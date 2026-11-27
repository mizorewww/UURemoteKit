import Foundation
import XCTest
@testable import UURemoteKit

final class AccountTests: XCTestCase {
    private func jwt(_ claims: String) -> String {
        let payload = Data(claims.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(payload).signature"
    }

    func testSignatureCoversOnlyTheXParamHeadersAndIsCaseInsensitive() {
        let headers = ["x-param-plat": "1", "x-param-ts": "1700000000"]
        let noisy = headers.merging(["Authorization": "Bearer t", "X-Param-SIGN": "dead", "Content-Type": "json"]) { $1 }
        let sign = UURequestSigner.sign(method: "POST", pathWithQuery: "/api/v1/x", headers: headers, body: Data("{}".utf8))
        XCTAssertEqual(sign.count, 64)
        XCTAssertEqual(sign, UURequestSigner.sign(method: "post", pathWithQuery: "/api/v1/x", headers: noisy, body: Data("{}".utf8)))
    }

    func testSignedHeadersLeaveEmptyValuesOutOfTheSignature() {
        var credentials = UUCredentials()
        credentials.token = "tok"
        credentials.csrf = "c"
        credentials.clientID = "client-1"
        let headers = UURequestSigner.signedHeaders(credentials: credentials, method: "GET", pathWithQuery: "/api/v1/x", body: Data())
        XCTAssertNil(headers["X-Param-device-id"])
        XCTAssertNil(headers["X-Param-user-id"])
        let sent = headers.filter { $0.key.lowercased().hasPrefix("x-param-") && $0.key != "X-Param-SIGN" }
        XCTAssertEqual(headers["X-Param-SIGN"], UURequestSigner.sign(method: "GET", pathWithQuery: "/api/v1/x", headers: sent, body: Data()))
        XCTAssertEqual(headers["Authorization"], "Bearer tok")
    }

    func testClaimsComeOutOfTheToken() {
        XCTAssertEqual(UURequestSigner.csrf(from: jwt(#"{"csrf":"abc123","uid":42}"#)), "abc123")
        XCTAssertEqual(UURequestSigner.userID(from: jwt(#"{"uid":42}"#)), "42")
        XCTAssertEqual(UURequestSigner.userID(from: jwt(#"{"sub":"777"}"#)), "777")
        XCTAssertNil(UURequestSigner.csrf(from: "not-a-jwt"))
    }

    func testGetRequestsHaveNoBody() {
        XCTAssertTrue(UUAPIRequest(method: "GET", path: "/api/v1/device/groups/of/my").body.isEmpty)
        XCTAssertEqual(UUAPIRequest(method: "POST", path: "/x").body, Data("{}".utf8))
    }

    func testDeviceFlagsReadAsBooleansOrNumbers() throws {
        var json: [String: Any] = ["device_id": "d1", "alias": "Mac", "status": "CONNECTED", "platform": 4, "controllable": true, "support_wol": false]
        let device = try XCTUnwrap(UUAPIClient.device(from: json))
        XCTAssertTrue(device.controllable && device.isOnline && device.isComputer)
        XCTAssertFalse(device.supportWOL)
        json["controllable"] = 1
        XCTAssertTrue(try XCTUnwrap(UUAPIClient.device(from: json)).controllable)
    }

    func testPhoneNumbersGoOutAsTheServiceTakesThem() {
        XCTAssertEqual(UUAPIClient.countryCode("+86"), "86")
        XCTAssertEqual(UUAPIClient.countryCode(" +1-264 "), "1-264")
        XCTAssertEqual(UUAPIClient.mobile("138 0013-8000"), "13800138000")
    }

    func testRoomConfigReadsFlatAndNestedAnswers() {
        let flat = UUAPIClient.roomConfig(from: ["token": "t", "signaling_server": "a", "signaling_list": ["a", "b"]])
        XCTAssertEqual(flat?.signalServers, ["a", "b"])
        XCTAssertEqual(flat?.timeout, 16000)
        let nested = UUAPIClient.roomConfig(from: ["room_config": ["token": "t", "signal_servers": ["c"], "timeout": 5000]])
        XCTAssertEqual(nested?.signalServers, ["c"])
        XCTAssertEqual(nested?.timeout, 5000)
        XCTAssertNil(UUAPIClient.roomConfig(from: ["token": "t"]))
    }

    func testDerivedDeviceIDIsStable() {
        let a = UURemoteAccount.derivedDeviceID(clientID: "c1", systemID: "s1")
        XCTAssertEqual(a, UURemoteAccount.derivedDeviceID(clientID: "c1", systemID: "s1"))
        XCTAssertNotEqual(a, UURemoteAccount.derivedDeviceID(clientID: "c2", systemID: "s1"))
        XCTAssertEqual(a.count, 16)
    }

    private func device(_ id: String, platform: Int, alias: String = "") -> UUDeviceInfo {
        var device = UUDeviceInfo()
        device.deviceID = id
        device.platform = platform
        device.alias = alias
        return device
    }

    @MainActor
    func testOnlyAMacHostsDeviceIsABorrowedSignIn() {
        let account = UURemoteAccount(storage: UUMemoryCredentialStorage(), clientName: "Rayon")
        let devices = [device("host-mac", platform: 4), device("own", platform: 1, alias: "Rayon · mac"), device("named", platform: 4, alias: "Rayon · m")]
        XCTAssertEqual(account.borrowedHost(deviceID: "host-mac", in: devices)?.deviceID, "host-mac")
        XCTAssertNil(account.borrowedHost(deviceID: "own", in: devices))
        XCTAssertNil(account.borrowedHost(deviceID: "named", in: devices))
        XCTAssertNil(account.borrowedHost(deviceID: "", in: devices))
        XCTAssertNil(account.borrowedHost(deviceID: "elsewhere", in: devices))
    }

    @MainActor
    func testHiddenDevicesAreNoDesktops() async {
        let account = UURemoteAccount(storage: UUMemoryCredentialStorage(), clientName: "Rayon")
        await account.adopt(UUCredentials(), devices: [device("pc", platform: 1, alias: "PC"), device("renamed", platform: 1, alias: "Office"), device("mac", platform: 4, alias: "Mac")])
        XCTAssertEqual(account.desktopDevices.map(\.deviceID), ["mac", "renamed", "pc"])
        account.hiddenDeviceIDs = ["renamed", "pc"]
        XCTAssertEqual(account.desktopDevices.map(\.deviceID), ["mac"])
    }

    func testOwnRegistrationsAreKnownByTheirExactName() {
        XCTAssertTrue(device("a", platform: 1, alias: "Rayon").isRegistration(of: "Rayon"))
        XCTAssertTrue(device("a", platform: 1, alias: "rayon · mini").isRegistration(of: "Rayon"))
        XCTAssertFalse(device("a", platform: 1, alias: "Rayon-lab-pc").isRegistration(of: "Rayon"))
        XCTAssertFalse(device("a", platform: 4, alias: "Rayon").isRegistration(of: "Rayon"))
    }

    @MainActor
    func testTheSignInIsKeptThroughTheStorage() async {
        var credentials = UUCredentials()
        credentials.userID = "u"
        credentials.deviceID = "d"
        credentials.clientID = "c"
        credentials.systemID = "s"
        credentials.token = "t"
        credentials.csrf = "x"
        let storage = UUMemoryCredentialStorage(UUSavedAccount(credentials: credentials, nickname: "Nick"))
        let account = UURemoteAccount(storage: storage, clientName: "Rayon")
        XCTAssertTrue(account.isLoggedIn)
        XCTAssertEqual(account.nickname, "Nick")
        account.logout()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(account.isLoggedIn)
        XCTAssertEqual(storage.load()?.credentials.deviceID, "d", "the registered device stays")
        XCTAssertEqual(storage.load()?.credentials.token, "")
    }

    func testQRCodeIsAPNG() {
        let png = UURemoteAccount.qrCode(for: "https://example.com")
        XCTAssertEqual(png?.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
    }
}
