//
//  UUPeerTransport.swift
//  UURemoteKit
//
//  What a UU Remote connection needs of its peer connection: an offer
//  shaped like the official viewer's, the host's answer and candidates,
//  the five data channels, and the decoded frames of each video track.
//  `UUWebRTCTransport` is the one the kit ships; tests can hand in another.
//

import Foundation
import IOSurface

/// The data channels the viewer opens, by their labels.
public enum UUDataChannel: String, CaseIterable, Sendable {
    case streamer = "STREAMER_DATA_CHANNEL"
    case file = "FILE_DATA_CHANNEL"
    case text = "TEXT_DATA_CHANNEL"
    case binary = "BINARY_DATA_CHANNEL"
    case control = "CONTROL_DATA_CHANNEL"
}

/// An ICE candidate as `RTCIceCandidateInit` names its fields.
public struct UUIceCandidate: Equatable, Sendable {
    public var candidate: String
    public var sdpMid: String?
    public var sdpMLineIndex: Int32?

    public init(candidate: String, sdpMid: String?, sdpMLineIndex: Int32?) {
        self.candidate = candidate
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
    }
}

/// An ICE server from the host's control acknowledgement.
public struct UUIceServer: Equatable, Sendable {
    public var urls: [String]
    public var username: String?
    public var credential: String?

    public init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }
}

public struct UUPeerConfiguration: Sendable {
    public var iceServers: [UUIceServer]
    /// Only through the relay servers.
    public var relayOnly: Bool
    /// Plays the host's audio; the stream is received either way.
    public var playsAudio: Bool
    /// Gathers on the loopback interface alone: tests that play the host in
    /// process, which other interfaces (VPNs, VM bridges) only slow down.
    var loopbackOnly = false

    public init(iceServers: [UUIceServer], relayOnly: Bool = false, playsAudio: Bool = false) {
        self.iceServers = iceServers
        self.relayOnly = relayOnly
        self.playsAudio = playsAudio
    }
}

/// A decoded frame of one of the host's video tracks: its IOSurface, held
/// in use for as long as the frame lives, so the decoder's pool does not
/// draw the next picture into it while it is still on its way to the
/// screen. A pixel buffer cannot cross threads in Swift; a surface can.
public final class UUVideoFrame: Sendable {
    /// The transceiver the track arrived on.
    public let mid: String
    public let surface: IOSurface
    public var width: Int { surface.width }
    public var height: Int { surface.height }

    public init(mid: String, surface: IOSurface) {
        self.mid = mid
        self.surface = surface
        surface.incrementUseCount()
    }

    deinit { surface.decrementUseCount() }
}

public enum UUIceState: Sendable, Equatable {
    case checking
    case connected
    case disconnected
    case failed
    case closed
    case other
}

/// The transport's numbers for the last moment, totals since it started.
public struct UUTransportStats: Equatable, Sendable {
    public struct Track: Equatable, Sendable {
        public var codec: String
        public var bytes: Double
        public var packets: Double
        public var lost: Double

        public init(codec: String = "", bytes: Double = 0, packets: Double = 0, lost: Double = 0) {
            self.codec = codec
            self.bytes = bytes
            self.packets = packets
            self.lost = lost
        }
    }

    /// Received video, by transceiver mid.
    public var video: [String: Track] = [:]
    /// The selected candidate pair's round trip, in seconds.
    public var roundTrip: Double?
    /// The selected pair's local candidate is a relay one.
    public var relayed = false

    public init(video: [String: Track] = [:], roundTrip: Double? = nil, relayed: Bool = false) {
        self.video = video
        self.roundTrip = roundTrip
        self.relayed = relayed
    }
}

public enum UUPeerEvent: Sendable {
    case candidate(UUIceCandidate)
    case iceState(UUIceState)
    case channelOpened(UUDataChannel)
    case channelClosed(UUDataChannel)
    case message(UUDataChannel, Data)
    case frame(UUVideoFrame)
}

public protocol UUPeerTransport: AnyObject, Sendable {
    /// The viewer's offer, as set locally: five receive-only video
    /// transceivers, one audio, and the five data channels.
    func makeOffer(iceRestart: Bool) async throws -> String
    func setRemoteAnswer(_ sdp: String) async throws
    /// Answers an offer the host pushed.
    func answer(remoteOffer sdp: String) async throws -> String
    func addRemoteCandidate(_ candidate: UUIceCandidate) async throws
    /// Sends on a channel; false when it is not open.
    @discardableResult func send(_ data: Data, on channel: UUDataChannel) -> Bool
    /// Asks the host for a key frame on every video track.
    func requestKeyFrame()
    func statistics() async -> UUTransportStats
    func close()
}

/// Makes a connection's transport; events may come on any thread.
public typealias UUPeerTransportFactory = @Sendable (UUPeerConfiguration, @escaping @Sendable (UUPeerEvent) -> Void) throws -> UUPeerTransport
