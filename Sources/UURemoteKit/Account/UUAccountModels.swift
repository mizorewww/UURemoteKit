//
//  UUAccountModels.swift
//  UURemoteKit
//
//  The account, device and room values the UU Remote service deals in.
//

import Foundation

public enum UUAPIError: Error, Sendable {
    case invalidURL(String)
    case transport(String)
    case http(Int, String)
    case api(Int, String)
    case missingField(String)
    case tokenExpired
}

extension UUAPIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidURL(url): "UU Remote: the request address is not valid (\(url))."
        case let .transport(reason): "Could not reach UU Remote: \(reason)"
        case let .http(status, reason): "UU Remote answered HTTP \(status): \(reason)"
        case let .api(_, message): "UU Remote refused the request: \(message)"
        case let .missingField(field): "UU Remote's answer is missing \(field)."
        case .tokenExpired: "The UU Remote sign-in has expired. Sign in again."
        }
    }
}

/// The service's request constants. The signing key is the one every UU
/// PC client signs with (x-param-plat=1), the same for every user; it may
/// rotate with a client release.
public enum UUConstants {
    public static let signingKey = "alWiSzXZTLu3WfFnw13uBru3"
    public static let apiBase = "https://api.nrd.nie.163.com"
    public static let apiBaseSecondary = "https://api-dcdn.nrd.nie.163.com"
    public static let apiBaseIPv4 = "https://api-ipv4.nrd.nie.163.com"
    /// Version reported to the cloud and to hosts. Hosts compare it against a
    /// moving baseline and refuse a control that falls under it ("控制端版本过低");
    /// the official Windows client is at 4.48.3, macOS at 4.48.4, so reporting
    /// the current release family stays clear of the baseline. The check is a
    /// numeric comparison: the code is the version's fourth component, as the
    /// official client's is.
    public static let versionName = "4.48.3.5000"
    public static let versionCode = "5000"
    /// The first three components, for places that carry no build number.
    public static var shortVersionName: String {
        versionName.split(separator: ".").prefix(3).joined(separator: ".")
    }
    public static let packageName = "com.netease.gameviewer"
    public static let channel = "gwqd"
    public static let language = "zh-CN"
    public static let country = "CN"
    public static let tokenInvalidCode = 1120
}

/// The persisted identity a logged-in UU Remote account carries.
public struct UUCredentials: Codable, Equatable, Sendable {
    public var userID: String = ""
    public var deviceID: String = ""
    public var clientID: String = ""
    public var systemID: String = ""
    public var token: String = ""
    public var csrf: String = ""
    public var guestID: String?
    public var signKey: String = UUConstants.signingKey

    public init() {}

    /// True when all fields a signed request needs are present.
    public var isComplete: Bool {
        !userID.isEmpty && !deviceID.isEmpty && !clientID.isEmpty
            && !systemID.isEmpty && !token.isEmpty && !csrf.isEmpty
    }
}

/// A device on the account.
public struct UUDeviceInfo: Equatable, Sendable {
    public var deviceID: String = ""
    public var alias: String = ""
    public var status: String = ""
    public var platform: Int = 0
    public var controllable = false
    public var supportWOL = false
    public var wallpaperURL: String?
    public var versionName: String?
    public var participants: [UUParticipant] = []

    public init() {}

    public var isOnline: Bool { status == "CONNECTED" || status == "READY" }
    /// A computer: a Windows (1) or Mac (4) host.
    public var isComputer: Bool { platform == 1 || platform == 4 }

    /// Whether this is a viewer's own sign-in named `clientName`: a viewer
    /// registers as a device of its own (the service wants one), named
    /// "<client>" or "<client> · <host>". The exact naming is the marker,
    /// not a bare prefix, which a real computer named "<client>-lab" shares.
    public func isRegistration(of clientName: String) -> Bool {
        guard platform == 1 else { return false }
        let name = alias.lowercased()
        let client = clientName.lowercased()
        return name == client || name.hasPrefix("\(client) ·")
    }

    public static func platformName(_ platform: Int) -> String {
        switch platform {
        case 1: "Windows"
        case 2: "Android"
        case 3: "iOS"
        case 4: "macOS"
        case 5: "TV"
        default: "Unknown"
        }
    }
}

/// Someone connected to a device.
public struct UUParticipant: Equatable, Sendable {
    public var clientID: String = ""
    public var deviceID: String = ""
    public var alias: String = ""
    public var platform: Int = 0
    public var userJoinType: String = ""
    public var controlledTime: String = ""
}

/// A joined room: the signaling token and servers.
public struct UURoomConfig: Sendable {
    public var token: String = ""
    public var signalServers: [String] = []
    public var timeout: Int = 0
    public var signalReconnectDelay: Int = 0
    public var reportToken: String?
    public var reportURL: String?
    public var appDataJSON: Data?
}
