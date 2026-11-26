import Foundation
import XCTest
@testable import UURemoteKit

/// The host's side of each clipboard exchange is played here with the
/// generated messages.
final class ClipboardTests: XCTestCase {
    private func message(_ data: Data) throws -> UUProtoMessage {
        try UUProtoMessage(serializedBytes: data)
    }

    private func hostRequest(id: UInt64, _ body: UUProtoRpcRequest.OneOf_Body) -> UUProtoMessage {
        var request = UUProtoRpcRequest()
        request.header.requestID = id
        request.body = body
        var message = UUProtoMessage()
        message.body = .rpcRequest(request)
        return message
    }

    private func hostRich(id: UInt64, _ kind: UUProtoRichClipboardRequest.OneOf_Kind) -> UUProtoMessage {
        var rich = UUProtoRichClipboardRequest()
        rich.kind = kind
        return hostRequest(id: id, .richClipboard(rich))
    }

    func testAnUnknownHostGetsTheRichOfferThenTheText() throws {
        var clipboard = UUClipboard()
        let messages = clipboard.offer("héllo\nworld", hostIsMac: nil)
        XCTAssertEqual(messages.count, 2)
        // The rpc bodies the hand-written encoder produced.
        func rpc(_ data: Data) throws -> String {
            guard case let .rpcRequest(request) = try message(data).body else { return "" }
            return try request.serializedData().hex
        }
        XCTAssertEqual(try rpc(messages[0]), "0a0208654a220a200a02080d0a1a080012167075626c69632e757466382d706c61696e2d74657874")
        XCTAssertEqual(try rpc(messages[1]), "0a02086852100801120c68c3a96c6c6f0a776f726c64")
    }

    func testEachHostGetsItsOwnForm() throws {
        var clipboard = UUClipboard()
        let mac = clipboard.offer("hi", hostIsMac: true)
        XCTAssertEqual(mac.count, 1)
        guard case let .rpcRequest(request) = try message(mac[0]).body, case .richClipboard = request.body else { return XCTFail() }
        let windows = clipboard.offer("hi", hostIsMac: false)
        XCTAssertEqual(windows.count, 1)
        guard case let .rpcRequest(text) = try message(windows[0]).body, case let .clipboardText(change) = text.body else { return XCTFail() }
        XCTAssertEqual(change.format, 1)
        XCTAssertEqual(change.text, "hi")
    }

    func testLongTextGoesInChunksOnCharacterBoundaries() throws {
        var clipboard = UUClipboard()
        let text = String(repeating: "中", count: 3000) // 9000 bytes
        let parts = clipboard.offer(text, hostIsMac: false)
        XCTAssertEqual(parts.count, 2)
        var joined = ""
        for (index, part) in parts.enumerated() {
            guard case let .rpcRequest(request) = try message(part).body, case let .clipboardText(change) = request.body else { return XCTFail() }
            XCTAssertEqual(change.more, index == 0)
            joined += change.text
        }
        XCTAssertEqual(joined, text)
        XCTAssertTrue(clipboard.offer("", hostIsMac: nil).isEmpty)
        XCTAssertTrue(clipboard.offer(String(repeating: "x", count: UUClipboardLimit.maxText + 1), hostIsMac: nil).isEmpty)
    }

    func testInboundTextChangesReassembleAndTheLastIsAcknowledged() throws {
        var clipboard = UUClipboard()
        var first = UUProtoClipboardTextChangeRequest()
        first.format = 1
        first.text = "hello "
        first.more = true
        var second = first
        second.text = "world"
        second.more = false
        let partial = clipboard.receive(hostRequest(id: 1, .clipboardText(first)))
        XCTAssertNil(partial.text)
        XCTAssertTrue(partial.replies.isEmpty)
        let done = clipboard.receive(hostRequest(id: 2, .clipboardText(second)))
        XCTAssertEqual(done.text, "hello world")
        guard case let .rpcResponse(response) = try message(done.replies[0]).body, case let .clipboardText(ack) = response.body else { return XCTFail() }
        XCTAssertEqual(response.header.requestID, 2)
        XCTAssertEqual(ack.err, 1)

        var other = first
        other.format = 2
        other.more = false
        let ignored = clipboard.receive(hostRequest(id: 3, .clipboardText(other)))
        XCTAssertTrue(ignored.handled)
        XCTAssertNil(ignored.text)
    }

