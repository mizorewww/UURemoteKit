//
//  UUPortMappingMessages.swift
//  UURemoteKit
//
//  PortMappingFrame (field 27) on FILE_DATA_CHANNEL, and the JSON its SYN
//  and SYN_ACK carry.
//

import Foundation

/// The JSON of a SYN: where on the host's side to connect.
struct UUPortMappingSYN: Codable, Equatable {
    var version: UInt64 = 1
    var targetHost: String
    var targetPort: UInt16

    enum CodingKeys: String, CodingKey {
        case version
        case targetHost = "target_host"
        case targetPort = "target_port"
    }

    var data: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data()
    }
}

/// The JSON of a SYN_ACK: whether the host connected, and why not.
struct UUPortMappingSYNACK: Codable, Equatable {
    var version: UInt64?
    var ok: Bool
    var error: String?

    init?(_ data: Data) {
        guard let decoded = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = decoded
    }
}

/// The streams of one connection are told apart by their three ids.
struct UUPortMappingKey: Hashable, Sendable {
    var session: UInt64
    var rule: UInt64
    var stream: UInt64

    init(session: UInt64, rule: UInt64, stream: UInt64) {
        self.session = session
        self.rule = rule
        self.stream = stream
    }

    init(_ frame: UUProtoPortMappingFrame) {
        self.init(session: frame.sessionID, rule: frame.ruleID, stream: frame.streamID)
    }

    func frame(_ type: UUProtoPortMappingType, payload: Data = Data()) -> UUProtoPortMappingFrame {
        var frame = UUProtoPortMappingFrame()
        frame.sessionID = session
        frame.ruleID = rule
        frame.streamID = stream
        frame.type = type
        frame.payload = payload
        return frame
    }
}
