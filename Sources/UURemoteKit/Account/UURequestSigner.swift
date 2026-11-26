//
//  UURequestSigner.swift
//  UURemoteKit
//
//  The X-Param signature every request to the service carries, and the
//  claims read out of its JWT access token.
//

import CryptoKit
import Foundation

/// Builds the signed request the API expects: METHOD + pathWithQuery +
/// x-param-* headers (lowercase keys sorted, excluding x-param-sign) + body.
public enum UURequestSigner {
    public static func sign(
        method: String,
        pathWithQuery: String,
        headers: [String: String],
        body: Data,
        signKey: String = UUConstants.signingKey
    ) -> String {
        let base = signatureBase(method: method, pathWithQuery: pathWithQuery, headers: headers, body: body)
        let key = SymmetricKey(data: Data(signKey.utf8))
        let signature = HMAC<SHA256>.authenticationCode(for: Data(base.utf8), using: key)
        return signature.map { String(format: "%02x", $0) }.joined()
    }

    public static func signatureBase(
        method: String,
        pathWithQuery: String,
        headers: [String: String],
        body: Data
    ) -> String {
        let xParam = headers
            .map { ($0.key.lowercased(), $0.value) }
            .filter { $0.0.hasPrefix("x-param-") && $0.0 != "x-param-sign" }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")
        return "\(method.uppercased())\(pathWithQuery)\(xParam)\(String(decoding: body, as: UTF8.self))"
    }

    /// The static x-param-* headers every request carries.
    public static func commonHeaders(credentials: UUCredentials, timestamp: Int? = nil, abi: String? = nil) -> [String: String] {
        var headers: [String: String] = [
            "X-Param-CHN": UUConstants.channel,
            "X-Param-PKGN": UUConstants.packageName,
            // The built-in signing key belongs to the PC client (platform 1);
            // any other platform's signature is refused as an invalid token.
            "X-Param-PLAT": "1",
            "X-Param-VC": UUConstants.versionCode,
            "X-Param-VN": UUConstants.versionName,
            "X-Param-TS": String(timestamp ?? Int(Date().timeIntervalSince1970)),
            "X-Param-CNT": UUConstants.country,
            "X-Param-LANG": UUConstants.language,
        ]
        if let abi { headers["X-Param-ABI"] = abi }
        if !credentials.clientID.isEmpty { headers["X-Param-client-id"] = credentials.clientID }
        if !credentials.deviceID.isEmpty { headers["X-Param-device-id"] = credentials.deviceID }
        if !credentials.systemID.isEmpty { headers["X-Param-system-id"] = credentials.systemID }
        if !credentials.userID.isEmpty { headers["X-Param-user-id"] = credentials.userID }
        if let guest = credentials.guestID, !guest.isEmpty { headers["X-Param-guest-id"] = guest }
        return headers
    }

    /// Assembles all headers for a signed request, including auth and cookies.
    ///
    /// Headers with empty values (a missing device id before registration,
    /// the always-empty `X-Param-OPR`) are dropped *before* signing so the
    /// signature covers exactly the `X-Param-*` set the wire carries —
    /// `URLRequest` cannot reliably send empty header values, and the server
    /// recomputes the signature over the headers it actually receives.
    public static func signedHeaders(
        credentials: UUCredentials,
        method: String,
        pathWithQuery: String,
        body: Data,
        timestamp: Int? = nil
    ) -> [String: String] {
        var headers = commonHeaders(credentials: credentials, timestamp: timestamp)
            .filter { !$0.value.isEmpty }
        headers["X-Param-SIGN"] = sign(
            method: method,
            pathWithQuery: pathWithQuery,
            headers: headers,
            body: body,
            signKey: credentials.signKey
        )
        if !credentials.token.isEmpty {
            headers["Authorization"] = "Bearer \(credentials.token)"
            headers["Cookie"] = "nrd_access_token=\(credentials.token);nrd_csrf_access_token=\(credentials.csrf)"
            headers["X-CSRF-TOKEN"] = credentials.csrf
        }
        return headers
    }

    /// The decoded claims of a JWT access token, or nil when it is not a JWT.
    public static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Re-pad to a multiple of 4 (JWTs strip the padding).
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// The `csrf` claim inside a JWT access token.
    public static func csrf(from token: String) -> String? {
        jwtPayload(token)?["csrf"] as? String
    }

    /// The account user id inside a JWT access token (`uid`, `user_id` or
    /// `sub` — token vintages differ), for token imports that arrive without
    /// a login response to read `user_id` from.
    public static func userID(from token: String) -> String? {
        guard let claims = jwtPayload(token) else { return nil }
        for key in ["uid", "user_id", "sub"] {
            if let value = claims[key] as? String, !value.isEmpty { return value }
            if let value = claims[key] as? NSNumber { return value.stringValue }
        }
        return nil
    }
}
