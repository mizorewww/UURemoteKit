//
//  UUConnectionPurpose.swift
//  UURemoteKit
//

/// What a connection to a device is for.
public enum UUConnectionPurpose: Sendable {
    /// The screen, input and clipboard (and terminals while it is open).
    case desktop
    /// Terminals and port mappings, no video.
    case terminal
}
