//
//  UURemoteConnection.swift
//  UURemoteKit
//
//  One control session with a device: the room's signaling, the host's
//  control acknowledgement, the peer connection, and what runs on it — the
//  desktop's screens, video, cursor, input and clipboard, terminals, and
//  port-mapped TCP streams.
//
//  The host keeps one control session per viewer: asking for control again
//  ends the first. A device's terminals and streams therefore ride on its
//  open desktop's connection; `UURemoteConnections` hands them out.
//

import Combine
import CoreGraphics
import Foundation
import os

public enum UURemotePhase: Equatable, Sendable {
    case connecting(String)
    case connected
    /// Connected, and the host's screen is locked.
    case locked
    case failed(String)
    case closed
}

public enum UURemoteEvent: Sendable {
    case phase(UURemotePhase)
    /// What the connection is doing, for a status line.
    case hint(String)
    /// The host's screens and the one in view.
    case screens([UUScreen], selected: Int?)
    /// The host's pointer, placed on the screen in view.
    case cursor(UUCursor)
    case roundTrip(milliseconds: Int)
    case network(UUNetworkStats)
    /// Text the host copied.
    case remoteClipboard(String)
    case notice(String)
    /// The host changed what was asked for, and says why.
    case streamChanged(UUStreamSettings, notice: String)
    /// The host kept its picture settings; these are back in force.
    case streamRefused(UUStreamSettings, reason: String)
}

public struct UURemoteFailure: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

@MainActor
public final class UURemoteConnection: ObservableObject {
    public let target: UURemoteTarget
    public let purpose: UUConnectionPurpose
    /// Events, on the main actor.
    public var onEvent: ((UURemoteEvent) -> Void)?
    /// Decoded frames of the screen in view, as they come, off the main
    /// actor. Set before `start()`.
    public nonisolated var onFrame: (@Sendable (UUVideoFrame) -> Void)? {
        get { frameSink.withLock { $0?.deliver } }
        set { frameSink.withLock { $0 = newValue.map(FrameSink.init) } }
    }

    public private(set) var phase: UURemotePhase = .connecting("")
    @Published public private(set) var statusHint = ""
    /// The host runs Windows (unknown hosts are taken for Windows, the
    /// common case): its keys are Windows virtual-key codes, not Mac ones.
    public private(set) var hostIsWindows = true
    /// Control and binary channels are open: terminals can start.
    public var isReady: Bool { open.contains(.control) && open.contains(.binary) && !isClosed }
    /// Published, so what runs on the connection hears it close.
    @Published public private(set) var isClosed = false

    private let account: UURemoteAccount
    private let transportFactory: UUPeerTransportFactory
    private let playsAudio: Bool
    private var hostPlatformKnown = false
    private var lease: UURoomLease?
    private var transport: UUPeerTransport?
    private var open: Set<UUDataChannel> = []
    private let sequence = OSAllocatedUnfairLock(initialState: UInt64(0))
    /// The closure sits in a struct: a bare closure as the lock's generic
    /// state is reabstracted on its way in and out of each `withLock`, and
    /// the inout write-back stores it wrapped once more, so every frame
    /// would add a layer until the decoder's thread ran out of stack.
    private let frameSink = OSAllocatedUnfairLock<FrameSink?>(initialState: nil)
    private struct FrameSink: Sendable {
        let deliver: @Sendable (UUVideoFrame) -> Void
    }
    private lazy var tunnel = UUPortMappingTunnel { [weak self] envelope in
        self?.sendFromAnyThread(envelope, on: .file)
    }
    private var tasks: [Task<Void, Never>] = []
    private var readyWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    /// Called once stopped, for the registry.
    var onStop: (() -> Void)?
    private static let log = Logger(subsystem: "UURemoteKit", category: "connection")

    // Routing: the room's socket carries every session on the device.
    private var appControlID = ""
    private var iceID = ""
    private var remoteClientID = ""
    private var answered = false
    private var earlyCandidates: [UUIceCandidate] = []
    private var iceState: UUIceState = .other

    /// Called by the registry for each new connection.
    init(account: UURemoteAccount, target: UURemoteTarget, purpose: UUConnectionPurpose, settings: UUStreamSettings, localRefreshRate: Int, preferredScreenID: Int?, playsAudio: Bool, transportFactory: @escaping UUPeerTransportFactory) {
        self.account = account
        self.target = target
        self.purpose = purpose
        self.playsAudio = playsAudio
        self.transportFactory = transportFactory
        stream = settings
        localRefresh = localRefreshRate
        self.preferredScreenID = preferredScreenID
    }

    // MARK: - Lifecycle

    public func start() {
        tasks.append(Task { await connect() })
    }

