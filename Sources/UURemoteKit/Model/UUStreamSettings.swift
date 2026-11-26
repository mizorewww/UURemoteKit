//
//  UUStreamSettings.swift
//  UURemoteKit
//

/// The picture a host sends: frame rate, quality preset and true colour.
public struct UUStreamSettings: Equatable, Sendable {
    public var fps: Int
    /// The host's preset: 2 HD, 3 Ultra HD, 4 Original, 5 Auto.
    public var quality: Int
    /// 4:4:4 chroma instead of 4:2:0.
    public var trueColor: Bool

    public static let qualityHD = 2
    public static let qualityAuto = 5

    public init(fps: Int = 60, quality: Int = qualityAuto, trueColor: Bool = false) {
        self.fps = fps
        self.quality = quality
        self.trueColor = trueColor
    }
}

/// How the connection carrying a desktop is doing.
public struct UUNetworkStats: Equatable, Sendable {
    /// The video's bit rate over the last second.
    public var bitsPerSecond: Int?
    /// Packets lost over the last second, in percent.
    public var lossPercent: Double?
    /// Through a relay server rather than peer to peer.
    public var relayed: Bool

    public init(bitsPerSecond: Int? = nil, lossPercent: Double? = nil, relayed: Bool = false) {
        self.bitsPerSecond = bitsPerSecond
        self.lossPercent = lossPercent
        self.relayed = relayed
    }
}

/// Mouse buttons, by their wire value.
public enum UUMouseButton: Int32, Sendable, CaseIterable {
    case left = 1
    case right = 2
    case middle = 4
    case back = 8
    case forward = 16
}