    func testTheOlderStreamReassembles() {
        var clipboard = UUClipboard()
        var change = UUProtoClipboardChange()
        change.id = 4
        change.text = "a"
        change.more = true
        var message = UUProtoMessage()
        message.body = .clipboardChange(change)
        XCTAssertNil(clipboard.receive(message).text)
        change.text = "b"
        change.more = false
        message.body = .clipboardChange(change)
        XCTAssertEqual(clipboard.receive(message).text, "ab")
    }

    /// The host offers, the viewer asks, the host confirms and sends the
    /// block: the text comes out in either format.
    func testAHostsOfferIsPulled() throws {
        for format in [UUClipboardFormat.windows, .mac] {
            for firstBlock in [0, 1] {
                var clipboard = UUClipboard()
                let original = "pull me 中文🙂\nsecond line"
                var list = UUProtoClipboardFormatList()
                list.formats = [format.offer]
                let asked = clipboard.receive(hostRich(id: 900, .formatList(list)))
                XCTAssertEqual(asked.replies.count, 2)
                guard case let .rpcRequest(request) = try message(asked.replies[1]).body,
                      case let .richClipboard(rich) = request.body,
                      case let .dataRequest(ask) = rich.kind
                else { return XCTFail("no data request") }
                XCTAssertEqual(ask.formatID, format.id)
                XCTAssertTrue(ask.hasFormatID)

                var confirm = UUProtoClipboardDataConfirm()
                confirm.status = 1
                confirm.key = ask.key
                confirm.blockCount = 1
                var richConfirm = UUProtoRichClipboardResponse()
                richConfirm.kind = .dataConfirm(confirm)
                var response = UUProtoRpcResponse()
                response.header.requestID = request.header.requestID
                response.body = .richClipboard(richConfirm)
                var confirmMessage = UUProtoMessage()
                confirmMessage.body = .rpcResponse(response)
                XCTAssertNil(clipboard.receive(confirmMessage).text)

                var block = UUProtoClipboardDataBlock()
                block.key = ask.key
                block.index = Int32(firstBlock)
                block.data = format.encode(original)
                let received = clipboard.receive(hostRich(id: 902, .dataBlock(block)))
                XCTAssertEqual(received.text, original, "\(format) from block \(firstBlock)")
                XCTAssertEqual(received.replies.count, 1)
            }
        }
    }

    func testTheHostsRequestForOurCopyIsAnsweredInBlocks() throws {
        var clipboard = UUClipboard()
        let original = "push 中文🙂\nline"
        _ = clipboard.offer(original, hostIsMac: true)
        var ask = UUProtoClipboardDataRequest()
        ask.formatID = 0
        ask.key = "host-key"
        ask.formatName = UUClipboardFormat.macName
        let answered = clipboard.receive(hostRich(id: 700, .dataRequest(ask)))
        XCTAssertEqual(answered.replies.count, 2)
        guard case let .rpcResponse(response) = try message(answered.replies[0]).body,
              case let .richClipboard(rich) = response.body,
              case let .dataConfirm(confirm) = rich.kind
        else { return XCTFail("no confirmation") }
        XCTAssertEqual(response.header.requestID, 700)
        XCTAssertEqual(confirm.status, 1)
        XCTAssertEqual(confirm.blockCount, 1)
        guard case let .rpcRequest(request) = try message(answered.replies[1]).body,
              case let .richClipboard(blockRich) = request.body,
              case let .dataBlock(block) = blockRich.kind
        else { return XCTFail("no block") }
        XCTAssertTrue(block.hasIndex)
        XCTAssertEqual(UUClipboardFormat.mac.decode(block.data), original)
    }

    func testWindowsTextIsUTF16WithCRLF() {
        let encoded = UUClipboardFormat.windows.encode("a\nb")
        XCTAssertEqual([UInt8](encoded), [0x61, 0, 0x0D, 0, 0x0A, 0, 0x62, 0, 0, 0])
        XCTAssertEqual(UUClipboardFormat.windows.decode(encoded), "a\nb")
    }
}
