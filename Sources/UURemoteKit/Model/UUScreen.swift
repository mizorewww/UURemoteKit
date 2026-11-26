//
//  UUScreen.swift
//  UURemoteKit
//

/// One of the host's screens.
public struct UUScreen: Identifiable, Equatable, Sendable {
    public var id: Int
    public var name: String
    /// In pixels.
    public var width: Int
    public var height: Int
    /// The screen's refresh, when the host says.
    public var fps: Int
    public var isPrimary: Bool
    /// A UU virtual screen, which can be removed again.
    public var isVirtual: Bool
    /// The video track the host streams this screen on, when it says.
    public var videoTrackIndex: Int?

    public init(id: Int, name: String = "", width: Int = 0, height: Int = 0, fps: Int = 60, isPrimary: Bool = false, isVirtual: Bool = false, videoTrackIndex: Int? = nil) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
        self.fps = fps
        self.isPrimary = isPrimary
        self.isVirtual = isVirtual
        self.videoTrackIndex = videoTrackIndex
    }
}
