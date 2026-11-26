import CoreVideo
import Foundation
import os
import VideoToolbox
@preconcurrency import WebRTC
import XCTest
@testable import UURemoteKit

/// Plays a UU host against the transport over loopback: answers its offer,
/// echoes what arrives on CONTROL, and streams H.264 on the first video
/// transceiver.
private final class LoopbackHost: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate, @unchecked Sendable {
    let factory = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory())
    var peer: RTCPeerConnection!
    var onCandidate: (@Sendable (RTCIceCandidate) -> Void)?
    private var channels: [RTCDataChannel] = []
    private var source: RTCVideoSource!
    private var capturer: RTCVideoCapturer!
    private var timer: DispatchSourceTimer?

    override init() {
        super.init()
        factory.setOptions(UUWebRTCTransport.loopbackOnly)
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        peer = factory.peerConnection(with: configuration, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self)
        source = factory.videoSource(forScreenCast: true)
        capturer = RTCVideoCapturer(delegate: source)
    }

    func answer(_ offer: String) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: offer)) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        for candidate in early.withLock({ state -> [UUIceCandidate] in
            state.described = true
            return state.candidates
        }) { addNow(candidate) }
        // The first video transceiver sends; the rest stay silent.
        if let video = peer.transceivers.first(where: { $0.mediaType == .video }) {
            var error: NSError?
            video.setDirection(.sendOnly, error: &error)
            video.sender.track = factory.videoTrack(with: source, trackId: "video_0")
        }
        let answer: String = try await withCheckedThrowingContinuation { continuation in
            peer.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { description, error in
                guard let description else { return continuation.resume(throwing: error!) }
                self.peer.setLocalDescription(description) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: description.sdp) }
                }
            }
        }
        return answer
    }

    /// Candidates that came before the offer, added with it.
    private let early = OSAllocatedUnfairLock(initialState: (described: false, candidates: [UUIceCandidate]()))

    func add(_ candidate: UUIceCandidate) {
        let now = early.withLock { state -> Bool in
            if !state.described { state.candidates.append(candidate) }
            return state.described
        }
        if now { addNow(candidate) }
    }

    private func addNow(_ candidate: UUIceCandidate) {
        peer.add(RTCIceCandidate(sdp: candidate.candidate, sdpMLineIndex: candidate.sdpMLineIndex ?? 0, sdpMid: candidate.sdpMid)) { _ in }
    }

    func startStreaming() {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        var frame: Int64 = 0
        timer.schedule(deadline: .now(), repeating: .milliseconds(33))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
            guard let buffer else { return }
            frame += 1
            self.source.capturer(self.capturer, didCapture: RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: Int64(DispatchTime.now().uptimeNanoseconds)))
        }
        timer.resume()
        self.timer = timer
    }

    func close() {
        timer?.cancel()
        peer.close()
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        dataChannel.delegate = self
        channels.append(dataChannel)
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        dataChannel.sendData(RTCDataBuffer(data: Data("echo:".utf8) + buffer.data, isBinary: true))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) { onCandidate?(candidate) }
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
}

