import Foundation
import Security

/// The Canvas feed link carries a private token, so it lives in the Keychain, not UserDefaults.
enum Keychain {
    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "feed", kSecAttrAccount as String: key]
    }
    static func get(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    @discardableResult
    static func set(_ value: String?, _ key: String) -> OSStatus {
        SecItemDelete(query(key) as CFDictionary)
        guard let value else { return errSecSuccess }
        var q = query(key)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(q as CFDictionary, nil)
    }
}

enum Feed {
    static let key = "feedURL"            // legacy single link
    static let listKey = "feedURLs"       // JSON array of links
    static let freeLimit = 1

    static func links() -> [String] {
        if let j = Keychain.get(listKey), let a = try? JSONDecoder().decode([String].self, from: Data(j.utf8)) { return a }
        if let old = Keychain.get(key) { return [old] }   // migrate the single-link version
        return []
    }
    @discardableResult
    static func setLinks(_ a: [String]) -> OSStatus {
        Keychain.set(nil, key)
        return Keychain.set(a.isEmpty ? nil : (try? String(data: JSONEncoder().encode(a), encoding: .utf8)) ?? nil, listKey)
    }
    /// A link's host only: the full link is a secret.
    static func label(_ link: String) -> String { URL(string: link)?.host ?? "Calendar feed" }

    /// Downloads every link and joins the calendars into one text. Fails if any link fails, so a bad link is never silently dropped.
    static func fetchAll(_ links: [String]) async throws -> String {
        var parts: [String] = []
        for l in links { parts.append(try await fetch(l)) }
        return parts.joined(separator: "\n")
    }
    struct Failure: LocalizedError { var errorDescription: String? }

    static func fetch(_ link: String) async throws -> String {
        var url = FeedURL.normalize(link)
        #if DEBUG
        if url == nil, link.hasPrefix("file://") { url = URL(string: link) }   // local testing only
        #endif
        guard let url else { throw Failure(errorDescription: "That doesn't look like an https or webcal link.") }
        let (data, resp) = try await URLSession.shared.data(from: url)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw Failure(errorDescription: "The feed returned HTTP \(http.statusCode). The link may have been reset.")
        }
        guard let text = String(data: data, encoding: .utf8), text.contains("BEGIN:VCALENDAR") else {
            throw Failure(errorDescription: "That link didn't return a calendar feed.")
        }
        return text
    }
}
