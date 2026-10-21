import Foundation

enum FeedURL {
    /// Accepts a pasted calendar link: https, or webcal (rewritten to https). Nothing else, so a pasted
    /// string can't point the app at file:// or other local schemes.
    static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("webcal://") { s = "https://" + s.dropFirst("webcal://".count) }
        guard let u = URL(string: s), u.scheme?.lowercased() == "https", u.host?.isEmpty == false else { return nil }
        return u
    }
}
