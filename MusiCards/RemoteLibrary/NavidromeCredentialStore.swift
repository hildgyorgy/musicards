import Foundation
import Security

struct NavidromeCredentialStore: Sendable {
    private let service: String

    init(service: String = "hu.hildgyorgy.MusiCards.navidrome") {
        self.service = service
    }

    func save(password: String, for profileID: UUID) throws {
        let passwordData = Data(password.utf8)
        let query = baseQuery(for: profileID)
        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData: passwordData] as CFDictionary
        )

        if status == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = passwordData
            newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            try check(SecItemAdd(newItem as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    func password(for profileID: UUID) throws -> String? {
        var query = baseQuery(for: profileID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        try check(status)

        guard let data = item as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw NavidromeCredentialStoreError.invalidStoredPassword
        }
        return password
    }

    func deletePassword(for profileID: UUID) throws {
        let status = SecItemDelete(baseQuery(for: profileID) as CFDictionary)
        if status != errSecItemNotFound {
            try check(status)
        }
    }

    private func baseQuery(for profileID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString
        ]
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw NavidromeCredentialStoreError.keychain(status)
        }
    }
}

enum NavidromeCredentialStoreError: Error, Equatable, Sendable {
    case keychain(OSStatus)
    case invalidStoredPassword
}
