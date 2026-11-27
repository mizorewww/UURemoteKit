//
//  UUWebRTCTransport.swift
//  UURemoteKit
//
//  The peer connection on the WebRTC SDK: data channels as RTCDataChannel,
//  video decoded by VideoToolbox into pixel buffers, track by track.
//

import CoreVideo
import Foundation
import os
import Synchronization
@preconcurrency import WebRTC

/// WebRTC's Objective-C objects are thread safe (each call is marshalled to
/// its signaling or worker thread), so the transport holds them as they are.
public final class UUWebRTCTransport: UUPeerTransport {
    /// The kit's default transport factory.
    public static let factory: UUPeerTransportFactory = { configuration, onEvent in
        try UUWebRTCTransport(configuration: configuration, onEvent: onEvent)
    }

    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    private static let sslInitialized: Bool = RTCInitializeSSL()
    private static let log = Logger(subsystem: "UURemoteKit", category: "webrtc")

    private let decoders = UUDecoderFactory()
    private let factory: RTCPeerConnectionFactory
    private let events: PeerEvents
    private let peer: RTCPeerConnection
    private let renderers: [Renderer]

    public init(configuration: UUPeerConfiguration, onEvent: @escaping @Sendable (UUPeerEvent) -> Void) throws {
        _ = Self.sslInitialized
        factory = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: decoders)
        if configuration.loopbackOnly { factory.setOptions(Self.loopbackOnly) }
        events = PeerEvents(onEvent: onEvent)

