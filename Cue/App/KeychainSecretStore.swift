import CueCore
import Foundation
import Security

/// Secret environment values in the login Keychain: service `Cue`, account `<itemID>.<KEY>` (spec §11).
struct KeychainSecretStore: SecretStore {
    static let service = "Cue"

    struct KeychainError: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
        }
    }

    private func query(_ itemID: UUID, _ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: "\(itemID.uuidString).\(key)",
        ]
    }

    func secret(itemID: UUID, key: String) -> String? {
        var query = query(itemID, key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setSecret(_ value: String, itemID: UUID, key: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(itemID, key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query(itemID, key)
            attributes[kSecValueData as String] = data
            attributes[kSecAttrLabel as String] = "Cue secret \(key)"
            let added = SecItemAdd(attributes as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    func deleteSecret(itemID: UUID, key: String) {
        SecItemDelete(query(itemID, key) as CFDictionary)
    }
}

/// Values typed in the editor first, then the Keychain: lets a Test Run use secrets before they're saved.
struct OverlaySecretStore: SecretStore {
    let drafts: [String: String]
    let itemID: UUID
    let base: any SecretStore

    func secret(itemID: UUID, key: String) -> String? {
        if itemID == self.itemID, let value = drafts[key] { return value }
        return base.secret(itemID: itemID, key: key)
    }
}
