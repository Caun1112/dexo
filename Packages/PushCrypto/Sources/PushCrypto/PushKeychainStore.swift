import Foundation
import Security

public enum PushKeychainError: Error, Equatable {
    case invalidConfiguration
    case unexpectedStatus(OSStatus)
    case malformedRecord
}

public struct PushKeychainStore: Sendable {
    private let service: String
    private let accessGroup: String

    public init(
        service: String = "com.eilgnaw.dexo.webpush",
        accessGroup: String
    ) throws {
        guard !service.isEmpty,
              !accessGroup.isEmpty,
              !accessGroup.contains("$(") else {
            throw PushKeychainError.invalidConfiguration
        }
        self.service = service
        self.accessGroup = accessGroup
    }

    public func save(_ subscription: StoredWebPushSubscription) throws {
        let data = try JSONEncoder().encode(subscription)
        let query = baseQuery(account: subscription.subscriptionID)
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw PushKeychainError.unexpectedStatus(status)
        }
    }

    public func load(subscriptionID: String) throws -> StoredWebPushSubscription {
        var query = baseQuery(account: subscriptionID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            throw PushKeychainError.unexpectedStatus(status)
        }
        guard let data = item as? Data,
              let record = try? JSONDecoder().decode(StoredWebPushSubscription.self, from: data),
              record.version == 1,
              record.subscriptionID == subscriptionID else {
            throw PushKeychainError.malformedRecord
        }
        return record
    }

    public func delete(subscriptionID: String) throws {
        let status = SecItemDelete(baseQuery(account: subscriptionID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PushKeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: false,
        ]
    }
}
