//
//  UUTerminalFrame.swift
//  UURemoteKit
//
//  TERM frames on BINARY_DATA_CHANNEL: a 16-byte header ("TERM", version,
//  kind, two flag bytes, little-endian session id and payload length) and
//  the payload, JSON for everything but stdin and stdout.
//

import Foundation

public enum UUTerminalKind: UInt8, CaseIterable, Sendable {
    case open = 1
    case stdin = 2
    case resize = 3
    case close = 4
    case stdout = 5
    case exit = 6
    case signal = 7
    case error = 8
    case listRequest = 9
    case listResponse = 10
    case killRequest = 11
    case killResponse = 12
    case openResponse = 13
    case unlockRequest = 14
    case unlockResponse = 15
    case detach = 16
}

public struct UUTerminalFrame: Equatable, Sendable {
    static let magic = Data("TERM".utf8)
    static let version: UInt8 = 1
    static let headerSize = 16
    static let maxPayload = 0x10_0000

    public var kind: UUTerminalKind
    public var sessionID: UInt32
    public var payload: Data
    public var flags: (UInt8, UInt8)

    public init(kind: UUTerminalKind, sessionID: UInt32, payload: Data = Data(), flags: (UInt8, UInt8) = (0, 0)) {
        self.kind = kind
        self.sessionID = sessionID
        self.payload = payload
        self.flags = flags
    }

    public static func == (lhs: UUTerminalFrame, rhs: UUTerminalFrame) -> Bool {
        lhs.kind == rhs.kind && lhs.sessionID == rhs.sessionID && lhs.payload == rhs.payload
            && lhs.flags == rhs.flags
    }

    public func encode() -> Data {
        var out = Data(capacity: Self.headerSize + payload.count)
        out.append(Self.magic)
        out.append(Self.version)
        out.append(kind.rawValue)
        out.append(flags.0)
        out.append(flags.1)
        withUnsafeBytes(of: sessionID.littleEndian) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    /// Exactly one complete frame; nil for anything else.
    public init?(decoding data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= Self.headerSize, Data(bytes[0 ..< 4]) == Self.magic,
              let kind = UUTerminalKind(rawValue: bytes[5])
        else { return nil }
        func uint32(at offset: Int) -> UInt32 {
            bytes[offset ..< offset + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) }
        }
        let length = Int(uint32(at: 12))
        guard length <= Self.maxPayload, bytes.count == Self.headerSize + length else { return nil }
        self.init(kind: kind, sessionID: uint32(at: 8), payload: Data(bytes[Self.headerSize...]), flags: (bytes[6], bytes[7]))
    }

    static func isFrame(_ data: Data) -> Bool {
        data.count >= 4 && data.prefix(4) == magic
    }
}

/// The JSON payloads of TERM frames.
enum UUTerminalJSON {
    private struct Open: Encodable { var cols: Int; var rows: Int; var shell: String; var option = "none" }
    private struct Size: Encodable { var cols: Int; var rows: Int }

    private static func encode(_ value: some Encodable) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)) ?? Data()
    }

    static func open(cols: Int, rows: Int, shell: String) -> Data {
        encode(Open(cols: cols, rows: rows, shell: shell))
    }

    static func resize(cols: Int, rows: Int) -> Data {
        encode(Size(cols: cols, rows: rows))
    }

    struct OpenResponse: Decodable, Equatable {
        var code: Int
        var message: String?
    }

    struct Exit: Decodable, Equatable {
        var exitCode: Int
        enum CodingKeys: String, CodingKey { case exitCode = "exit_code" }
    }

    static func openResponse(_ payload: Data) -> OpenResponse? {
        try? JSONDecoder().decode(OpenResponse.self, from: payload)
    }

    static func exitCode(_ payload: Data) -> Int? {
        (try? JSONDecoder().decode(Exit.self, from: payload))?.exitCode
    }
}

/// A terminal session the host keeps, attached or not.
public struct UUTerminalSession: Identifiable, Equatable, Sendable, Decodable {
    public var id: UInt32
    public var name: String
    public var shell: String
    /// "running" while a client is attached, "detached" otherwise.
    public var state: String
    public var createdAt: Date
    public var lastActive: Date

    public var isDetached: Bool { state == "detached" }

    public init(id: UInt32, name: String, shell: String = "", state: String, createdAt: Date, lastActive: Date) {
        self.id = id
        self.name = name
        self.shell = shell
        self.state = state
        self.createdAt = createdAt
        self.lastActive = lastActive
    }

    enum CodingKeys: String, CodingKey {
        case id = "session_id", name, shell, state
        case createdAt = "created_at_ms"
        case lastActive = "last_active_ms"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UInt32.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "session"
        shell = try container.decodeIfPresent(String.self, forKey: .shell) ?? ""
        state = try container.decodeIfPresent(String.self, forKey: .state) ?? ""
        func date(_ key: CodingKeys) throws -> Date {
            Date(timeIntervalSince1970: (try container.decodeIfPresent(Double.self, forKey: key) ?? 0) / 1000)
        }
        createdAt = try date(.createdAt)
        lastActive = try date(.lastActive)
    }

    /// LIST_RESP: the sessions, most recently used first; nil when malformed.
    static func list(from payload: Data) -> [UUTerminalSession]? {
        struct Lenient: Decodable {
            var session: UUTerminalSession?
            init(from decoder: Decoder) throws { session = try? UUTerminalSession(from: decoder) }
        }
        guard let entries = try? JSONDecoder().decode([Lenient].self, from: payload) else { return nil }
        return entries.compactMap(\.session).sorted { $0.lastActive > $1.lastActive }
    }
}
