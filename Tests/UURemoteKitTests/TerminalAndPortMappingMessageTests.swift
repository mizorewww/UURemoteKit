import Foundation
import XCTest
@testable import UURemoteKit

final class TerminalAndPortMappingMessageTests: XCTestCase {
    func testTerminalFrameHeaderLayoutAndRoundTrip() throws {
        let frame = UUTerminalFrame(kind: .stdin, sessionID: 0x0102_0304, payload: Data("ls\n".utf8))
        let encoded = frame.encode()
        XCTAssertEqual(encoded.hex, "5445524d" + "01" + "02" + "0000" + "04030201" + "03000000" + "6c730a")
        XCTAssertEqual(UUTerminalFrame(decoding: encoded), frame)
        XCTAssertNil(UUTerminalFrame(decoding: encoded.dropLast()))
        XCTAssertNil(UUTerminalFrame(decoding: Data("TERX".utf8) + encoded.dropFirst(4)))
        XCTAssertNil(UUTerminalFrame(decoding: Data()))
    }

    func testTerminalJSON() throws {
        let open = try JSONSerialization.jsonObject(with: UUTerminalJSON.open(cols: 80, rows: 24, shell: "C:\\Windows\\cmd.exe")) as? [String: Any]
        XCTAssertEqual(open?["shell"] as? String, "C:\\Windows\\cmd.exe")
        XCTAssertEqual(open?["option"] as? String, "none")
        XCTAssertEqual(UUTerminalJSON.openResponse(Data(#"{"code":3,"message":"no"}"#.utf8)), .init(code: 3, message: "no"))
        XCTAssertEqual(UUTerminalJSON.exitCode(Data(#"{"exit_code":1}"#.utf8)), 1)
    }

    func testSessionListIsMostRecentFirstAndSkipsBadEntries() {
        let payload = Data(#"[{"session_id":1,"name":"a","state":"detached","last_active_ms":1000},{"name":"broken"},{"session_id":2,"name":"b","state":"running","last_active_ms":5000}]"#.utf8)
        let sessions = UUTerminalSession.list(from: payload)
        XCTAssertEqual(sessions?.map(\.id), [2, 1])
        XCTAssertEqual(sessions?.last?.isDetached, true)
        XCTAssertNil(UUTerminalSession.list(from: Data("{}".utf8)))
    }

    func testPortMappingFramesMatchTheHandWrittenEncoder() {
        let key = UUPortMappingKey(session: 1, rule: 2, stream: 3)
        XCTAssertEqual(
            UUControl.envelope(sequence: 1, timestamp: 1_700_000_000, .portMappingFrame(key.frame(.syn, payload: Data("{}".utf8)))).hex,
            "08011080e2cfaa06da010a0801100218032a027b7d"
        )
        XCTAssertEqual(
            UUControl.envelope(sequence: 2, timestamp: 1_700_000_000, .portMappingFrame(key.frame(.data, payload: Data([1, 2, 3])))).hex,
            "08021080e2cfaa06da010d08011002180320022a03010203"
        )
    }

    func testPortMappingJSONEscapesTheHost() throws {
        let syn = UUPortMappingSYN(targetHost: #"evil","target_port":1,"x":""#, targetPort: 22)
        let decoded = try JSONDecoder().decode(UUPortMappingSYN.self, from: syn.data)
        XCTAssertEqual(decoded, syn)
        XCTAssertEqual(UUPortMappingSYNACK(Data(#"{"version":1,"ok":false,"error":"refused"}"#.utf8))?.error, "refused")
        XCTAssertNil(UUPortMappingSYNACK(Data("nope".utf8)))
    }

    func testOpenFailuresAndExitCodesAreReadFromTheirFrames() {
        let refused = UUTerminalFrame(kind: .openResponse, sessionID: 1, payload: Data(#"{"code":3,"message":"no shell"}"#.utf8))
        XCTAssertEqual(refused.openFailure?.code, 3)
        XCTAssertEqual(refused.openFailure?.message, "no shell")
        XCTAssertNil(UUTerminalFrame(kind: .openResponse, sessionID: 1, payload: Data(#"{"code":0}"#.utf8)).openFailure)
        XCTAssertEqual(UUTerminalFrame(kind: .exit, sessionID: 1, payload: Data(#"{"exit_code":2}"#.utf8)).exitCode, 2)
        XCTAssertNil(UUTerminalFrame(kind: .stdout, sessionID: 1, payload: Data(#"{"exit_code":2}"#.utf8)).exitCode)
    }
}
