import Foundation
import Security

/// One generic-password Keychain item, readable after first unlock, kept on this device and never synced.
public struct KeychainStore: SecretStore {
    /// The item holding the credential of the one active connection.
    public static let activeConnection = KeychainStore(service: "com.jutsustudio.connection", account: "active")
    /// The same item for Debug builds. They are signed with a development certificate, and the Keychain trusts
    /// only the build that created an item: a release build finding a Debug build's item makes macOS ask for the
    /// login keychain password, so the two never share one.
    public static let developmentConnection = KeychainStore(
        service: "com.jutsustudio.connection.debug", account: "active")

    public let service: String
    public let account: String
    public let accessGroup: String?

    public init(service: String, account: String, accessGroup: String? = nil) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    public func saveData(_ data: Data) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(itemQuery as CFDictionary, attributes as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            let newItem = itemQuery.merging(attributes) { _, new in new }
            let addStatus = SecItemAdd(newItem as CFDictionary, nil)
            switch addStatus {
            case errSecSuccess:
                return
            case errSecDuplicateItem:
                // Another writer added the item between our update and add; overwrite theirs.
                try check(SecItemUpdate(itemQuery as CFDictionary, attributes as CFDictionary))
            default:
                throw KeychainError(status: addStatus)
            }
        default:
            throw KeychainError(status: status)
        }
    }

    public func loadData() throws -> Data? {
        var query = itemQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeychainError(status: errSecInternalError) }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    public func delete() throws {
        let status = SecItemDelete(itemQuery as CFDictionary)
        if status != errSecItemNotFound {
            try check(status)
        }
    }

    private var itemQuery: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}

/// A failed Keychain call. Carries only the status code, never the stored value.
public struct KeychainError: Error, Equatable, CustomStringConvertible, LocalizedError {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }

    public var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
        return "Keychain error \(status): \(message)"
    }

    public var errorDescription: String? { description }
}
