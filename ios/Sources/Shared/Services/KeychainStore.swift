import Foundation
import Security

public enum KeychainStore {
    public static func set(_ value: String, for key: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(for: key)
        var deleteQuery = query
        deleteQuery.removeValue(forKey: kSecReturnData as String)
        deleteQuery.removeValue(forKey: kSecMatchLimit as String)
        SecItemDelete(deleteQuery as CFDictionary)
        SecItemDelete(baseQuery(for: key, useAccessGroup: false) as CFDictionary)

        var attributes = deleteQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    public static func get(_ key: String) -> String? {
        if let value = get(key, useAccessGroup: true) {
            return value
        }
        return get(key, useAccessGroup: false)
    }

    public static func delete(_ key: String) {
        SecItemDelete(baseQuery(for: key) as CFDictionary)
        SecItemDelete(baseQuery(for: key, useAccessGroup: false) as CFDictionary)
    }

    private static func get(_ key: String, useAccessGroup: Bool) -> String? {
        let query = baseQuery(for: key, useAccessGroup: useAccessGroup).merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]) { _, new in new }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    private static func baseQuery(for key: String, useAccessGroup: Bool = true) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]

        if useAccessGroup, let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private static var accessGroup: String? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "ZWKeychainAccessGroup") as? String,
              !group.isEmpty else {
            return nil
        }
        return group
    }
}
