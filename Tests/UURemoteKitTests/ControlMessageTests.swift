import Foundation
import XCTest
@testable import UURemoteKit

/// The golden bytes are what Rayon's hand-written encoder (the code this
/// package replaced) produced for the same messages, which live hosts take.
final class ControlMessageTests: XCTestCase {
    /// The body of an envelope (the one field after sequence and timestamp),
    /// for messages whose timestamp is the clock's.
    private func body(_ data: Data) throws -> Data {
        let message = try UUProtoMessage(serializedBytes: data)
        switch message.body {
        case let .rpcRequest(request): return try request.serializedData()
        case let .simpleAction(action): return try action.serializedData()
        default: XCTFail("unexpected body"); return Data()
        }
    }

    func testEchoRequestMatchesTheHandWrittenEncoder() {
        XCTAssertEqual(
            UUControl.echoRequest(sequence: 7, timestamp: 1_700_000_000_000).hex,
            "08071080d095ffbc311a140800221008061002180120023002380240034801"
        )
    }

    func testEchoResponseMatchesTheHandWrittenEncoder() {
        XCTAssertEqual(
            UUControl.echoResponse(sequence: 8, timestamp: 1_700_000_000_001, requestSequence: 42).hex,
            "08081081d095ffbc311a1a0801120a7b22736571223a34327d220a08061002180130024003"
        )
    }

    func testEchoSequenceIsReadFromTheArguments() throws {
        let message = try XCTUnwrap(UUControl.decode(UUControl.echoResponse(sequence: 1, requestSequence: 99)))
        guard case let .simpleAction(action) = message.body else { return XCTFail() }
        XCTAssertEqual(UUControl.echoSequence(action), 99)
    }

    func testRPCRequestsMatchTheHandWrittenEncoder() throws {
        XCTAssertEqual(try body(UUControl.sendVideoTrack(requestID: 3, tracks: [0, 1, 2])).hex, "0a0208037a06080008010802")
        XCTAssertEqual(
            try body(UUControl.captureSetting(requestID: 9, settings: UUStreamSettings(fps: 60, quality: 5, trueColor: true), codec: 2, fpsCount: 60, cursorCapture: false)).hex,
            "0a02080912360802100520feffffffffffffffff0128ffffffffffffffffff0130ffffffffffffffffff01380350016002680270801e78f01090013c"
        )
        XCTAssertEqual(try body(UUControl.createVirtualDisplay(requestID: 4, width: 1920, height: 1080)).hex, "0a020804620a0a0608800f10b8081001")
        XCTAssertEqual(try body(UUControl.removeVirtualDisplay(requestID: 5, screenID: 2)).hex, "0a0208056a020802")
        XCTAssertEqual(try body(UUControl.captureScreen(3, start: true, sequence: 11)).hex, "0808120f7b2273637265656e5f6964223a337d")
    }

    func testConnectOptionsMatchTheHandWrittenEncoder() {
        let settings = UUStreamSettings(fps: 60, quality: 5)
        XCTAssertEqual(
            UUConnectRequest.options(purpose: .desktop, deviceID: "abc123", settings: settings).hex,
            "080110ffffffffffffffffff011a160802100520022a0608800f10b808320038014801583c220c083c100218801e20f0102801220c083c100218801e20f0102803220c083c100118801e20f0102801220c083c100118801e20f0102803320808800f10b808183c3a0608800f10b80840044a0661626331323350015a10080610021801200230023802400348016206342e34382e34"
        )
        XCTAssertEqual(
            UUConnectRequest.options(purpose: .terminal, deviceID: "abc123", settings: settings).hex,
            "080810ffffffffffffffffff01220a083c100218801e20f010220a083c100218801e20f010220a083c100118801e20f010220a083c100118801e20f01040044a0661626331323350016206342e34382e34"
        )
    }

