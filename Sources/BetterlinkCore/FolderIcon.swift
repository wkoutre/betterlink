import Foundation

/// What a folder in the sidebar shows in place of the folder glyph: an emoji,
/// or one of the Mac's built-in symbols (an SF Symbol, by name).
///
/// Kept in sidebar.json and in sync as one string, "emoji:🚀" or
/// "symbol:star.fill", so a field holds it whole and the higher stamp wins it
/// whole. A kind this betterlink doesn't know (one a newer betterlink wrote)
/// is kept as it is, never dropped, and drawn as the plain folder glyph.
public enum FolderIcon: Codable, Hashable, Sendable {
    case emoji(String)
    case symbol(String)
    case unknown(String)

    public init(raw: String) {
        if raw.hasPrefix("emoji:") { self = .emoji(String(raw.dropFirst(6))) }
        else if raw.hasPrefix("symbol:") { self = .symbol(String(raw.dropFirst(7))) }
        else { self = .unknown(raw) }
    }

    public var raw: String {
        switch self {
        case .emoji(let e): return "emoji:\(e)"
        case .symbol(let s): return "symbol:\(s)"
        case .unknown(let r): return r
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(raw: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }

    // MARK: Checking what a person or an agent typed

    /// Why a typed icon was refused, in words to show them.
    public struct Invalid: Error, Equatable, Sendable {
        public let message: String
    }

    /// One emoji, as typed or picked: a single character (a flag, a family or
    /// a skin tone counts as one) that is drawn as an emoji. Spaces around it
    /// are dropped.
    public static func checkedEmoji(_ text: String) throws -> FolderIcon {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let c = t.first, t.count == 1 else {
            throw Invalid(message: t.isEmpty ? "Give an emoji." : "Give one emoji, not \(t.count) characters.")
        }
        // The longest real ones (a family, a tagged flag) are under 40 bytes.
        guard t.utf8.count <= 64, isEmoji(c) else { throw Invalid(message: "\"\(t)\" isn't an emoji.") }
        return .emoji(t)
    }

    /// Whether a character is drawn as an emoji: one of its scalars is shown
    /// as an emoji by default (🚀, a flag's letters), or it is an emoji that
    /// asks to be drawn as one (❤️, 1️⃣: the character and U+FE0F). A digit, #
    /// or © alone is text.
    static func isEmoji(_ c: Character) -> Bool {
        let scalars = c.unicodeScalars
        if scalars.contains(where: { $0.properties.isEmojiPresentation }) { return true }
        guard let first = scalars.first, first.properties.isEmoji else { return false }
        return scalars.contains { $0.value == 0xFE0F }
    }

    /// The longest symbol name taken. The Mac's longest are about 50 characters.
    static let maxSymbolLength = 100

    /// A built-in symbol, by its name in Apple's SF Symbols (star.fill,
    /// folder.badge.person.crop). This checks the shape of the name;
    /// `exists`, where AppKit is at hand, checks that this Mac draws it.
    public static func checkedSymbol(_ text: String, exists: ((String) -> Bool)? = nil) throws -> FolderIcon {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw Invalid(message: "Give a symbol name, such as star.fill.") }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard t.count <= maxSymbolLength, t.unicodeScalars.allSatisfy(allowed.contains),
              parts.allSatisfy({ !$0.isEmpty }), t.first!.isLetter || t.first!.isNumber else {
            throw Invalid(message: "\"\(t)\" isn't a symbol name. Names look like star.fill or folder.badge.plus (the SF Symbols app lists them).")
        }
        if let exists, !exists(t) {
            throw Invalid(message: "This Mac has no symbol called \"\(t)\". Names look like star.fill or folder.badge.plus (the SF Symbols app lists them).")
        }
        return .symbol(t)
    }
}