        let rtc = RTCConfiguration()
        rtc.iceServers = configuration.iceServers.map {
            RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential)
        }
        rtc.iceTransportPolicy = configuration.relayOnly ? .relay : .all
        rtc.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peer = factory.peerConnection(with: rtc, constraints: constraints, delegate: events) else {
            throw Failure(message: "WebRTC could not make a peer connection.")
        }
        self.peer = peer

        // As the official viewer offers them: the data channels, five video
        // tracks to receive (one per screen the host may stream) and audio.
        for channel in UUDataChannel.allCases {
            let options = RTCDataChannelConfiguration()
            options.isOrdered = true
            guard let made = peer.dataChannel(forLabel: channel.rawValue, configuration: options) else { continue }
            made.delegate = events
            events.setChannel(made, for: channel)
        }
        let receiveOnly = RTCRtpTransceiverInit()
        receiveOnly.direction = .recvOnly
        renderers = (0 ..< 5).compactMap { _ in
            guard let transceiver = peer.addTransceiver(of: .video, init: receiveOnly),
                  let track = transceiver.receiver.track as? RTCVideoTrack else { return nil }
            let renderer = Renderer(transceiver: transceiver, track: track, onEvent: onEvent)
            track.add(renderer)
            return renderer
        }
        if let audio = peer.addTransceiver(of: .audio, init: receiveOnly) {
            audio.receiver.track?.isEnabled = configuration.playsAudio
        }
        #if os(iOS)
            if !configuration.playsAudio {
                // No audio unit (and no microphone prompt) for a silent session.
                let session = RTCAudioSession.sharedInstance()
                session.useManualAudio = true
                session.isAudioEnabled = false
            }
        #endif
    }

    // MARK: - Descriptions

    public func makeOffer(iceRestart: Bool) async throws -> String {
        let constraints = RTCMediaConstraints(mandatoryConstraints: iceRestart ? [kRTCMediaConstraintsIceRestart: kRTCMediaConstraintsValueTrue] : nil, optionalConstraints: nil)
        let sdp = try await describe { self.peer.offer(for: constraints, completionHandler: $0) }
        let offer = RTCSessionDescription(type: .offer, sdp: sdp)
        try await apply { self.peer.setLocalDescription(offer, completionHandler: $0) }
        return sdp
    }

    public func setRemoteAnswer(_ sdp: String) async throws {
        let answer = RTCSessionDescription(type: .answer, sdp: sdp)
        try await apply { self.peer.setRemoteDescription(answer, completionHandler: $0) }
    }

    public func answer(remoteOffer sdp: String) async throws -> String {
        let offer = RTCSessionDescription(type: .offer, sdp: sdp)
        try await apply { self.peer.setRemoteDescription(offer, completionHandler: $0) }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let sdp = try await describe { self.peer.answer(for: constraints, completionHandler: $0) }
        let answer = RTCSessionDescription(type: .answer, sdp: sdp)
        try await apply { self.peer.setLocalDescription(answer, completionHandler: $0) }
        return sdp
    }

    public func addRemoteCandidate(_ candidate: UUIceCandidate) async throws {
        let ice = RTCIceCandidate(sdp: candidate.candidate, sdpMLineIndex: candidate.sdpMLineIndex ?? 0, sdpMid: candidate.sdpMid)
        try await apply { self.peer.add(ice, completionHandler: $0) }
    }

    /// The SDP of the description WebRTC made.
    private func describe(_ call: (@escaping @Sendable (RTCSessionDescription?, Error?) -> Void) -> Void) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            call { description, error in
                if let description {
                    continuation.resume(returning: description.sdp)
                } else {
                    continuation.resume(throwing: error ?? Failure(message: "WebRTC made no session description."))
                }
            }
        }
    }

    private func apply(_ call: (@escaping @Sendable (Error?) -> Void) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            call { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    // MARK: - Channels, key frames, statistics

    @discardableResult
    public func send(_ data: Data, on channel: UUDataChannel) -> Bool {
        guard let made = events.channel(channel), made.readyState == .open else { return false }
        return made.sendData(RTCDataBuffer(data: data, isBinary: true))
    }

    public func requestKeyFrame() {
        decoders.requests.request()
    }

    public func statistics() async -> UUTransportStats {
        await withCheckedContinuation { continuation in
            peer.statistics { report in
                continuation.resume(returning: Self.stats(from: report.statistics.values.map { ($0.type, $0.id, $0.values) }))
            }
        }
    }

    /// The numbers out of a report's entries (type, id, values).
    static func stats(from entries: [(type: String, id: String, values: [String: NSObject])]) -> UUTransportStats {
        func number(_ value: NSObject?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }
        var stats = UUTransportStats()
        var codecs: [String: String] = [:]
        var localTypes: [String: String] = [:]
        var pairs: [String: [String: NSObject]] = [:]
        var selectedPair: String?
        for entry in entries {
            switch entry.type {
            case "codec": codecs[entry.id] = entry.values["mimeType"] as? String
            case "local-candidate": localTypes[entry.id] = entry.values["candidateType"] as? String
            case "candidate-pair": pairs[entry.id] = entry.values
            case "transport": selectedPair = entry.values["selectedCandidatePairId"] as? String ?? selectedPair
            default: break
            }
        }
        for entry in entries where entry.type == "inbound-rtp" && entry.values["kind"] as? String == "video" {
            guard let mid = entry.values["mid"] as? String else { continue }
            stats.video[mid] = .init(
                codec: (entry.values["codecId"] as? String).flatMap { codecs[$0] } ?? "",
                bytes: number(entry.values["bytesReceived"]),
                packets: number(entry.values["packetsReceived"]),
                lost: number(entry.values["packetsLost"])
            )
        }
        let pair = selectedPair.flatMap { pairs[$0] }
            ?? pairs.values.first { ($0["nominated"] as? NSNumber)?.boolValue == true && $0["state"] as? String == "succeeded" }
        if let pair {
            stats.roundTrip = (pair["currentRoundTripTime"] as? NSNumber)?.doubleValue
            stats.relayed = (pair["localCandidateId"] as? String).flatMap { localTypes[$0] } == "relay"
        }
        return stats
    }

    static var loopbackOnly: RTCPeerConnectionFactoryOptions {
        let options = RTCPeerConnectionFactoryOptions()
        options.ignoreLoopbackNetworkAdapter = false
        options.ignoreEthernetNetworkAdapter = true
        options.ignoreWiFiNetworkAdapter = true
        options.ignoreVPNNetworkAdapter = true
        options.ignoreCellularNetworkAdapter = true
        return options
    }

    public func close() {
        for renderer in renderers { renderer.track.remove(renderer) }
        for channel in events.channels { channel.close() }
        peer.close()
    }

    deinit {
        peer.close()
    }

    /// One video track's frames, as pixel buffers, with its transceiver's
    /// mid (known once the offer is set).
    private final class Renderer: NSObject, RTCVideoRenderer, Sendable {
        private let transceiver: RTCRtpTransceiver
        /// Kept: the SDK removes a track object's renderers when it goes.
        let track: RTCVideoTrack
        private let onEvent: @Sendable (UUPeerEvent) -> Void

        init(transceiver: RTCRtpTransceiver, track: RTCVideoTrack, onEvent: @escaping @Sendable (UUPeerEvent) -> Void) {
            self.transceiver = transceiver
            self.track = track
            self.onEvent = onEvent
        }

        func setSize(_ size: CGSize) {}

        func renderFrame(_ frame: RTCVideoFrame?) {
            // VideoToolbox decodes onto IOSurfaces; a buffer that is not
            // on one (no decoder here makes such) cannot be shown as it is.
            guard let buffer = frame?.buffer as? RTCCVPixelBuffer,
                  let surface = CVPixelBufferGetIOSurface(buffer.pixelBuffer)?.takeUnretainedValue(),
                  !transceiver.mid.isEmpty else { return }
            onEvent(.frame(UUVideoFrame(mid: transceiver.mid, surface: surface)))
        }
    }
}

/// The peer connection's and data channels' delegate, made before them.
private final class PeerEvents: NSObject, Sendable {
    let onEvent: @Sendable (UUPeerEvent) -> Void
    /// Ours, or the host's where it opened one of the same label.
    private let channelsByLabel = Mutex<[UUDataChannel: RTCDataChannel]>([:])

    init(onEvent: @escaping @Sendable (UUPeerEvent) -> Void) {
        self.onEvent = onEvent
    }

    func channel(_ channel: UUDataChannel) -> RTCDataChannel? {
        channelsByLabel.withLock { $0[channel] }
    }

    func setChannel(_ made: RTCDataChannel, for channel: UUDataChannel) {
        channelsByLabel.withLock { $0[channel] = made }
    }

    var channels: [RTCDataChannel] {
        channelsByLabel.withLock { Array($0.values) }
    }
}

extension PeerEvents: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        let state: UUIceState = switch newState {
        case .checking: .checking
        case .connected, .completed: .connected
        case .disconnected: .disconnected
        case .failed: .failed
        case .closed: .closed
        default: .other
        }
        onEvent(.iceState(state))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onEvent(.candidate(UUIceCandidate(candidate: candidate.sdp, sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.sdpMLineIndex)))
    }

    /// A channel the host opened: it takes the place of ours of that label.
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        guard let channel = UUDataChannel(rawValue: dataChannel.label) else { return }
        dataChannel.delegate = self
        setChannel(dataChannel, for: channel)
        if dataChannel.readyState == .open { onEvent(.channelOpened(channel)) }
    }
}

extension PeerEvents: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        guard let channel = UUDataChannel(rawValue: dataChannel.label),
              self.channel(channel) === dataChannel else { return }
        switch dataChannel.readyState {
        case .open: onEvent(.channelOpened(channel))
        case .closed: onEvent(.channelClosed(channel))
        default: break
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard let channel = UUDataChannel(rawValue: dataChannel.label) else { return }
        onEvent(.message(channel, buffer.data))
    }
}