    func testScreenSourcesFillTheTrackAndCurrentScreen() {
        var sources = UUProtoScreenSources()
        var first = UUProtoScreen()
        first.id = 0
        first.isPrimary = true
        first.currentResolution.pixelWidth = 2880
        first.currentResolution.pixelHeight = 1800
        var second = UUProtoScreen()
        second.id = 5
        second.screenType = 1
        second.videoTrackIndex = 1
        second.displayName = "Virtual"
        var points = UUProtoWinRect()
        points.width = 1920
        points.height = 1080
        second.resolutions = [UUProtoWinRect(), points]
        sources.screens = [first, second]

        let decoded = UUControl.screens(from: sources)
        XCTAssertEqual(decoded.currentID, 0)
        XCTAssertEqual(decoded.screens, [
            UUScreen(id: 0, name: "Display 0", width: 2880, height: 1800, fps: 0, isPrimary: true, videoTrackIndex: 0),
            UUScreen(id: 5, name: "Virtual", width: 1920, height: 1080, fps: 0, isVirtual: true, videoTrackIndex: 1),
        ])
    }

    func testCaptureSettingAnswerGivesItsRequestAndErrors() {
        var response = UUProtoRpcResponse()
        response.header.requestID = 12
        var answer = UUProtoCaptureSettingResponse()
        var error = UUProtoRpcError()
        error.code = -3
        error.message = "fps"
        answer.errors = [error]
        response.body = .captureSetting(answer)
        var message = UUProtoMessage()
        message.body = .rpcResponse(response)
        let decoded = UUControl.captureSettingAnswer(message)
        XCTAssertEqual(decoded?.requestID, 12)
        XCTAssertEqual(decoded?.errors, [UUControl.RPCFailure(code: -3, message: "fps", detail: "")])

        // An answer without errors leaves its body off.
        response.body = nil
        message.body = .rpcResponse(response)
        XCTAssertEqual(UUControl.captureSettingAnswer(message)?.errors, [])

        // A clipboard acknowledgement is none.
        response.body = .clipboardText(UUProtoClipboardTextChangeResponse())
        message.body = .rpcResponse(response)
        XCTAssertNil(UUControl.captureSettingAnswer(message))
    }

    func testInputIsJSONWithItsTextEscaped() throws {
        let text = try JSONSerialization.jsonObject(with: UUInput.text("a \"quote\" \\ and\nnewline").data) as? [String: String]
        XCTAssertEqual(text?["content"], "a \"quote\" \\ and\nnewline")
        XCTAssertEqual(String(decoding: UUInput.pointerMove(x: 1.5, y: .nan, screenID: 2).data, as: UTF8.self),
                       #"{"abs_x":1,"abs_y":0,"action":"mouse_move_absolute","screen_id":2}"#)
        XCTAssertEqual(String(decoding: UUInput.key(13, isDown: true, windowsHost: true).data, as: UTF8.self),
                       #"{"action":"kbd_press","interrept":true,"key":13}"#)
        XCTAssertEqual(String(decoding: UUInput.button(.right, isDown: false).data, as: UTF8.self),
                       #"{"action":"mouse_release","button":2}"#)
    }

    func testControlChannelJSONIsNoMessage() {
        XCTAssertNil(UUControl.decode(UUInput.text("hi").data))
    }

    func testCursorImageNeedsAllItsPixels() {
        XCTAssertNotNil(UUControl.image(rgba: Data(count: 16), width: 2, height: 2))
        XCTAssertNil(UUControl.image(rgba: Data(count: 15), width: 2, height: 2))
        XCTAssertNil(UUControl.image(rgba: Data(), width: 0, height: 0))
    }

    func testCursorIsPlacedByItsHotspot() {
        let shape = UUCursor(x: 10, y: 20, width: 32, height: 32)
        let placed = shape.placed(at: (0.5, 0.5), on: CGSize(width: 100, height: 200))
        XCTAssertEqual(placed?.x ?? 0, 0.4, accuracy: 1e-9)
        XCTAssertEqual(placed?.y ?? 0, 0.4, accuracy: 1e-9)
        XCTAssertNil(shape.placed(at: (0.5, 0.5), on: .zero))
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index ..< next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}