    public func stop() {
        guard !isClosed else { return }
        Self.log.info("stop the \(self.purpose == .desktop ? "desktop" : "terminal", privacy: .public) connection")
        isClosed = true
        for task in tasks { task.cancel() }
        tasks.removeAll()
        tunnel.shutdown()
        transport?.close()
        transport = nil
        if let lease {
            self.lease = nil
            account.rooms.leave(lease)
        }
        for waiter in readyWaiters.values { waiter.resume(throwing: UURemoteFailure(failureReason ?? "The UU Remote connection closed.")) }
        readyWaiters.removeAll()
        for waiter in listWaiters.values { waiter.resume(returning: nil) }
        listWaiters.removeAll()
        if case .failed = phase {} else { report(.closed, hint: "UU Remote session ended") }
        onStop?()
        onStop = nil
    }

    private var failureReason: String? {
        if case let .failed(reason) = phase { return reason }
        return nil
    }

    private func report(_ phase: UURemotePhase, hint: String? = nil) {
        self.phase = phase
        onEvent?(.phase(phase))
        if let hint { self.hint(hint) }
        if case .failed = phase { resumeReadyWaiters() }
    }

    private func hint(_ text: String) {
        statusHint = text
        onEvent?(.hint(text))
    }

    /// The connection is gone for good: what runs on it ends, and can
    /// reconnect on a new one.
    private func lose(_ reason: String) {
        guard !isClosed else { return }
        Self.log.error("connection lost: \(reason, privacy: .public)")
        report(.failed(reason))
        stop()
    }

    /// Returns once terminals can start; throws when the connection fails,
    /// closes, or takes longer than `timeout`.
    public func waitUntilReady(timeout: Duration = .seconds(30)) async throws {
        if isReady { return }
        if let failureReason { throw UURemoteFailure(failureReason) }
        if isClosed { throw UURemoteFailure("The UU Remote connection closed.") }
        let id = UUID()
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.readyWaiters.removeValue(forKey: id)?.resume(throwing: UURemoteFailure("UU Remote did not connect in \(timeout.components.seconds) seconds. Is the device online?"))
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { readyWaiters[id] = $0 }
    }

    private func resumeReadyWaiters() {
        let outcome: Result<Void, Error>
        if isReady {
            outcome = .success(())
        } else if let failureReason {
            outcome = .failure(UURemoteFailure(failureReason))
        } else {
            return
        }
        let waiters = readyWaiters.values
        readyWaiters.removeAll()
        for waiter in waiters { waiter.resume(with: outcome) }
    }

    // MARK: - Connecting

