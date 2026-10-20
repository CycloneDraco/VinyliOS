import Foundation
import Security

/// Small items shared by the app and its widgets: the Spotify login and a
/// note of what's playing. Both targets list one keychain access group (and
/// only that one), which makes it the default group for everything written
/// here; nothing needs to name it, so it keeps working after re-signing with
/// another team. Readable after first unlock, so widgets and Live Activity
/// buttons work while the device is locked.
enum Keychain {
    private static let service = "io.github.cyclonedraco.vinyl.ios"

    static func read(_ account: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func write(_ data: Data, for account: String) {
        // Delete-then-add (rather than update) so the item always lands in
        // the default, shared group, even if an older copy lived elsewhere.
        delete(account)
        let item: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Before 1.3 items lived in the app's private group, out of the widgets'
    /// reach. Rewriting moves them into the shared one.
    static func moveToSharedGroup(_ account: String) {
        guard let data = read(account) else { return }
        write(data, for: account)
    }
}
