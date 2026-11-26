//
//  UUPortMappingTunnel.swift
//  UURemoteKit
//
//  TCP streams to ports on the host, carried in PortMappingFrames on the
//  connection's FILE_DATA_CHANNEL. Each stream is one end of a socket pair:
//  the caller (an SSH library, say) reads and writes the other end as if it
//  were a TCP socket.
//

import Darwin
import Foundation
import os

public struct UUPortMappingFailure: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

final class UUPortMappingTunnel: Sendable {
    /// Sends a complete envelope on FILE_DATA_CHANNEL.
    typealias Send = @Sendable (Data) -> Void

    /// One open stream: our end of the socket pair, read by a dispatch
    /// source and written on the same queue. The source's cancel handler is
    /// the one place the descriptor is closed, after every read and write
    /// queued before it: nothing reads or writes a descriptor number that
    /// has been closed (and perhaps handed out again).
    private final class Stream: Sendable {
        let key: UUPortMappingKey
        let fd: Int32
        let queue: DispatchQueue
        let source: DispatchSourceRead
        let onClose: (@Sendable () -> Void)?

        init(key: UUPortMappingKey, fd: Int32, onClose: (@Sendable () -> Void)?) {
            self.key = key
            self.fd = fd
            self.onClose = onClose
            queue = DispatchQueue(label: "UURemoteKit.port-mapping.\(key.stream)")
            source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        }
    }

    private struct State {
        var streams: [UUPortMappingKey: Stream] = [:]
        var pending: [UUPortMappingKey: CheckedContinuation<Void, Error>] = [:]
        var sequence: UInt64 = 0
        var nextID: UInt64 = 1
        var closed = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let send: Send
    private static let log = Logger(subsystem: "UURemoteKit", category: "port-mapping")

    init(send: @escaping Send) {
        self.send = send
    }

    private func send(_ frame: UUProtoPortMappingFrame) {
        let sequence = state.withLock { state -> UInt64 in
            state.sequence += 1
            return state.sequence
        }
        send(UUControl.envelope(sequence: sequence, timestamp: UUControl.nowSeconds, .portMappingFrame(frame)))
    }

    /// A frame from the host.
    func handle(_ frame: UUProtoPortMappingFrame) {
        let key = UUPortMappingKey(frame)
        switch frame.type {
        case .synAck:
            guard let ack = UUPortMappingSYNACK(frame.payload),
                  let waiter = state.withLock({ $0.pending.removeValue(forKey: key) })
            else { return }
            if ack.ok {
                waiter.resume()
            } else {
                waiter.resume(throwing: UUPortMappingFailure(ack.error ?? "The host refused the connection."))
            }
        case .data:
            guard let stream = state.withLock({ $0.streams[key] }) else { return }
            let payload = frame.payload
            stream.queue.async { [weak self] in
                guard !stream.source.isCancelled else { return }
                if !Self.write(payload, to: stream.fd) { self?.close(key, sendFIN: true) }
            }
        case .fin:
            // A FIN instead of a SYN-ACK fails the open; its opener tears
            // the stream down.
            if let waiter = state.withLock({ $0.pending.removeValue(forKey: key) }) {
                waiter.resume(throwing: UUPortMappingFailure("The host closed the port mapping."))
            } else {
                close(key, sendFIN: false)
            }
        case .syn, .dataAck, .UNRECOGNIZED:
            // A host's own forwards (SYN) are not ours to take.
            break
        }
    }

    private static func write(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, base + offset, raw.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    /// A stream to `host:port` as the host sees it. Returns the caller's end
    /// of a socket pair, which the caller closes; `onClose` runs once the
    /// stream has ended.
    ///
    /// The stream is registered before the SYN goes out: a host that speaks
    /// first (sshd's banner) sends DATA right behind its SYN-ACK, and those
    /// bytes wait in the socket pair until the caller reads them.
    func openStream(host: String, port: UInt16, timeout: Duration, onClose: (@Sendable () -> Void)? = nil) async throws -> Int32 {
        let key = try state.withLock { state -> UUPortMappingKey in
            guard !state.closed else { throw UUPortMappingFailure("The UU Remote connection closed.") }
            defer { state.nextID += 1 }
            return UUPortMappingKey(session: state.nextID, rule: state.nextID, stream: state.nextID)
        }
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw UUPortMappingFailure("Could not make a socket pair (errno \(errno)).")
        }
        for fd in pair {
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        }
        let stream = Stream(key: key, fd: pair[1], onClose: onClose)
        stream.source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            let count = buffer.withUnsafeMutableBytes { read(stream.fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR || errno == EAGAIN { return }
            guard count > 0, let self else {
                self?.close(key, sendFIN: true)
                return
            }
            self.send(key.frame(.data, payload: Data(buffer[0 ..< count])))
        }
        stream.source.setCancelHandler {
            Darwin.close(stream.fd)
        }
        // Nothing can be read yet: the caller's end is not handed out.
        stream.source.resume()

        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.state.withLock { $0.pending.removeValue(forKey: key) }?
                .resume(throwing: UUPortMappingFailure("The host did not answer the port mapping in time."))
        }
        defer { timer.cancel() }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let open = state.withLock { state -> Bool in
                    guard !state.closed else { return false }
                    state.pending[key] = continuation
                    state.streams[key] = stream
                    return true
                }
                guard open else {
                    return continuation.resume(throwing: UUPortMappingFailure("The UU Remote connection closed."))
                }
                send(key.frame(.syn, payload: UUPortMappingSYN(targetHost: host, targetPort: port).data))
            }
        } catch {
            // Refused, timed out or cut off: the stream never opened, so
            // there is no FIN to send and no `onClose` to run.
            state.withLock { _ = $0.streams.removeValue(forKey: key) }
            stream.source.cancel()
            Darwin.close(pair[0])
            throw error
        }
        return pair[0]
    }

    /// Ends one stream: the reader stops, our end is closed, and the host
    /// is told when it was us who ended it.
    private func close(_ key: UUPortMappingKey, sendFIN: Bool) {
        guard let stream = state.withLock({ $0.streams.removeValue(forKey: key) }) else { return }
        stream.source.cancel()
        if sendFIN { send(key.frame(.fin)) }
        stream.onClose?()
    }

    /// Ends every stream and every open in flight: the connection is gone.
    func shutdown() {
        let (streams, pending) = state.withLock { state in
            state.closed = true
            defer {
                state.streams.removeAll()
                state.pending.removeAll()
            }
            // Streams still opening are torn down by their opener.
            let open = state.streams.values.filter { state.pending[$0.key] == nil }
            return (open, Array(state.pending.values))
        }
        for waiter in pending { waiter.resume(throwing: UUPortMappingFailure("The UU Remote connection closed.")) }
        for stream in streams {
            stream.source.cancel()
            stream.onClose?()
        }
    }
}
