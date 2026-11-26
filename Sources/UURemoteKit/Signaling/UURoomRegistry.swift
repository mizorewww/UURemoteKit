//
//  UURoomRegistry.swift
//  UURemoteKit
//
//  A device's room, joined once and shared. Joining a device's room
//  (`force_join`) takes it from whoever held it, an earlier join of ours
//  included, and the host then drops the sessions that came in through the
//  old one: a desktop opened next to a device's terminals cut every terminal
//  off. So every connection to a device asks for control over the same room
//  and signaling socket, each as a session of its own (its app_control_id,
//  ice_id and peer, which route the socket's soac to it), and the room is
//  left with the last of them.
//

import Foundation
import os

/// A connection's hold on its device's room. Given back with `leave`.
struct UURoomLease: Sendable {
    let room: UURoomRegistry.Room
    let listener: UUID
    let config: UURoomConfig
    var signal: UUSignalingClient { room.signal }
}

/// `[String: Any]` from JSONSerialization, carried across isolation.
struct UUJSON: @unchecked Sendable {
    let object: [String: Any]
    init(_ object: [String: Any]) { self.object = object }
}

/// What a room's socket receives, for its connections.
enum UUSignalMessage: Sendable {
    /// A Socket.IO event and its arguments.
    case event(String, [UUJSON])
    /// A `soac` message (offer, answer, candidate), plain or binary.
    case soac(UUJSON)
}

@MainActor
final class UURoomRegistry {
    /// One joined room and its socket; what arrives on it goes to every
    /// connection in the room, each keeping only its own.
    final class Room: Sendable {
        let key: String
        let signal = UUSignalingClient()
        private let state = OSAllocatedUnfairLock(initialState: State())

        private struct State {
            var listeners: [UUID: @Sendable (UUSignalMessage) -> Void] = [:]
            var dropped = false
        }

        /// The connections holding the room.
        @MainActor var users = 0
        /// The join and the socket's connect, once.
        @MainActor var joined: Task<UURoomConfig, Error>?

        init(key: String) { self.key = key }

        /// The socket is gone (or never came up): a new connection joins anew.
        var isDropped: Bool { state.withLock(\.dropped) }

        func markDropped() { state.withLock { $0.dropped = true } }

        /// Opens the socket; what it receives goes to the room's connections.
        func connect(_ config: UURoomConfig) async throws {
            await signal.setOnSignalEvent { [weak self] event, args, _ in
                self?.dispatch(.event(event, args.map(UUJSON.init)))
            }
            await signal.setOnSOAC { [weak self] soac in
                self?.dispatch(.soac(UUJSON(soac)))
            }
            await signal.setOnStateChange { [weak self] state in
                if case .error = state { self?.markDropped() }
            }
            try await signal.connect(roomConfig: config)
        }

        func addListener(_ id: UUID, _ listener: @escaping @Sendable (UUSignalMessage) -> Void) {
            state.withLock { $0.listeners[id] = listener }
        }

        func removeListener(_ id: UUID) {
            state.withLock { _ = $0.listeners.removeValue(forKey: id) }
        }

        private func dispatch(_ message: UUSignalMessage) {
            for listener in state.withLock({ Array($0.listeners.values) }) { listener(message) }
        }
    }

    private var rooms: [String: Room] = [:]
    private nonisolated static let log = Logger(subsystem: "UURemoteKit", category: "rooms")

    /// The target's room, joined and its socket connected if no connection
    /// holds it yet. `onMessage` gets everything the socket receives, for
    /// every connection in the room: each keeps what is routed to it.
    func join(_ target: UURemoteTarget, api: UUAPIClient, onMessage: @escaping @Sendable (UUSignalMessage) -> Void) async throws -> UURoomLease {
        let key = target.roomKey
        let room: Room
        if let existing = rooms[key], !existing.isDropped {
            room = existing
        } else {
            room = Room(key: key)
            rooms[key] = room
            room.joined = Task { @MainActor in
                do {
                    let config = target.isAssist
                        ? try await api.joinShareByCode(connectID: target.assistID, code: target.assistCode)
                        : try await api.roomJoinByDevice(target.deviceID, forceJoin: true)
                    try await room.connect(config)
                    Self.log.info("joined a room")
                    return config
                } catch {
                    room.markDropped()
                    Self.log.error("could not join a room: \(error.localizedDescription, privacy: .public)")
                    throw error
                }
            }
        }
        room.users += 1
        let listener = UUID()
        room.addListener(listener, onMessage)
        do {
            guard let joined = room.joined else { throw UUSignalError.notConnected }
            return UURoomLease(room: room, listener: listener, config: try await joined.value)
        } catch {
            leave(room: room, listener: listener)
            throw error
        }
    }

    /// One connection fewer in the room; the last one leaves it.
    func leave(_ lease: UURoomLease) {
        leave(room: lease.room, listener: lease.listener)
    }

    private func leave(room: Room, listener: UUID) {
        room.removeListener(listener)
        room.users -= 1
        guard room.users <= 0 else { return }
        if rooms[room.key] === room { rooms.removeValue(forKey: room.key) }
        let joined = room.joined
        Task {
            _ = try? await joined?.value
            await room.signal.disconnect()
        }
    }
}
