//
//  UUInput.swift
//  UURemoteKit
//
//  Desktop input: bare JSON objects on CONTROL_DATA_CHANNEL.
//

import Foundation

struct UUInput: Encodable, Equatable {
    var action: String
    var screenID: Int?
    var absX: Double?
    var absY: Double?
    var deltaX: Int32?
    var deltaY: Int32?
    var button: Int32?
    var key: Int32?
    /// Windows hosts want it on key events (sic).
    var interrept: Bool?
    var content: String?

    enum CodingKeys: String, CodingKey {
        case action
        case screenID = "screen_id"
        case absX = "abs_x"
        case absY = "abs_y"
        case deltaX = "delta_x"
        case deltaY = "delta_y"
        case button, key, interrept, content
    }

    var data: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data()
    }

    /// The pointer at a normalized place, clamped to the screen; `screenID`
    /// says which screen, without which a host with several puts it on the
    /// one it captured last. What is no number is 0.
    static func pointerMove(x: Double, y: Double, screenID: Int?) -> UUInput {
        func clamp(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
        return UUInput(action: "mouse_move_absolute", screenID: screenID, absX: clamp(x), absY: clamp(y))
    }

    static func button(_ button: UUMouseButton, isDown: Bool) -> UUInput {
        UUInput(action: isDown ? "mouse_press" : "mouse_release", button: button.rawValue)
    }

    /// In the host's wheel units, positive `dy` scrolling up.
    static func scroll(dx: Int32, dy: Int32) -> UUInput {
        UUInput(action: "mouse_scroll", deltaX: dx, deltaY: dy)
    }

    static func key(_ key: Int32, isDown: Bool, windowsHost: Bool) -> UUInput {
        UUInput(action: isDown ? "kbd_press" : "kbd_release", key: key, interrept: windowsHost ? true : nil)
    }

    static func text(_ text: String) -> UUInput {
        UUInput(action: "text_input", content: text)
    }

    /// The keyboard heartbeat the host's input watchdog wants once a second.
    static let keyboardHeartbeat = Data(#"{"heartbeat":"kbd_heartbeat"}"#.utf8)
}
