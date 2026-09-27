import Foundation
import Security

enum RemoteCredentialStore {
    private static let service = "io.github.LJY0317.PluraMobile.remote"
    private static let tokenAccount = "bridge-capability-token"
    private static let serverURLAccount = "bridge-server-url"
    private static let targetIDAccount = "bridge-target-id"
    private static let endpointsAccount = "bridge-endpoints"

    static func loadToken() -> String? {
        loadString(account: tokenAccount)
    }

    static func loadServerURL() -> String? {
        loadString(account: serverURLAccount)
    }

    static func loadTargetID() -> String? {
        loadString(account: targetIDAccount)
    }

    static func loadEndpoints() -> [RemoteConnectionEndpoint] {
        guard let encoded = loadString(account: endpointsAccount),
              let data = encoded.data(using: .utf8),
              let values = try? JSONDecoder().decode([RemoteConnectionEndpoint].self, from: data)
        else { return [] }
        return values.sorted { $0.priority < $1.priority }
    }

    private static func loadString(account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty
        else { return nil }
        return token
    }

    static func saveToken(_ token: String) throws {
        try saveString(token, account: tokenAccount)
    }

    static func saveServerURL(_ serverURL: String) throws {
        try saveString(serverURL, account: serverURLAccount)
    }

    static func saveTargetID(_ targetID: String) throws {
        try saveString(targetID, account: targetIDAccount)
    }

    static func saveEndpoints(_ endpoints: [RemoteConnectionEndpoint]) throws {
        let data = try JSONEncoder().encode(endpoints.sorted { $0.priority < $1.priority })
        guard let value = String(data: data, encoding: .utf8) else { return }
        try saveString(value, account: endpointsAccount)
    }

    private static func saveString(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let lookup: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let update: [CFString: Any] = [kSecValueData: data]
        let status = SecItemUpdate(lookup as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = lookup
            add[kSecValueData] = data
            add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    static func deletePairing() throws {
        for account in [tokenAccount, serverURLAccount, targetIDAccount, endpointsAccount] {
            try deleteString(account: account)
        }
    }

    private static func deleteString(account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private struct KeychainError: Error {
        let status: OSStatus
    }
}