    private func connect() async {
        report(.connecting("Starting UU Remote session"), hint: "Resolving device…")
        guard !target.deviceID.isEmpty || target.isAssist else {
            report(.failed("UU Remote device ID is missing."), hint: "Bind a device first")
            return stop()
        }
        await account.ready()
        if let device = account.device(withID: target.deviceID) {
            hostIsWindows = device.platform != 4
            hostPlatformKnown = true
            guard device.isOnline || target.isAssist else {
                let name = device.alias.isEmpty ? "The device" : device.alias
                report(.failed("\(name) is offline in UU Remote. Open UU Remote on it, then reconnect."), hint: "")
                return stop()
            }
        }
        // Signed out, the service only answers with its missing headers. A
        // share code joins without an account.
        guard account.isLoggedIn || target.isAssist else {
            report(.failed("Sign in to UU Remote to connect."), hint: "UU Remote Account")
            return stop()
        }

        let (messages, feed) = AsyncStream.makeStream(of: Inbound.self)
        tasks.append(Task { [weak self] in
            for await message in messages {
                guard let self, !self.isClosed else { return }
                await self.handle(message)
            }
        })
        do {
            report(.connecting("Joining room"), hint: "Joining UU Remote room…")
            let lease = try await account.rooms.join(target, api: account.api) { _ = feed.yield(.signal($0)) }
            guard !isClosed else { return account.rooms.leave(lease) }
            self.lease = lease
            hint("Signal channel open")

            // The viewer asks to be controlled before it knows the ICE
            // servers: the acknowledgement carries them.
            report(.connecting("Requesting control"), hint: "Asking host to control…")
            appControlID = UUID().uuidString
            iceID = Self.randomHex(byteCount: 16)
            let ack = try await lease.signal.emitControl(
                appControlID: appControlID,
                connectOptions: UUConnectRequest.options(purpose: purpose, deviceID: account.credentials.deviceID, settings: stream),
                streamerData: UUConnectRequest.streamerData(controlID: appControlID, fps: stream.fps),
                timeout: 15
            )
            let result = try Self.controlResult(ack, appControlID: appControlID)
            remoteClientID = result["client_id"] as? String ?? ""
            // The cloud assigns the session's ice_id in the acknowledgement.
            if let assigned = result["ice_id"] as? String, !assigned.isEmpty, assigned.count <= 128 { iceID = assigned }
            hint("Control request accepted")
            guard !isClosed else { return }

            report(.connecting("Creating peer connection"), hint: "Starting WebRTC…")
            let configuration = UUPeerConfiguration(
                iceServers: Self.iceServers(from: result),
                relayOnly: result["force_relay"] as? Bool ?? false,
                playsAudio: playsAudio
            )
            // Frames stay off the main actor: only the track in view's go
            // out, and a new size comes back for the cursor.
            let view = view
            let sink = frameSink
            let transport = try transportFactory(configuration) { [weak self] event in
                guard case let .frame(frame) = event else {
                    feed.yield(.peer(event))
                    return
                }
                let size = CGSize(width: frame.width, height: frame.height)
                let (drawn, resized) = view.withLock { state -> (Bool, Bool) in
                    guard state.accepts(frame.mid) else { return (false, false) }
                    defer { state.size = size }
                    return (true, state.size != size)
                }
                guard drawn else { return }
                if resized { Task { @MainActor in self?.frameSizeChanged(size) } }
                sink.withLock { $0 }?.deliver(frame)
            }
            self.transport = transport
            report(.connecting("Negotiating media"), hint: "Sending SDP offer…")
            try await sendOffer(iceRestart: false)

            tasks.append(Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    await self?.sampleStatistics()
                }
            })
            tasks.append(Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard let self, !self.isClosed, !self.open.contains(.control) else { return }
                self.lose("UU Remote session timed out waiting for the host.")
            })
        } catch {
            report(.failed(error.localizedDescription), hint: "")
            stop()
        }
    }

    private enum Inbound: Sendable {
        case signal(UUSignalMessage)
        case peer(UUPeerEvent)
    }

    private func handle(_ inbound: Inbound) async {
        switch inbound {
        case let .signal(.soac(soac)): await handleSOAC(soac.object)
        case let .signal(.event(name, args)): await handleSignalEvent(name, args: args.map(\.object))
        case let .peer(event): await handle(event)
        }
    }

    /// `["success", {result}]`, for this session.
    nonisolated static func controlResult(_ ack: Data, appControlID: String) throws -> [String: Any] {
        guard let array = try? JSONSerialization.jsonObject(with: ack) as? [Any], array.count >= 2,
              array[0] as? String == "success", let result = array[1] as? [String: Any]
        else { throw UURemoteFailure("The host's answer to the control request could not be read.") }
        if let returned = result["app_control_id"] as? String, returned != appControlID {
            throw UURemoteFailure("The control acknowledgement belongs to another session.")
        }
        if let code = (result["code"] as? NSNumber)?.intValue, code != 0 {
            throw UURemoteFailure("The host refused control: \(result["msg"] as? String ?? "error \(code)")")
        }
        return result
    }

    /// `iceServers[]` of the acknowledgement, `urls` a string or a list.
    nonisolated static func iceServers(from result: [String: Any]) -> [UUIceServer] {
        (result["iceServers"] as? [[String: Any]] ?? []).compactMap { server in
            let urls: [String] = switch server["urls"] {
            case let list as [Any]: list.compactMap { $0 as? String }
            case let url as String: [url]
            default: []
            }
            guard !urls.isEmpty else { return nil }
            return UUIceServer(urls: urls, username: server["username"] as? String, credential: server["credential"] as? String)
        }
    }

    private nonisolated static func randomHex(byteCount: Int) -> String {
        (0 ..< byteCount).map { _ in String(format: "%02x", UInt8.random(in: 0 ... 255)) }.joined()
    }

    // MARK: - Signaling

    /// Ids must match where the message has them; nothing is for this
    /// session before its control acknowledgement.
    private func matchesRoute(_ body: [String: Any]) -> Bool {
        guard !remoteClientID.isEmpty else { return false }
        if let ice = body["ice_id"] as? String, ice != iceID { return false }
        if let app = body["app_control_id"] as? String, app != appControlID { return false }
        return true
    }

    private func handleSignalEvent(_ event: String, args: [[String: Any]]) async {
        switch event {
        case "control":
            // A host may push an offer through a control event.
            if let first = args.first, matchesRoute(first), let sdp = UUSessionDescription.sdp(in: first) {
                await answerRemoteOffer(sdp)
            }
        case "be-controlled":
            hint("Host acknowledged the control request")
        default:
            break
        }
    }

    private func handleSOAC(_ raw: [String: Any]) async {
        // `{client_id, data:{…}}`, or the message itself.
        let soac = raw["data"] as? [String: Any] ?? raw
        if let client = raw["client_id"] as? String, client != remoteClientID { return }
        guard matchesRoute(soac) else { return }
        switch soac["type"] as? String {
        case "offer":
            if let sdp = UUSessionDescription.sdp(in: soac) { await answerRemoteOffer(sdp) }
        case "answer":
            if let sdp = UUSessionDescription.sdp(in: soac) { await applyAnswer(sdp) }
        case "candidate":
            await addCandidate(soac)
        case "restart_ice":
            answered = false
            try? await sendOffer(iceRestart: true)
        default:
            break
        }
    }

    private func sendSOAC(_ data: [String: Any]) async throws {
        guard let lease else { throw UUSignalError.notConnected }
        var body = data
        body["ice_id"] = iceID
        body["app_control_id"] = appControlID
        try await lease.signal.sendSOAC(["client_id": remoteClientID, "data": body])
    }

    private func sendOffer(iceRestart: Bool) async throws {
        guard let transport, !remoteClientID.isEmpty else { return }
        let sdp = try await transport.makeOffer(iceRestart: iceRestart)
        try await sendSOAC(["type": "offer", "sdp": UUSessionDescription.offerForHost(sdp), "ice_network_type": 3])
        hint("SDP offer sent")
    }

    private func answerRemoteOffer(_ sdp: String) async {
        guard let transport else { return }
        do {
            let answer = try await transport.answer(remoteOffer: sdp)
            try await sendSOAC(["type": "answer", "sdp": answer])
            hint("SDP answer sent")
        } catch {
            lose("UU Remote SDP answer failed: \(error.localizedDescription)")
        }
    }

    private func applyAnswer(_ sdp: String) async {
        guard let transport, !answered else { return }
        do {
            try await transport.setRemoteAnswer(sdp)
            answered = true
        } catch {
            return lose("UU Remote SDP answer rejected: \(error.localizedDescription)")
        }
        let tracks = UUSessionDescription.videoTrackMids(in: sdp)
        midByTrackIndex = tracks.mids
        namedMids = tracks.named
        followViewedScreen()
        let early = earlyCandidates
        earlyCandidates.removeAll()
        for candidate in early { try? await transport.addRemoteCandidate(candidate) }
    }

    /// A host candidate: a bare string, or an RTCIceCandidateInit object.
    private func addCandidate(_ soac: [String: Any]) async {
        let candidate: UUIceCandidate
        if let line = soac["candidate"] as? String {
            candidate = UUIceCandidate(candidate: line, sdpMid: soac["sdp_mid"] as? String, sdpMLineIndex: (soac["sdp_m_line_index"] as? NSNumber)?.int32Value)
        } else if let object = soac["candidate"] as? [String: Any], let line = object["candidate"] as? String {
            candidate = UUIceCandidate(candidate: line, sdpMid: object["sdpMid"] as? String, sdpMLineIndex: (object["sdpMLineIndex"] as? NSNumber)?.int32Value)
        } else {
            return
        }
        if answered {
            try? await transport?.addRemoteCandidate(candidate)
        } else if earlyCandidates.count < 256 {
            earlyCandidates.append(candidate)
        }
    }

    // MARK: - Peer events

    private func handle(_ event: UUPeerEvent) async {
        switch event {
        case let .candidate(candidate):
            var object: [String: Any] = ["candidate": candidate.candidate]
            object["sdpMid"] = candidate.sdpMid ?? NSNull()
            object["sdpMLineIndex"] = candidate.sdpMLineIndex.map { NSNumber(value: $0) } ?? NSNull()
            try? await sendSOAC(["type": "candidate", "candidate": object])
        case let .iceState(state):
            handleICEState(state)
        case let .channelOpened(channel):
            open.insert(channel)
            channelOpened(channel)
            resumeReadyWaiters()
        case let .channelClosed(channel):
            let wasOpen = open.remove(channel) != nil
            if wasOpen, channel == .control || channel == .binary { lose("The UU Remote connection closed.") }
        case let .message(channel, data):
            receive(data, on: channel)
        case .frame:
            break
        }
    }

    private func handleICEState(_ state: UUIceState) {
        iceState = state
        hint("ICE \(state)")
        switch state {
        case .connected:
            if phase != .locked { report(.connected) }
        case .failed:
            lose("The UU Remote connection was lost.")
        case .disconnected:
            // Often back within seconds (a network change); gone if not.
            tasks.append(Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard let self, self.iceState == .disconnected else { return }
                self.lose("The UU Remote connection was lost.")
            })
        default:
            break
        }
    }

    private func channelOpened(_ channel: UUDataChannel) {
        switch channel {
        case .control:
            report(.connected, hint: "Control channel open")
            startHeartbeat()
        case .text:
            sendFirstStreamSettings()
        default:
            break
        }
    }

    // MARK: - Sending

    private func nextSequence() -> UInt64 {
        sequence.withLock { $0 += 1; return $0 }
    }

    private func send(_ data: Data, on channel: UUDataChannel) {
        guard open.contains(channel) else { return }
        transport?.send(data, on: channel)
    }

    /// The port-mapping tunnel sends from its own queues.
    private nonisolated func sendFromAnyThread(_ data: Data, on channel: UUDataChannel) {
        Task { @MainActor [weak self] in self?.send(data, on: channel) }
    }

    private func startHeartbeat() {
        tasks.append(Task { [weak self] in
            var tick = 0
            while !Task.isCancelled, let self {
                // The control association stays alive on an echo request
                // every 100 ms, and the host's input watchdog wants the
                // keyboard heartbeat about once a second.
                self.send(UUControl.echoRequest(sequence: self.nextSequence()), on: .control)
                tick += 1
                if tick % 10 == 0 { self.send(UUInput.keyboardHeartbeat, on: .control) }
                try? await Task.sleep(for: .milliseconds(100))
            }
        })
        guard purpose == .desktop else { return }
        tasks.append(Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !self.isClosed else { return }
            // One sendVideoTrack request once the channel is up, as the
            // official viewer sends.
            self.send(UUControl.sendVideoTrack(requestID: self.nextSequence(), tracks: self.midByTrackIndex.keys.sorted()), on: .control)
        })
    }

    // MARK: - Receiving

    private func receive(_ data: Data, on channel: UUDataChannel) {
        switch channel {
        case .control: receiveControl(data)
        case .binary: receiveTerminal(data)
        case .text: receiveText(data)
        case .file:
            if let message = UUControl.decode(data), case let .portMappingFrame(frame) = message.body { tunnel.handle(frame) }
        case .streamer:
            // Video comes on the RTP tracks.
            break
        }
    }

    private func receiveControl(_ data: Data) {
        // Input JSON the host echoes is no protobuf message.
        guard let message = UUControl.decode(data) else { return }
        switch message.body {
        case let .simpleAction(action):
            if action.action == .echoRequest {
                send(UUControl.echoResponse(sequence: nextSequence(), requestSequence: UUControl.echoSequence(action)), on: .control)
            }
        case let .screenSources(sources):
            let listed = UUControl.screens(from: sources)
            handleScreens(listed.screens, currentID: listed.currentID)
        case let .systemStateChange(change):
            if change.hasIsLocked {
                report(change.isLocked ? .locked : .connected)
            }
            if change.hasCursor { updateCursor(shape: UUControl.cursor(from: change.cursor)) }
        case .rpcResponse:
            if let answer = UUControl.captureSettingAnswer(message) { handleStreamAnswer(answer.requestID, errors: answer.errors) }
        case let .portMappingFrame(frame):
            tunnel.handle(frame)
        default:
            break
        }
    }

    private func receiveText(_ data: Data) {
        guard let message = UUControl.decode(data) else { return }
        if let answer = UUControl.captureSettingAnswer(message) {
            return handleStreamAnswer(answer.requestID, errors: answer.errors)
        }
        let received = clipboard.receive(message)
        for reply in received.replies { send(reply, on: .text) }
        if let text = received.text { onEvent?(.remoteClipboard(text)) }
    }

    // MARK: - Input

    /// Where the pointer was last sent: buttons and the wheel carry no
    /// position, so a press where no move went first is preceded by one.
    private var sentPointer: (x: Double, y: Double)?

    /// The pointer at a normalized place on the screen in view.
    public func movePointer(x: Double, y: Double) {
        guard open.contains(.control), x.isFinite, y.isFinite else { return }
        sentPointer = (x, y)
        let screenID = screens.count > 1 ? viewedScreenID : nil
        send(UUInput.pointerMove(x: x, y: y, screenID: screenID).data, on: .control)
        updateCursor(pointer: (x, y))
    }

    private func pointer(at x: Double, _ y: Double) {
        if let sentPointer, sentPointer.x == x, sentPointer.y == y { return }
        movePointer(x: x, y: y)
    }

    public func pressButton(_ button: UUMouseButton, isDown: Bool, x: Double, y: Double) {
        guard open.contains(.control) else { return }
        pointer(at: x, y)
        send(UUInput.button(button, isDown: isDown).data, on: .control)
    }

    /// `dx`/`dy` in wheel notches, positive `dy` scrolling up.
    public func scroll(dx: Double, dy: Double, x: Double, y: Double) {
        guard open.contains(.control), dx.isFinite, dy.isFinite else { return }
        pointer(at: x, y)
        // The host takes browser wheel deltas, about 60 a notch.
        send(UUInput.scroll(dx: Int32(clamping: Int((dx * 60).rounded())), dy: Int32(clamping: Int((dy * 60).rounded()))).data, on: .control)
    }

    /// A key in the host's code space: a Windows virtual-key code for a
    /// Windows host (`hostIsWindows`), a Mac virtual keycode for a Mac.
    public func key(_ code: Int32, isDown: Bool) {
        guard open.contains(.control) else { return }
        send(UUInput.key(code, isDown: isDown, windowsHost: hostIsWindows).data, on: .control)
    }

    public func typeText(_ text: String) {
        guard open.contains(.control) else { return }
        send(UUInput.text(text).data, on: .control)
    }

    /// Offers local text to the host's clipboard: plain text a Windows host
    /// applies, the format offer a Mac host takes, both when the host's
    /// platform is not known.
    public func setRemoteClipboard(_ text: String) {
        guard open.contains(.text) else { return }
        for message in clipboard.offer(text, hostIsMac: hostPlatformKnown ? !hostIsWindows : nil) { send(message, on: .text) }
    }

    private var clipboard = UUClipboard()

    // MARK: - Screens and their tracks

    private var screens: [UUScreen] = []
    /// The screen in view: the one the pointer is on and whose track is drawn.
    private var viewedScreenID: Int?
    private let preferredScreenID: Int?
    private var preferredApplied = false
    private var virtualScreenAskedAt: Date?
    private var screenActivated = false
    private var midByTrackIndex: [Int: String] = [:]
    private var namedMids: Set<String> = []
    /// Which track's frames go out, decided as frames arrive off the main
    /// actor.
    private let view = OSAllocatedUnfairLock(initialState: TrackView())

    /// The host listed its screens: the one in view stays while it is
    /// there, otherwise the host's current one is; the preferred screen is
    /// shown once listed.
    private func handleScreens(_ listed: [UUScreen], currentID: Int?) {
        let known = Set(screens.map(\.id))
        screens = listed
        view.withLock { $0.skipped = nil }
        if let asked = virtualScreenAskedAt, Date().timeIntervalSince(asked) > 10 { virtualScreenAskedAt = nil }
        if virtualScreenAskedAt != nil, !known.isEmpty, let added = listed.first(where: { $0.isVirtual && !known.contains($0.id) }) {
            virtualScreenAskedAt = nil
            return selectScreen(added.id)
        }
        if !listed.contains(where: { $0.id == viewedScreenID }) {
            viewedScreenID = currentID.flatMap { id in listed.first { $0.id == id }?.id }
                ?? listed.first(where: \.isPrimary)?.id ?? listed.first?.id
        }
        if !preferredApplied, let preferred = preferredScreenID, listed.contains(where: { $0.id == preferred }) {
            preferredApplied = true
            if preferred != viewedScreenID { return selectScreen(preferred) }
        }
        // The official viewer starts the capture of the screen it shows:
        // without it, a host whose screen was removed kept sending input
        // there until a screen was chosen again.
        if !screenActivated, let viewed = viewedScreenID {
            screenActivated = true
            send(UUControl.captureScreen(viewed, start: true, sequence: nextSequence()), on: .control)
        }
        followViewedScreen()
        onEvent?(.screens(listed, selected: viewedScreenID))
    }

    /// Shows another of the host's screens: its capture starts, the one in
    /// view stops (the host otherwise streams both), and its track is the
    /// one drawn.
    public func selectScreen(_ screenID: Int) {
        guard open.contains(.control), screenID != viewedScreenID else { return }
        let previous = viewedScreenID
        send(UUControl.captureScreen(screenID, start: true, sequence: nextSequence()), on: .control)
        if let previous, screens.contains(where: { $0.id == previous }) {
            send(UUControl.captureScreen(previous, start: false, sequence: nextSequence()), on: .control)
        }
        viewedScreenID = screenID
        screenActivated = true
        followViewedScreen(leaving: true)
        onEvent?(.screens(screens, selected: screenID))
    }

    /// A new UU virtual screen; the view goes to it once the host lists it.
    public func addVirtualScreen(width: Int, height: Int) {
        guard open.contains(.control), width > 0, height > 0 else { return }
        virtualScreenAskedAt = Date()
        send(UUControl.createVirtualDisplay(requestID: nextSequence(), width: width, height: height), on: .control)
    }

    /// Removes a virtual screen, viewing another first if it is in view.
    /// The last screen stays.
    public func removeVirtualScreen(_ screenID: Int) {
        guard open.contains(.control), screens.count > 1, screens.contains(where: { $0.id == screenID && $0.isVirtual }) else { return }
        if screenID == viewedScreenID,
           let other = screens.first(where: { $0.id != screenID && $0.isPrimary }) ?? screens.first(where: { $0.id != screenID }) {
            selectScreen(other.id)
        }
        send(UUControl.removeVirtualDisplay(requestID: nextSequence(), screenID: screenID), on: .control)
    }

    /// Draws the track of the screen in view once the host has said which
    /// it is and the answer which transceiver carries it; when `leaving`
    /// and that is not known, the next track to send another frame.
    private func followViewedScreen(leaving: Bool = false) {
        let mid = screens.first { $0.id == viewedScreenID }?.videoTrackIndex.flatMap { midByTrackIndex[$0] }
        let certain = mid.map(namedMids.contains) ?? false
        let changed = view.withLock { $0.follow(mid, certain: certain, leaving: leaving) }
        if changed { transport?.requestKeyFrame() }
    }

    /// A key frame on every track.
    public func requestKeyFrame() {
        transport?.requestKeyFrame()
    }

    // MARK: - Stream settings

    private var stream: UUStreamSettings
    private let localRefresh: Int
    /// The codec the frames come in (1 H.264, 2 H.265), for the settings
    /// request; 0 until the stats say.
    private var codec: Int32 = 0
    private var pendingStream: (requestID: UInt64, previous: UUStreamSettings)?
    private var appliedStream: UUStreamSettings?
    private var firstStreamSent = false

    /// New picture settings: kept for the next connection, asked of the
    /// host now when connected.
    public func updateStream(_ settings: UUStreamSettings) {
        let previous = stream
        stream = settings
        sendStreamSettings(previous: previous)
    }

    /// The settings the official viewer sends once connected: when TEXT is
    /// open and the codec is known, whichever comes last, once.
    private func sendFirstStreamSettings() {
        guard !firstStreamSent, open.contains(.text), codec != 0 else { return }
        firstStreamSent = true
        sendStreamSettings(previous: nil)
    }

    private func sendStreamSettings(previous: UUStreamSettings?) {
        guard open.contains(.text) else { return }
        let requestID = nextSequence()
        pendingStream = (requestID, previous ?? appliedStream ?? stream)
        // cursorCapture false: the cursor is drawn here. With it the host
        // put a second one in the picture.
        send(UUControl.captureSetting(requestID: requestID, settings: stream, codec: codec, fpsCount: Int32(min(stream.fps, max(localRefresh, 30))), cursorCapture: false), on: .text)
    }

    /// Applied, applied with the frame rate lowered to the host screen's
    /// (-3), true colour declined (-6), or refused.
    private func handleStreamAnswer(_ requestID: UInt64, errors: [UUControl.RPCFailure]) {
        guard let pending = pendingStream, pending.requestID == requestID else { return }
        pendingStream = nil
        struct ColourOutcome: Decodable { var error_code: Int }
        if let colour = errors.first(where: { $0.code == -6 }),
           let outcome = try? JSONDecoder().decode(ColourOutcome.self, from: Data(colour.detail.utf8)),
           outcome.error_code == 1 || outcome.error_code == 2, stream.trueColor {
            stream.trueColor = false
            onEvent?(.streamChanged(stream, notice: "The host can't send true colour here; it sends standard colour."))
        }
        let refused = errors.filter { $0.code != -3 && $0.code != -6 }
        guard let first = refused.first else {
            appliedStream = stream
            if errors.contains(where: { $0.code == -3 }) {
                onEvent?(.notice("The host's screen can't show \(stream.fps) fps; it sends what its screen does."))
            }
            return
        }
        stream = pending.previous
        onEvent?(.streamRefused(pending.previous, reason: "The host kept its picture settings: \(first.message.isEmpty ? "error \(first.code)" : first.message)"))
    }

    // MARK: - Cursor

    private var cursorShape: UUCursor?
    private var cursorPointer = (x: 0.5, y: 0.5)
    private var screenSize: CGSize = .zero

    private func updateCursor(shape: UUCursor? = nil, pointer: (x: Double, y: Double)? = nil) {
        if let shape { cursorShape = shape }
        if let pointer { cursorPointer = pointer }
        if let placed = cursorShape?.placed(at: cursorPointer, on: screenSize) { onEvent?(.cursor(placed)) }
    }

    private func frameSizeChanged(_ size: CGSize) {
        screenSize = size
        updateCursor()
    }

    // MARK: - Statistics

    private var lastStats: (at: Date, mid: String?, track: UUTransportStats.Track)?

    /// Once a second while connected: round trip, and the bit rate and loss
    /// of the track in view.
    private func sampleStatistics() async {
        guard let transport else { return }
        let stats = await transport.statistics()
        let mid = view.withLock { $0.viewed }
        if codec == 0, let name = stats.video.values.first(where: { !$0.codec.isEmpty })?.codec.uppercased() {
            codec = name.contains("264") ? UUCodec.h264 : UUCodec.h265
            sendFirstStreamSettings()
        }
        var network = UUNetworkStats(relayed: stats.relayed)
        if let mid, let track = stats.video[mid] {
            let now = Date()
            if let last = lastStats, last.mid == mid, track.bytes >= last.track.bytes {
                let seconds = max(now.timeIntervalSince(last.at), 0.1)
                network.bitsPerSecond = Int((track.bytes - last.track.bytes) * 8 / seconds)
                let lost = max(track.lost - last.track.lost, 0)
                let arrived = max(track.packets - last.track.packets, 0)
                if lost + arrived > 0 { network.lossPercent = lost * 100 / (lost + arrived) }
            }
            lastStats = (now, mid, track)
        } else {
            lastStats = nil
        }
        onEvent?(.network(network))
        if let roundTrip = stats.roundTrip { onEvent?(.roundTrip(milliseconds: Int((roundTrip * 1000).rounded()))) }
    }

    // MARK: - Terminals

    private var terminalSinks: [UInt32: (UUTerminalFrame) -> Void] = [:]
    /// Terminals closed here: the host's late frames for them go nowhere.
    private var closedTerminals: Set<UInt32> = []
    /// Every session id the host listed, so a new one takes none of them.
    private var knownSessions: Set<UInt32> = []
    private var listWaiters: [UUID: CheckedContinuation<[UUTerminalSession]?, Never>] = [:]

    public var openTerminalCount: Int { terminalSinks.count }

    /// Opens a terminal, or attaches to a detached session, and returns its
    /// session id; its frames go to `onFrame`.
    ///
    /// The host keeps a session through disconnects, by the id the viewer
    /// gave it, so a new one takes an id no session has.
    public func openTerminal(sessionID: UInt32? = nil, cols: Int, rows: Int, onFrame: @escaping (UUTerminalFrame) -> Void) -> UInt32 {
        let id = sessionID ?? Self.newSessionID(avoiding: knownSessions)
        closedTerminals.remove(id)
        terminalSinks[id] = onFrame
        let shell = hostIsWindows ? "powershell.exe" : "/bin/zsh"
        sendTerminal(UUTerminalFrame(kind: .open, sessionID: id, payload: UUTerminalJSON.open(cols: cols, rows: rows, shell: shell)))
        return id
    }

    nonisolated static func newSessionID(avoiding taken: Set<UInt32>) -> UInt32 {
        while true {
            let id = UInt32.random(in: 1 ... UInt32(Int32.max))
            if !taken.contains(id) { return id }
        }
    }

    /// Ends a session on the host.
    public func closeTerminal(_ id: UInt32) {
        terminalSinks.removeValue(forKey: id)
        closedTerminals.insert(id)
        sendTerminal(UUTerminalFrame(kind: .close, sessionID: id))
    }

    /// Leaves a session running on the host, to attach to later.
    public func detachTerminal(_ id: UInt32) {
        guard terminalSinks.removeValue(forKey: id) != nil else { return }
        closedTerminals.insert(id)
        sendTerminal(UUTerminalFrame(kind: .detach, sessionID: id))
    }

    public func sendTerminalInput(_ data: Data, sessionID: UInt32) {
        sendTerminal(UUTerminalFrame(kind: .stdin, sessionID: sessionID, payload: data))
    }

    public func resizeTerminal(cols: Int, rows: Int, sessionID: UInt32) {
        sendTerminal(UUTerminalFrame(kind: .resize, sessionID: sessionID, payload: UUTerminalJSON.resize(cols: cols, rows: rows)))
    }

    private func sendTerminal(_ frame: UUTerminalFrame) {
        send(frame.encode(), on: .binary)
    }

    /// The host's sessions, attached or not; nil when it does not answer.
    public func listTerminalSessions(timeout: Duration = .seconds(8)) async -> [UUTerminalSession]? {
        guard !isClosed else { return nil }
        let id = UUID()
        sendTerminal(UUTerminalFrame(kind: .listRequest, sessionID: 0))
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.listWaiters.removeValue(forKey: id)?.resume(returning: nil)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { listWaiters[id] = $0 }
    }

    private func receiveTerminal(_ data: Data) {
        guard let frame = UUTerminalFrame(decoding: data) else { return }
        if frame.kind == .listResponse {
            let sessions = UUTerminalSession.list(from: frame.payload)
            if let sessions { knownSessions.formUnion(sessions.map(\.id)) }
            let waiters = listWaiters.values
            listWaiters.removeAll()
            for waiter in waiters { waiter.resume(returning: sessions) }
            return
        }
        guard !closedTerminals.contains(frame.sessionID) else { return }
        terminalSinks[frame.sessionID]?(frame)
    }

    // MARK: - Port mapping

    /// A TCP stream to `host:port` as the device sees it (`127.0.0.1` for
    /// its own services). Returns one end of a socket pair, which the
    /// caller reads, writes and closes; `onClose` runs once it has ended.
    public func openPortMapping(host: String, port: UInt16, timeout: Duration = .seconds(20), onClose: (@Sendable () -> Void)? = nil) async throws -> Int32 {
        guard open.contains(.file) else { throw UUPortMappingFailure("The UU Remote connection is not ready for port mapping.") }
        return try await tunnel.openStream(host: host, port: port, timeout: timeout, onClose: onClose)
    }
}

