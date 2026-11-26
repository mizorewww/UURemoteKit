//
//  UURemoteTarget.swift
//  UURemoteKit
//

/// A device to connect to: one on the account, or one shared with a
/// remote-assistance code (which needs no account).
public struct UURemoteTarget: Hashable, Sendable {
    public var deviceID: String
    /// The device's connect id and the code its owner gave out, for a
    /// remote-assistance join; empty for a device on the account.
    public var assistID: String
    public var assistCode: String

    public init(deviceID: String, assistID: String = "", assistCode: String = "") {
        self.deviceID = deviceID
        self.assistID = assistID
        self.assistCode = assistCode
    }

    var isAssist: Bool { !assistID.isEmpty }

    /// A room is the device's, or the assistance's.
    var roomKey: String { isAssist ? "assist|\(assistID)" : "device|\(deviceID)" }
}
