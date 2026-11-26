//
//  UURemoteAccount.swift
//  UURemoteKit
//
//  The signed-in UU Remote account: QR, SMS and token sign-in, the device
//  identity the service wants a viewer to have, and the account's devices
//  with their presence. Kept through the host app's `UUCredentialStorage`.
//

import Combine
import CoreImage
import CryptoKit
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers

@MainActor
public final class UURemoteAccount: ObservableObject {
    @Published public private(set) var credentials = UUCredentials()
    @Published public private(set) var nickname = ""
    @Published public private(set) var devices: [UUDeviceInfo] = []
    @Published public private(set) var isLoggedIn = false
    @Published public private(set) var qrLoginState = QRLoginState.idle
    /// The QR code to scan, as PNG.
    @Published public private(set) var qrImageData: Data?
    @Published public private(set) var qrStatusHint = ""
    @Published public private(set) var loginError: String?
    /// Why the last device refresh failed; nil once one succeeds.
    @Published public private(set) var refreshError: String?

    public var userID: String { credentials.userID }

    /// The REST API, signed as this account.
    public nonisolated let api = UUAPIClient()
    /// The name this viewer registers its own device under ("<name> · <host>").
    public let clientName: String
    /// Called with the devices after every refresh that got them.
    public var onDevicesRefreshed: (([UUDeviceInfo]) -> Void)?

    private let storage: UUCredentialStorage
    private var qrPollingTask: Task<Void, Never>?
    /// Handing the saved account to the API client at launch: the account
    /// says "signed in" at once, and requests wait for this.
    private var loading: Task<Void, Never>?
    private nonisolated static let log = Logger(subsystem: "UURemoteKit", category: "account")

    public enum QRLoginState: Equatable, Sendable {
        case idle
        case generating
        case waiting
        case scanned
        case confirmed
        case expired
        case failed(String)
    }

    public init(storage: UUCredentialStorage, clientName: String) {
        self.storage = storage
        self.clientName = clientName
        guard let saved = storage.load() else { return }
        credentials = saved.credentials
        nickname = saved.nickname
        isLoggedIn = saved.credentials.isComplete
        loading = Task {
            await api.updateCredentials(saved.credentials)
            await ensureLocalDeviceIdentity()
            if !credentials.token.isEmpty { isLoggedIn = credentials.isComplete }
            if isLoggedIn { try? await fetchDevices() }
        }
    }

    /// Returns once the saved account is in the API client.
    public func ready() async {
        await loading?.value
    }

    private func persist() {
        let empty = credentials == UUCredentials()
        storage.save(empty ? nil : UUSavedAccount(credentials: credentials, nickname: nickname))
    }

    private func apply(_ updated: UUCredentials) async {
        credentials = updated
        persist()
        await api.updateCredentials(updated)
    }

    // MARK: - Sign-in

    /// Starts a QR sign-in; `qrImageData` shows the code to scan with the
    /// UU Remote app. Returns the code's content.
    @discardableResult
    public func startQRLogin() async throws -> String {
        qrPollingTask?.cancel()
        qrLoginState = .generating
        qrStatusHint = "Generating QR code…"
        do {
            try await ensureRegisteredDevice()
            let (jumpURL, token, _) = try await api.qrcodeGenLogin()
            qrImageData = Self.qrCode(for: jumpURL)
            qrLoginState = .waiting
            qrStatusHint = "Scan with the UU Remote app"
            qrPollingTask = Task { await pollQRLogin(token: token, jumpURL: jumpURL) }
            return jumpURL
        } catch {
            qrLoginState = .failed(error.localizedDescription)
            qrStatusHint = error.localizedDescription
            loginError = error.localizedDescription
            throw error
        }
    }

