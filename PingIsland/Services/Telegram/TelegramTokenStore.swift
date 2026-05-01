import Foundation
import Security

protocol TelegramTokenStoring {
    func save(_ token: String) throws
    func load() throws -> String?
    func clear() throws
}

struct TelegramTokenStore {
    private let service: String
    private let account: String

    init(
        service: String = "app.pingisland.telegram",
        account: String = "bot-token"
    ) {
        self.service = service
        self.account = account
    }

    func save(_ token: String) throws {
        let data = Data(token.utf8)
        let query = baseQuery()
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw TelegramTokenStoreError.keychainStatus(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw TelegramTokenStoreError.keychainStatus(addStatus)
        }
    }

    func load() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw TelegramTokenStoreError.keychainStatus(status)
        }

        guard let data = result as? Data else {
            throw TelegramTokenStoreError.invalidData
        }

        return String(data: data, encoding: .utf8)
    }

    func clear() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TelegramTokenStoreError.keychainStatus(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

extension TelegramTokenStore: TelegramTokenStoring {}

enum TelegramTokenStoreError: Error, Equatable {
    case keychainStatus(OSStatus)
    case invalidData
}
