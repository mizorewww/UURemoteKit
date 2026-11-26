import Foundation
import XCTest
@testable import UURemoteKit

final class ConnectionTests: XCTestCase {
    func testTheControlAcknowledgementIsReadForThisSession() throws {
        let ack = Data(#"["success",{"app_control_id":"a","client_id":"c","ice_id":"i","force_relay":true,"iceServers":[{"urls":"turn:t","username":"u","credential":"p"},{"urls":["stun:s1","stun:s2"]},{"urls":[]}]}]"#.utf8)
        let result = try UURemoteConnection.controlResult(ack, appControlID: "a")
        XCTAssertEqual(result["client_id"] as? String, "c")
        XCTAssertEqual(UURemoteConnection.iceServers(from: result), [
            UUIceServer(urls: ["turn:t"], username: "u", credential: "p"),
            UUIceServer(urls: ["stun:s1", "stun:s2"]),
        ])
        XCTAssertThrowsError(try UURemoteConnection.controlResult(ack, appControlID: "other"))
        XCTAssertThrowsError(try UURemoteConnection.controlResult(Data(#"["success",{"code":5,"msg":"busy"}]"#.utf8), appControlID: "a"))
        XCTAssertThrowsError(try UURemoteConnection.controlResult(Data("[]".utf8), appControlID: "a"))
    }

    func testANewTerminalSessionTakesNoListedID() {
        let taken = Set<UInt32>(1 ... 100)
        for _ in 0 ..< 100 { XCTAssertFalse(taken.contains(UURemoteConnection.newSessionID(avoiding: taken))) }
    }

    func testTheTrackInViewIsFollowedAndASilentGuessGivesWay() {
        var view = TrackView()
        let start = Date()
        // None chosen: the first to send.
        XCTAssertTrue(view.accepts("1", now: start))
        XCTAssertFalse(view.accepts("2", now: start.addingTimeInterval(1)))
        // A guess that goes silent gives way to one that sends.
        XCTAssertTrue(view.accepts("2", now: start.addingTimeInterval(3)))
        // The answer names the screen's track: that one, for certain.
        XCTAssertTrue(view.follow("3", certain: true, leaving: false))
        XCTAssertFalse(view.follow("3", certain: true, leaving: false))
        XCTAssertTrue(view.accepts("3", now: start.addingTimeInterval(4)))
        XCTAssertFalse(view.accepts("2", now: start.addingTimeInterval(10)), "a named track that sent keeps the view")
        // Leaving for a screen whose track is unknown: the next track, not the old one.
        XCTAssertTrue(view.follow(nil, certain: false, leaving: true))
        XCTAssertFalse(view.accepts("3", now: Date()))
        XCTAssertTrue(view.accepts("4", now: Date()))
    }

    @MainActor
    func testASignedOutAccountFailsWithoutReachingTheService() async throws {
        let account = UURemoteAccount(storage: UUMemoryCredentialStorage(), clientName: "Rayon")
        let connections = UURemoteConnections(account: account, transportFactory: { _, _ in
            XCTFail("no transport without an account")
            throw UURemoteFailure("unreachable")
        }, linger: .milliseconds(10))
        let desktop = connections.desktop(for: UURemoteTarget(deviceID: "device"))
        var phases: [UURemotePhase] = []
        desktop.onEvent = { if case let .phase(phase) = $0 { phases.append(phase) } }
        desktop.start()
        do {
            try await desktop.waitUntilReady(timeout: .seconds(2))
            XCTFail("ready")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Sign in"))
        }
        XCTAssertTrue(desktop.isClosed)
        XCTAssertTrue(phases.contains(.failed("Sign in to UU Remote to connect.")))
        // Terminals fail the same way, on a connection of their own.
        do {
            _ = try await connections.acquire(UURemoteTarget(deviceID: "device"), timeout: .seconds(2))
            XCTFail("acquired")
        } catch {}
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(connections.holds(UURemoteTarget(deviceID: "device")))
    }
}
