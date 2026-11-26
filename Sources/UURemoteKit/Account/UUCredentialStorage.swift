//
//  UUCredentialStorage.swift
//  UURemoteKit
//
//  Where an account's sign-in is kept between launches. The host app picks
//  the store; the kit never writes anywhere on its own.
//

import Foundation
import os
import Security

/// What is kept of an account: the sign-in, the device identity it was made
/// with, and the name the sign-in answered with (no request returns it later).
public struct UUSavedAccount: Codable, Equatable, Sendable {
    public var credentials: UUCredentials
    public var nickname: String

    public init(credentials: UUCredentials, nickname: String = "") {
        self.credentials = credentials
        self.nickname = nickname
    }
}

public protocol UUCredentialStorage: Sendable {
    func load() -> UUSavedAccount?
    /// Replaces what is kept; nil forgets it.
    func save(_ account: UUSavedAccount?)
}

/// The sign-in as one generic-password item in the keychain.
public struct UUKeychainCredentialStorage: UUCredentialStorage {
    public let service: String
    public let account: String

    public init(service: String, account: String = "uu-remote-account") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func load() -> UUSavedAccount? {
        var query = query
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return try? JSONDecoder().decode(UUSavedAccount.self, from: data)
    }

    public func save(_ saved: UUSavedAccount?) {
        guard let saved, let data = try? JSONEncoder().encode(saved) else {
            SecItemDelete(query as CFDictionary)
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
    }
}

/// Keeps the sign-in for as long as the process runs: previews, tests.
public final class UUMemoryCredentialStorage: UUCredentialStorage {
    private let saved: OSAllocatedUnfairLock<UUSavedAccount?>

    public init(_ account: UUSavedAccount? = nil) {
        saved = OSAllocatedUnfairLock(initialState: account)
    }

    public func load() -> UUSavedAccount? { saved.withLock { $0 } }
    public func save(_ account: UUSavedAccount?) { saved.withLock { $0 = account } }
}
