import Foundation
import Security
import tetmuxCore

/// Per-host password storage in the login Keychain.
///
/// Lives in `tetmuxUI` rather than `tetmuxCore` on purpose. `Security.framework` is as macOS-only as
/// AppKit is, and §2.4 keeps the protocol, transport, and session layers free of anything that would
/// not build elsewhere. `SessionService` never reads a credential; it publishes the prompt and is
/// handed an answer, so the platform boundary stays where the SRD put it.
///
/// Items are `kSecClassInternetPassword` with `kSecAttrProtocol` = ssh, keyed by server, account, and
/// port. That is the same shape other ssh clients use, so an entry is recognisable in Keychain Access
/// and revocable there without going through tetmux.
public enum KeychainStore {
    /// Blocking Keychain calls, kept off both the main thread and `SessionService`'s actor.
    ///
    /// `SecItemCopyMatching` can put a system dialog on screen — an unsigned development build gets
    /// asked about every time, because the ACL is tied to the code signature. On the main thread that
    /// is a beachball, and inside the actor it would stall every other host's channel behind it.
    public static func password(for config: HostConfig) async -> String? {
        await Task.detached(priority: .userInitiated) {
            var query = baseQuery(for: config)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            guard status == errSecSuccess, let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }.value
    }

    /// Adds or replaces the stored password. Returns the `OSStatus` message on failure so the caller
    /// can show it verbatim rather than guessing why saving did not work.
    @discardableResult
    public static func save(_ password: String, for config: HostConfig) async -> String? {
        await Task.detached(priority: .userInitiated) {
            let query = baseQuery(for: config)
            let attributes: [String: Any] = [kSecValueData as String: Data(password.utf8)]

            let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if update == errSecSuccess { return nil }

            if update == errSecItemNotFound {
                var insert = query
                insert[kSecValueData as String] = Data(password.utf8)
                // Available whenever the user is logged in, and never synced to iCloud: a password to
                // a specific machine on a specific network is not useful on another device, and the
                // fewer places it exists the better.
                insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
                let add = SecItemAdd(insert as CFDictionary, nil)
                return add == errSecSuccess ? nil : message(for: add)
            }
            return message(for: update)
        }.value
    }

    public static func delete(for config: HostConfig) async {
        await Task.detached(priority: .userInitiated) {
            _ = SecItemDelete(baseQuery(for: config) as CFDictionary)
        }.value
    }

    /// The attributes that *identify* an item. Deliberately excludes the password itself, so the same
    /// dictionary can be used to look up, update, and delete.
    private static func baseQuery(for config: HostConfig) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrProtocol as String: kSecAttrProtocolSSH,
            kSecAttrServer as String: config.hostname ?? config.name,
            // Distinguishes this entry in Keychain Access from one another ssh client wrote.
            kSecAttrLabel as String: "tetmux — \(config.name)",
        ]
        // An account is part of the item's identity, so it has to be present consistently. Hosts
        // whose user comes from ~/.ssh/config have none here, and the empty string is a stable stand-in
        // for "whatever ssh resolves it to".
        query[kSecAttrAccount as String] = config.user ?? ""
        if let port = config.port {
            query[kSecAttrPort as String] = port
        }
        return query
    }

    private static func message(for status: OSStatus) -> String {
        SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
    }
}
