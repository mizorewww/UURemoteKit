import Compression
import Foundation
import XCTest
@testable import UURemoteKit

final class SignalingTests: XCTestCase {
    /// gzip of three lines of SDP, with a file name in its header.
    private let gzipSDP = Data(hex: "1f8b08080000000000ff7364702e747874002bb335e0e5cab7d55530543052f0f453f00c3051303432d7330042435eae625b5d5eae322aa90100c11bac796c000000")
    private let sdpText = String(repeating: "v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\ns=-\r\n", count: 3)

    func testGzipIsReadPastItsHeaderAndCheckedAgainstItsSize() throws {
        XCTAssertEqual(String(decoding: try UUGzip.decompress(gzipSDP), as: UTF8.self), sdpText)
        XCTAssertThrowsError(try UUGzip.decompress(Data("plain".utf8)))
        XCTAssertThrowsError(try UUGzip.decompress(gzipSDP.dropLast(9)))
        XCTAssertThrowsError(try UUGzip.decompress(gzipSDP, limit: 16))
        var wrongSize = gzipSDP
        wrongSize[wrongSize.count - 4] ^= 1
        XCTAssertThrowsError(try UUGzip.decompress(wrongSize))
    }

    /// A member that inflates past the cap fails as too large.
    func testAGzipBombStopsAtTheCap() throws {
        var deflated = Data()
        let filter = try OutputFilter(.compress, using: .zlib) { deflated.append($0 ?? Data()) }
        try filter.write(Data(count: 32 * 1024 * 1024))
        try filter.finalize()
        // Header, raw DEFLATE, then a CRC (unchecked) and ISIZE 2^25 mod 2^32.
        let bomb = Data(hex: "1f8b08000000000000ff") + deflated + Data(hex: "00000000" + "00000002")
        XCTAssertEqual(try UUGzip.decompress(bomb, limit: 32 * 1024 * 1024).count, 32 * 1024 * 1024)
        XCTAssertThrowsError(try UUGzip.decompress(bomb, limit: 1024 * 1024)) { error in
            guard case UUGzip.Failure.tooLarge = error else { return XCTFail("\(error)") }
        }
    }

    func testEngineIOPackets() throws {
        guard case let .open(open) = try UUEngineIO.decode(#"0{"sid":"x","pingInterval":25000}"#) else { return XCTFail() }
        XCTAssertEqual(open["sid"] as? String, "x")
        guard case let .ping(probe) = try UUEngineIO.decode("2probe") else { return XCTFail() }
        XCTAssertEqual(probe, "probe")
        XCTAssertEqual(UUEngineIO.encodePong("probe"), "3probe")
        XCTAssertThrowsError(try UUEngineIO.decode(""))
    }

    func testSocketIOEventsAndAcks() throws {
        let encoded = try UUEngineIO.encodeEvent("be-controlled", args: [["a": 1]], id: 5)
        XCTAssertTrue(encoded.hasPrefix("425"))
        guard case let .message(.event(_, id, event, args, _)) = try UUEngineIO.decode(encoded) else { return XCTFail() }
        XCTAssertEqual(id, 5)
        XCTAssertEqual(event, "be-controlled")
        XCTAssertEqual(args.count, 1)

        let binary = try UUEngineIO.encodeBinaryEvent("control", args: [["k": "v"]], id: 9, attachmentCount: 1)
        XCTAssertTrue(binary.hasPrefix("451-9"))

        // The server answers a `451-<id>` emit with `45<id>[…]`.
        guard case let .message(.ack(_, ackID, ackArgs)) = try UUEngineIO.decode(#"4512["success",{"code":0}]"#) else { return XCTFail() }
        XCTAssertEqual(ackID, 12)
        XCTAssertEqual(ackArgs.first as? String, "success")

        guard case let .message(.binaryEvent(_, eventID, name, _, attachments)) = try UUEngineIO.decode(#"451-33["control",{"app_data":{"_placeholder":true,"num":0}}]"#) else { return XCTFail() }
        XCTAssertEqual(eventID, 33)
        XCTAssertEqual(name, "control")
        XCTAssertEqual(attachments, 1)
    }

    /// A soac reaches the room once, plain or with a binary attachment,
    /// whose placeholder becomes the attachment's base64.
    func testSOACIsDeliveredOnceWithItsAttachmentHydrated() async {
        final class Box: @unchecked Sendable { var soacs: [[String: Any]] = [] }
        let client = UUSignalingClient()
        let box = Box()
        await client.setOnSOAC { box.soacs.append($0) }
        await client.handleSocketPacket(.event(namespace: "/", id: nil, event: "soac", args: [["sdp": "plain"]], binary: []))
        XCTAssertEqual(box.soacs.count, 1)
        await client.handleSocketPacket(.binaryEvent(namespace: "/", id: nil, event: "soac", args: [["gzip_sdp": ["_placeholder": true, "num": 0]]], attachmentCount: 1))
        XCTAssertEqual(box.soacs.count, 1)
        await client.handleBinaryFrame(Data([0x04]) + gzipSDP)
        XCTAssertEqual(box.soacs.count, 2)
        XCTAssertEqual(box.soacs.last?["gzip_sdp"] as? String, gzipSDP.base64EncodedString())
    }

    func testAConnectThatNeverOpensFailsInsteadOfHanging() async {
        let client = UUSignalingClient()
        var config = UURoomConfig()
        config.token = "t"
        config.signalServers = ["ws://127.0.0.1:9"]
        config.timeout = 2000
        do {
            try await client.connect(roomConfig: config)
            XCTFail("connected to nothing")
        } catch {}
    }
}
