//
//  UURemoteConnections.swift
//  UURemoteKit
//
//  An account's connections, one control session per device. The host
//  keeps one per viewer: asking for control a second time (a terminal's,
//  while the screen streams) ends the first. So while a desktop is open,
//  the device's terminals and port-mapped streams ride on the desktop's
//  connection; a terminal connection is made only when no desktop is open,
//  and closes a few seconds after the last terminal or stream on it.
//

import Foundation
import os

@MainActor
public final class UURemoteConnections {
    public let account: UURemoteAccount
    private let transportFactory: UUPeerTransportFactory
    /// How long a terminal connection outlives its last user: what that
    /// user sent last goes out first, and a terminal opened meanwhile takes
    /// the connection over.
    let linger: Duration

    private struct Entry {
        let connection: UURemoteConnection
        var users: Int
    }

    /// The connection terminals and streams use, by device.
    private var entries: [String: Entry] = [:]
    /// Each device's open desktop.
    private var desktops: [String: UURemoteConnection] = [:]
    private static let log = Logger(subsystem: "UURemoteKit", category: "connections")

    public init(account: UURemoteAccount, transportFactory: @escaping UUPeerTransportFactory = UUWebRTCTransport.factory, linger: Duration = .seconds(3)) {
        self.account = account
        self.transportFactory = transportFactory
        self.linger = linger
    }

    /// A desktop connection to the target, not yet started. While it is
    /// open, the device's terminals and streams use it.
    public func desktop(
        for target: UURemoteTarget,
        settings: UUStreamSettings = UUStreamSettings(),
        localRefreshRate: Int = 60,
        preferredScreenID: Int? = nil,
        playsAudio: Bool = false
    ) -> UURemoteConnection {
        let connection = make(target, purpose: .desktop, settings: settings, localRefreshRate: localRefreshRate, preferredScreenID: preferredScreenID, playsAudio: playsAudio)
        let key = target.deviceID
        desktops[key] = connection
        connection.onStop = { [weak self, weak connection] in
            guard let self, let connection, self.desktops[key] === connection else { return }
            self.desktops.removeValue(forKey: key)
        }
        return connection
    }

    private func make(_ target: UURemoteTarget, purpose: UUConnectionPurpose, settings: UUStreamSettings, localRefreshRate: Int, preferredScreenID: Int?, playsAudio: Bool) -> UURemoteConnection {
        UURemoteConnection(account: account, target: target, purpose: purpose, settings: settings, localRefreshRate: localRefreshRate, preferredScreenID: preferredScreenID, playsAudio: playsAudio, transportFactory: transportFactory)
    }

    /// The device's connection for terminals and streams, ready: its open
    /// desktop's, or one of its own, made if there is none. Pair with
    /// `release(_:)`.
    public func acquire(_ target: UURemoteTarget, timeout: Duration = .seconds(30)) async throws -> UURemoteConnection {
        let key = target.deviceID
        let connection: UURemoteConnection
        if var entry = entries[key], !entry.connection.isClosed {
            entry.users += 1
            entries[key] = entry
            connection = entry.connection
        } else if let desktop = desktops[key], !desktop.isClosed {
            Self.log.info("terminals ride on the desktop's connection")
            entries[key] = Entry(connection: desktop, users: 1)
            connection = desktop
        } else {
            connection = make(target, purpose: .terminal, settings: UUStreamSettings(), localRefreshRate: 60, preferredScreenID: nil, playsAudio: false)
            entries[key] = Entry(connection: connection, users: 1)
            connection.start()
        }
        do {
            try await connection.waitUntilReady(timeout: timeout)
        } catch {
            release(connection)
            throw error
        }
        return connection
    }

    /// One user fewer. A terminal connection closes `linger` after its last
    /// user; a desktop's is the desktop's to close. A connection the device
    /// no longer uses (it dropped and was replaced) leaves the new one alone.
    public func release(_ connection: UURemoteConnection) {
        let key = connection.target.deviceID
        guard var entry = entries[key], entry.connection === connection else {
            if connection.purpose == .terminal { connection.stop() }
            return
        }
        entry.users -= 1
        entries[key] = entry
        guard entry.users <= 0 else { return }
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.linger)
            guard let current = self.entries[key], current.connection === connection, current.users <= 0 else { return }
            self.entries.removeValue(forKey: key)
            if connection.purpose == .terminal { connection.stop() }
        }
    }

    /// The device's terminal sessions, most recently used first.
    public func terminalSessions(on target: UURemoteTarget) async throws -> [UUTerminalSession] {
        let connection = try await acquire(target)
        defer { release(connection) }
        guard let sessions = await connection.listTerminalSessions() else {
            throw UURemoteFailure("The device did not list its terminal sessions.")
        }
        return sessions
    }

    /// Ends a session no terminal here is attached to.
    public func endTerminalSession(_ id: UInt32, on target: UURemoteTarget) async throws {
        let connection = try await acquire(target)
        defer { release(connection) }
        connection.closeTerminal(id)
    }

    /// A port-mapped TCP stream to a service on the device; the device's
    /// connection stays while the stream is open. Returns one end of a
    /// socket pair, which the caller closes.
    public func openStream(to target: UURemoteTarget, host: String, port: UInt16, timeout: Duration = .seconds(20)) async throws -> Int32 {
        // Joining the room takes longer than a TCP connect; `timeout` is
        // for the stream.
        let connection = try await acquire(target, timeout: max(timeout, .seconds(30)))
        do {
            return try await connection.openPortMapping(host: host, port: port, timeout: timeout) { [weak self] in
                Task { @MainActor in self?.release(connection) }
            }
        } catch {
            release(connection)
            throw error
        }
    }

    /// What the device's connection is doing, for a terminal waiting on it.
    public func status(of target: UURemoteTarget) -> String {
        entries[target.deviceID]?.connection.statusHint ?? ""
    }

    /// Whether a connection holds the device (open or lingering).
    func holds(_ target: UURemoteTarget) -> Bool {
        entries[target.deviceID] != nil
    }
}