    private func pollQRLogin(token: String, jumpURL: String) async {
        var lastStatus = 1
        while !Task.isCancelled {
            do {
                let status = try await api.qrcodeLoginStatus(token: token, qrcodeJumpURL: jumpURL, loginStatus: lastStatus)
                switch status {
                case 0:
                    qrLoginState = .expired
                    qrStatusHint = "QR code expired"
                    return
                case 1:
                    qrStatusHint = "Scan with the UU Remote app"
                case 2:
                    qrStatusHint = "Scanned — confirm on the device"
                    qrLoginState = .scanned
                case 3:
                    continue
                case 4:
                    qrLoginState = .confirmed
                    qrStatusHint = "Logging in…"
                    let (uid, nick, jwt) = try await api.loginByQRCode(token: token, qrcodeJumpURL: jumpURL)
                    await signedIn(userID: uid, nickname: nick, token: jwt)
                    qrStatusHint = "Logged in as \(nickname.isEmpty ? userID : nickname)"
                    return
                default:
                    qrStatusHint = "Waiting…"
                }
                lastStatus = status
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                guard !Task.isCancelled else { return }
                qrStatusHint = error.localizedDescription
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Sends an SMS sign-in code to a phone number.
    public func sendSMSCode(countryCode: String, mobile: String) async throws {
        try await ensureRegisteredDevice()
        try await api.mobileCode(countryCode: countryCode, mobile: mobile)
    }

    public func loginBySMS(countryCode: String, mobile: String, code: String) async throws {
        let (uid, nick, jwt) = try await api.loginByMobile(countryCode: countryCode, mobile: mobile, code: code)
        await signedIn(userID: uid, nickname: nick, token: jwt)
    }

    /// Signs in with a token copied from another client.
    public func importToken(_ token: String) async throws {
        await signedIn(userID: "", nickname: "", token: token)
    }

    /// Takes a sign-in made elsewhere as it is (previews, tests): nothing is
    /// registered, and it is not kept.
    public func adopt(_ credentials: UUCredentials, devices: [UUDeviceInfo]? = nil) async {
        await ready()
        self.credentials = credentials
        await api.updateCredentials(credentials)
        isLoggedIn = credentials.isComplete
        if let devices { self.devices = devices } else { try? await fetchDevices() }
    }

    /// Keeps a fresh token, fills in the identity, and fetches the devices.
    private func signedIn(userID uid: String, nickname nick: String, token jwt: String) async {
        var updated = credentials
        updated.token = jwt
        updated.userID = uid.isEmpty ? (UURequestSigner.userID(from: jwt) ?? "") : uid
        updated.csrf = UURequestSigner.csrf(from: jwt) ?? ""
        nickname = nick
        loginError = nil
        await apply(updated)
        await ensureLocalDeviceIdentity()
        isLoggedIn = credentials.isComplete
        try? await fetchDevices()
    }

    /// Makes sure the client, system and device ids exist: the ids are made
    /// once and kept; the device id comes from registering (or, when that is
    /// out of reach, is derived from the ids, so a valid token still counts).
    private func ensureLocalDeviceIdentity() async {
        var updated = credentials
        if updated.clientID.isEmpty { updated.clientID = UUID().uuidString }
        if updated.systemID.isEmpty { updated.systemID = UUID().uuidString }
        if updated != credentials { await apply(updated) }
        guard credentials.deviceID.isEmpty, !credentials.token.isEmpty else { return }
        do {
            try await registerLocalDevice()
        } catch {
            guard credentials.deviceID.isEmpty else { return }
            var derived = credentials
            derived.deviceID = Self.derivedDeviceID(clientID: derived.clientID, systemID: derived.systemID)
            await apply(derived)
        }
    }

    /// Sign-in requests are signed as a registered device: without one the
    /// service makes no QR code and sends no SMS. Registered once, and kept.
    private func ensureRegisteredDevice() async throws {
        await ensureLocalDeviceIdentity()
        guard credentials.deviceID.isEmpty else { return }
        try await registerLocalDevice()
    }

    /// A stable 16-character device id derived from the kept ids.
    nonisolated static func derivedDeviceID(clientID: String, systemID: String) -> String {
        let digest = SHA256.hash(data: Data("uu|\(clientID)|\(systemID)".utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    /// The name the device is registered under: the client, and the computer.
    private var localDeviceName: String {
        let host = ProcessInfo.processInfo.hostName.components(separatedBy: ".").first ?? ""
        return host.isEmpty ? clientName : "\(clientName) · \(host)"
    }

    private func registerLocalDevice() async throws {
        let deviceID = try await api.deviceWindowsInit(
            name: localDeviceName,
            clientID: credentials.clientID,
            systemID: credentials.systemID,
            machineGUID: UUID().uuidString,
            os: "macOS",
            baseBoard: "Apple",
            cpu: "Apple Silicon",
            video: ["Apple GPU"],
            mac: "00-00-00-00-00-00",
            memory: 16 * 1024,
            screen: "1920x1080"
        )
        var updated = credentials
        updated.deviceID = deviceID
        await apply(updated)
    }

    /// Signs out. The registered device is kept, so signing in again does
    /// not add another one to the account.
    public func logout() {
        Task { await signOut(keepingDevice: true) }
    }

    private func signOut(keepingDevice: Bool) async {
        qrPollingTask?.cancel()
        var kept = UUCredentials()
        if keepingDevice {
            kept.clientID = credentials.clientID
            kept.systemID = credentials.systemID
            kept.deviceID = credentials.deviceID
        }
        nickname = ""
        devices = []
        isLoggedIn = false
        qrLoginState = .idle
        qrImageData = nil
        qrStatusHint = ""
        await apply(kept)
    }

    // MARK: - Devices

    /// Fetches the account's devices and their presence again.
    public func refreshDevices() async throws {
        await ready()
        try await fetchDevices()
    }

    private func fetchDevices() async throws {
        do {
            let grouped = try await api.deviceGroupsOfMy()
            devices = grouped.isEmpty ? try await api.deviceList() : grouped
            refreshError = nil
        } catch {
            refreshError = error.localizedDescription
            throw error
        }
        if await dropBorrowedIdentity() { return }
        onDevicesRefreshed?(devices)
    }

    /// A sign-in under a Mac host's own device id came from the official
    /// app, not from this viewer: signed in as the host, every request was
    /// the host's, and the service dropped the host's connections. It is let
    /// go of, device and all, to sign in again as this viewer.
    private func dropBorrowedIdentity() async -> Bool {
        guard let device = borrowedHost(deviceID: credentials.deviceID, in: devices) else { return false }
        Self.log.error("signed in as the account's host; signing out")
        await signOut(keepingDevice: false)
        loginError = "\(clientName) was signed in as \(device.alias.isEmpty ? "this computer" : device.alias)'s UU Remote app, which made UU Remote drop that computer's connections. Sign in again: \(clientName) now signs in as itself."
        return true
    }

    /// The account's Mac host whose device id the sign-in uses, if it is one.
    func borrowedHost(deviceID: String, in devices: [UUDeviceInfo]) -> UUDeviceInfo? {
        guard !deviceID.isEmpty,
              let device = devices.first(where: { $0.deviceID == deviceID }),
              device.platform == 4,
              !device.alias.lowercased().hasPrefix(clientName.lowercased())
        else { return nil }
        return device
    }

    /// The account's computers to connect to (not this viewer's own
    /// registrations), by name.
    public var desktopDevices: [UUDeviceInfo] {
        devices
            .filter { $0.isComputer && !$0.isRegistration(of: clientName) && $0.deviceID != credentials.deviceID }
            .sorted { $0.alias.localizedStandardCompare($1.alias) == .orderedAscending }
    }

    public func device(withID deviceID: String) -> UUDeviceInfo? {
        devices.first { $0.deviceID == deviceID }
    }

    // MARK: - QR code

    /// `content` as a QR code, PNG.
    nonisolated static func qrCode(for content: String, scale: CGFloat = 8) -> Data? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(content.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
              let image = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
