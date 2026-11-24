import Foundation

/// A keyboard shortcut the user picked: a key plus at least one of Control,
/// Option or Command (Shift alone would take ordinary typing). Stored per Mac,
/// like the menu bar icon.
public struct Shortcut: Codable, Equatable, Sendable {
    /// The macOS virtual key code (kVK_*).
    public var keyCode: UInt32
    /// Carbon modifier mask: command 256, shift 512, option 2048, control 4096.
    public var modifiers: UInt32
    /// The key's label as typed, upper-cased ("S", "1", "/").
    public var key: String

    public static let command: UInt32 = 256, shift: UInt32 = 512, option: UInt32 = 2048, control: UInt32 = 4096

    public init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode; self.modifiers = modifiers & (Self.command | Self.shift | Self.option | Self.control); self.key = key
    }

    /// Control-Option-S (kVK_ANSI_S is 1).
    public static let sidebarDefault = Shortcut(keyCode: 1, modifiers: control | option, key: "S")

    /// Usable as a system-wide shortcut: a key and Control, Option or Command.
    public var isValid: Bool {
        !key.isEmpty && modifiers & (Self.command | Self.option | Self.control) != 0
    }

    /// "⌃⌥⇧⌘S", in the order macOS menus use.
    public var display: String {
        var s = ""
        if modifiers & Self.control != 0 { s += "⌃" }
        if modifiers & Self.option != 0 { s += "⌥" }
        if modifiers & Self.shift != 0 { s += "⇧" }
        if modifiers & Self.command != 0 { s += "⌘" }
        return s + key
    }

    public static func load(_ defaults: UserDefaults, key k: String) -> Shortcut? {
        defaults.data(forKey: k).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }.flatMap { $0.isValid ? $0 : nil }
    }

    public func save(_ defaults: UserDefaults, key k: String) {
        if let d = try? JSONEncoder().encode(self) { defaults.set(d, forKey: k) }
    }
}