final class TransportTests: XCTestCase {
    func testTheOfferIsShapedLikeTheOfficialViewers() throws {
        let transport = try UUWebRTCTransport(configuration: UUPeerConfiguration(iceServers: [])) { _ in }
        defer { transport.close() }
        let expectation = expectation(description: "offer")
        let sdp = OSAllocatedUnfairLock(initialState: "")
        Task {
            let offer = try await transport.makeOffer(iceRestart: false)
            sdp.withLock { $0 = offer }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        let offer = sdp.withLock { $0 }
        XCTAssertEqual(offer.components(separatedBy: "m=video ").count - 1, 5)
        XCTAssertEqual(offer.components(separatedBy: "m=audio ").count - 1, 1)
        XCTAssertTrue(offer.contains("a=recvonly"))
        XCTAssertTrue(offer.contains("H265/90000"), "H.265 is offered")
        XCTAssertTrue(offer.contains("m=application "))
        let sent = UUSessionDescription.offerForHost(offer)
        XCTAssertTrue(sent.contains("a=x-uuremote-quic\r\na=group:BUNDLE"))
        XCTAssertTrue(sent.contains("a=max-message-size:262144"))
    }

    /// Channels open both ways, messages cross, and the host's video comes
    /// out decoded, on the transceiver it was sent on.
    func testALoopbackHostsChannelsAndVideoArrive() async throws {
        let host = LoopbackHost()
        defer { host.close() }
        let opened = expectation(description: "CONTROL open")
        let echoed = expectation(description: "echo")
        let framed = expectation(description: "frame")
        framed.assertForOverFulfill = false
        let mids = OSAllocatedUnfairLock(initialState: Set<String>())
        let transportBox = OSAllocatedUnfairLock<UUWebRTCTransport?>(initialState: nil)
        var configuration = UUPeerConfiguration(iceServers: [])
        configuration.loopbackOnly = true
        let transport = try UUWebRTCTransport(configuration: configuration) { event in
            switch event {
            case let .candidate(candidate): host.add(candidate)
            case .channelOpened(.control):
                opened.fulfill()
                transportBox.withLock { $0 }?.send(Data("ping".utf8), on: .control)
            case let .message(.control, data):
                XCTAssertEqual(String(decoding: data, as: UTF8.self), "echo:ping")
                echoed.fulfill()
            case let .frame(frame):
                XCTAssertEqual(frame.width, 320)
                mids.withLock { _ = $0.insert(frame.mid) }
                framed.fulfill()
            default: break
            }
        }
        transportBox.withLock { $0 = transport }
        defer { transport.close() }
        // The host's candidates wait for its answer to be set here.
        let hostCandidates = OSAllocatedUnfairLock(initialState: (answered: false, waiting: [UUIceCandidate]()))
        host.onCandidate = { rtc in
            let candidate = UUIceCandidate(candidate: rtc.sdp, sdpMid: rtc.sdpMid, sdpMLineIndex: rtc.sdpMLineIndex)
            let now = hostCandidates.withLock { state -> Bool in
                if !state.answered { state.waiting.append(candidate) }
                return state.answered
            }
            if now { Task { try? await transport.addRemoteCandidate(candidate) } }
        }
        let offer = try await transport.makeOffer(iceRestart: false)
        let answer = try await host.answer(offer)
        try await transport.setRemoteAnswer(answer)
        let waiting = hostCandidates.withLock { state -> [UUIceCandidate] in
            state.answered = true
            return state.waiting
        }
        for candidate in waiting { try await transport.addRemoteCandidate(candidate) }
        host.startStreaming()
        await fulfillment(of: [opened, echoed, framed], timeout: 20)
        let firstVideoMid = UUSessionDescription.videoTrackMids(in: answer).mids[0]
        XCTAssertEqual(mids.withLock { $0 }, Set([firstVideoMid].compactMap { $0 }))
        let stats = await transport.statistics()
        XCTAssertGreaterThan(stats.video.values.map(\.bytes).reduce(0, +), 0)
        XCTAssertFalse(stats.relayed)
    }

    func testVideoTracksAreFoundByNameOrOrder() {
        let sdp = """
        m=video 9 UDP\r\na=mid:0\r\na=msid:- video_1\r\n\
        m=video 9 UDP\r\na=mid:1\r\n\
        m=video 0 UDP\r\na=mid:2\r\n\
        m=video 9 UDP\r\na=mid:3\r\na=msid:- video_0\r\n
        """
        let tracks = UUSessionDescription.videoTrackMids(in: sdp)
        XCTAssertEqual(tracks.mids, [1: "0", 0: "3", 2: "1"])
        XCTAssertEqual(tracks.named, ["0", "3"])
    }

    func testSDPComesPlainOrGzipped() throws {
        XCTAssertEqual(UUSessionDescription.sdp(in: ["sdp": "plain"]), "plain")
        let gzip = Data(hex: "1f8b08080000000000ff7364702e747874002bb335e0e5cab7d55530543052f0f453f00c3051303432d7330042435eae625b5d5eae322aa90100c11bac796c000000")
        XCTAssertEqual(UUSessionDescription.sdp(in: ["gzip_sdp": gzip.base64EncodedString()])?.hasPrefix("v=0\r\n"), true)
        XCTAssertNil(UUSessionDescription.sdp(in: ["gzip_sdp": "not base64!"]))
    }

    func testStatsReadTheTrackAndTheSelectedPair() {
        let stats = UUWebRTCTransport.stats(from: [
            ("codec", "c1", ["mimeType": "video/H265" as NSString]),
            ("inbound-rtp", "i1", ["kind": "video" as NSString, "mid": "2" as NSString, "codecId": "c1" as NSString, "bytesReceived": 1000 as NSNumber, "packetsReceived": 10 as NSNumber, "packetsLost": 1 as NSNumber]),
            ("local-candidate", "l1", ["candidateType": "relay" as NSString]),
            ("candidate-pair", "p1", ["localCandidateId": "l1" as NSString, "currentRoundTripTime": 0.05 as NSNumber]),
            ("transport", "t1", ["selectedCandidatePairId": "p1" as NSString]),
        ])
        XCTAssertEqual(stats.video["2"], .init(codec: "video/H265", bytes: 1000, packets: 10, lost: 1))
        XCTAssertEqual(stats.roundTrip, 0.05)
        XCTAssertTrue(stats.relayed)
    }
}
