import Darwin
import Foundation
import os
import XCTest
@testable import UURemoteKit

/// A host that answers every SYN and echoes every DATA back, played
/// against the tunnel over its envelopes.
private final class EchoHost: Sendable {
    let sent = OSAllocatedUnfairLock(initialState: [UUProtoPortMappingFrame]())
    let refuse: Bool
    let tunnel = OSAllocatedUnfairLock<UUPortMappingTunnel?>(initialState: nil)

    init(refuse: Bool = false) { self.refuse = refuse }

    func receive(_ envelope: Data) {
        guard let message = try? UUProtoMessage(serializedBytes: envelope),
              case let .portMappingFrame(frame) = message.body else { return }
        sent.withLock { $0.append(frame) }
        let key = UUPortMappingKey(frame)
        let reply: UUProtoPortMappingFrame?
        switch frame.type {
        case .syn:
            let ack = refuse ? #"{"version":1,"ok":false,"error":"nothing listens"}"# : #"{"version":1,"ok":true}"#
            reply = key.frame(.synAck, payload: Data(ack.utf8))
        case .data:
            reply = key.frame(.data, payload: frame.payload)
        default:
            reply = nil
        }
        guard let reply, let tunnel = tunnel.withLock({ $0 }) else { return }
        DispatchQueue.global().async { tunnel.handle(reply) }
    }
}

final class PortMappingTunnelTests: XCTestCase {
    private func makeTunnel(refuse: Bool = false) -> (UUPortMappingTunnel, EchoHost) {
        let host = EchoHost(refuse: refuse)
        let tunnel = UUPortMappingTunnel { host.receive($0) }
        host.tunnel.withLock { $0 = tunnel }
        return (tunnel, host)
    }

    private func readAll(_ fd: Int32, count: Int) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < count {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { break }
            data.append(contentsOf: buffer[0 ..< n])
        }
        return data
    }

    func testAStreamCarriesBytesBothWays() async throws {
        let (tunnel, host) = makeTunnel()
        let fd = try await tunnel.openStream(host: "127.0.0.1", port: 22, timeout: .seconds(2))
        let message = Data((0 ..< 100_000).map { UInt8($0 % 251) })
        let writer = Task.detached {
            message.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count { offset += max(0, write(fd, raw.baseAddress! + offset, raw.count - offset)) }
            }
        }
        let echoed = readAll(fd, count: message.count)
        await writer.value
        XCTAssertEqual(echoed, message)
        let syn = try XCTUnwrap(host.sent.withLock { $0.first })
        XCTAssertEqual(try JSONDecoder().decode(UUPortMappingSYN.self, from: syn.payload).targetPort, 22)
        close(fd)
    }

    func testClosingOurEndTellsTheHost() async throws {
        let (tunnel, host) = makeTunnel()
        let closed = expectation(description: "onClose")
        let fd = try await tunnel.openStream(host: "127.0.0.1", port: 22, timeout: .seconds(2)) { closed.fulfill() }
        close(fd)
        await fulfillment(of: [closed], timeout: 2)
        XCTAssertTrue(host.sent.withLock { $0.contains { $0.type == .fin } })
    }

    func testTheHostsFINEndsTheStream() async throws {
        let (tunnel, _) = makeTunnel()
        let fd = try await tunnel.openStream(host: "127.0.0.1", port: 22, timeout: .seconds(2))
        tunnel.handle(UUPortMappingKey(session: 1, rule: 1, stream: 1).frame(.fin))
        var byte: UInt8 = 0
        XCTAssertEqual(read(fd, &byte, 1), 0, "end of stream")
        close(fd)
    }

    func testARefusalAndASilentHostFail() async throws {
        let (refusing, _) = makeTunnel(refuse: true)
        do {
            _ = try await refusing.openStream(host: "127.0.0.1", port: 22, timeout: .seconds(2))
            XCTFail("opened")
        } catch let failure as UUPortMappingFailure {
            XCTAssertEqual(failure.message, "nothing listens")
        }
        let silent = UUPortMappingTunnel { _ in }
        do {
            _ = try await silent.openStream(host: "127.0.0.1", port: 22, timeout: .milliseconds(100))
            XCTFail("opened")
        } catch {}
    }

    func testShutdownEndsOpensInFlightAndStreams() async throws {
        let silent = UUPortMappingTunnel { _ in }
        let opening = Task { try await silent.openStream(host: "h", port: 1, timeout: .seconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        silent.shutdown()
        do {
            _ = try await opening.value
            XCTFail("opened")
        } catch {}
        do {
            _ = try await silent.openStream(host: "h", port: 1, timeout: .seconds(1))
            XCTFail("opened after shutdown")
        } catch {}
    }

    /// A host that speaks first, like sshd with its banner: its DATA comes
    /// right behind the SYN-ACK, before the opener has resumed.
    func testDataRightBehindTheSYNACKIsKept() async throws {
        let banner = Data("SSH-2.0-OpenSSH_9.9\r\n".utf8)
        let tunnel = OSAllocatedUnfairLock<UUPortMappingTunnel?>(initialState: nil)
        let opener = UUPortMappingTunnel { envelope in
            guard let message = try? UUProtoMessage(serializedBytes: envelope),
                  case let .portMappingFrame(frame) = message.body, frame.type == .syn,
                  let tunnel = tunnel.withLock({ $0 }) else { return }
            let key = UUPortMappingKey(frame)
            DispatchQueue.global().async {
                tunnel.handle(key.frame(.synAck, payload: Data(#"{"version":1,"ok":true}"#.utf8)))
                tunnel.handle(key.frame(.data, payload: banner))
            }
        }
        tunnel.withLock { $0 = opener }
        for _ in 0 ..< 50 {
            let fd = try await opener.openStream(host: "127.0.0.1", port: 22, timeout: .seconds(2))
            // A lost banner fails the read instead of hanging the test.
            var wait = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
            XCTAssertEqual(readAll(fd, count: banner.count), banner)
            close(fd)
        }
    }

    /// Streams closed by the host while data for them is in flight: every
    /// descriptor is closed once, and no write lands on a closed one.
    func testClosingUnderTrafficNeverTouchesAClosedDescriptor() async throws {
        let (tunnel, _) = makeTunnel()
        for round in 0 ..< 50 {
            let fd = try await tunnel.openStream(host: "h", port: 1, timeout: .seconds(2))
            let key = UUPortMappingKey(session: UInt64(round + 1), rule: UInt64(round + 1), stream: UInt64(round + 1))
            DispatchQueue.concurrentPerform(iterations: 20) { index in
                if index == 10 { tunnel.handle(key.frame(.fin)) } else { tunnel.handle(key.frame(.data, payload: Data([1]))) }
            }
            close(fd)
        }
    }
}