/// Which video track's frames are the picture.
struct TrackView: Sendable {
    /// The track drawn; nil until one is known, when the first track to
    /// send a frame is taken (other than `skipped`, the one just left).
    var viewed: String?
    var skipped: String?
    var skippedAt = Date.distantPast
    var heardAt = Date()
    var heard = false
    /// The answer named the drawn track's index.
    var certain = false
    var size: CGSize = .zero

    /// The screen in view is on `mid`, or (`leaving`) the drawn track is
    /// left for the next one to send. True when the drawn track changed.
    mutating func follow(_ mid: String?, certain: Bool, leaving: Bool) -> Bool {
        if let mid {
            self.certain = certain
            guard mid != viewed else { return false }
            viewed = mid
            skipped = nil
            heardAt = Date()
            heard = false
            return true
        }
        guard leaving else { return false }
        skipped = viewed
        skippedAt = Date()
        viewed = nil
        return true
    }

    /// Whether a frame of `mid` is drawn. None chosen yet: this one, unless
    /// it is the one just left (for 5 s, or until the host lists its screens
    /// again). A chosen one that never sent, or that the answer did not
    /// name, gives way after 2 s of silence while another sends: its index
    /// was mapped wrongly. A screen standing still sends nothing, so a
    /// named track that has sent keeps the view.
    mutating func accepts(_ mid: String, now: Date = Date()) -> Bool {
        if mid == viewed {
            heardAt = now
            heard = true
            return true
        }
        let open = viewed == nil && (mid != skipped || now.timeIntervalSince(skippedAt) > 5)
        let silent = viewed != nil && now.timeIntervalSince(heardAt) > 2 && (!heard || !certain)
        guard open || silent else { return false }
        viewed = mid
        heardAt = now
        heard = true
        certain = false
        return true
    }
}
