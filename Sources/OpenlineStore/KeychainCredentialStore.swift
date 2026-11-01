// Copyright (C) 2026 Openline contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import OpenlineCore
import Security

public struct KeychainError: Error, LocalizedError {
    public let status: OSStatus
    public var errorDescription: String? {
        SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
    }
}

public struct KeychainCredentialStore: CredentialStore {
    private let service: String

    public init(service: String = "org.openline.sip") {
        self.service = service
    }

    private func query(_ reference: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: reference]
    }

    public func password(for reference: String) throws -> String? {
        var item: CFTypeRef?
        var attributes = query(reference)
        attributes[kSecReturnData] = true
        attributes[kSecMatchLimit] = kSecMatchLimitOne
        let status = SecItemCopyMatching(attributes as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }

    public func setPassword(_ password: String, for reference: String) throws {
        let data = Data(password.utf8)
        var status = SecItemUpdate(query(reference) as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query(reference)
            attributes[kSecValueData] = data
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func deletePassword(for reference: String) throws {
        let status = SecItemDelete(query(reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

/// For tests and the integration agent; never constructed by the application.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init() {}

    public func password(for reference: String) throws -> String? {
        lock.withLock { values[reference] }
    }

    public func setPassword(_ password: String, for reference: String) throws {
        lock.withLock { values[reference] = password }
    }

    public func deletePassword(for reference: String) throws {
        lock.withLock { values[reference] = nil }
    }
}
