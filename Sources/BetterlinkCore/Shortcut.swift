import Foundation

/// A keyboard shortcut the user picked: a key with Control (see `isValid`),
/// never one of the browser's own Control shortcuts. Stored per Mac, like the
/// menu bar icon.
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

    /// Usable as a system-wide shortcut: a key with Control. Without Control
    /// it would take something else while the browser is in front: Command
    /// combinations are the browser's own (⌘T, ⌥⌘I for DevTools), and Option
    /// combinations type characters (⌥S types ß).
    public var isValid: Bool {
        !key.isEmpty && modifiers & Self.control != 0 && !isBrowserShortcut
    }

    /// The Control shortcuts browsers define themselves. Chromium spreads them
    /// over several tables: global_keyboard_shortcuts_mac.mm (⌃PageUp/⌃PageDown,
    /// with or without Shift, switch and move tabs; ⌃⌘C/P/W/X/Z act on tab
    /// groups), accelerators_cocoa.mm (⌃⇥ and ⌃⇧⇥ cycle tabs, as in Safari)
    /// and main_menu_builder.mm (⌃⌘F full screen, as in every Mac app).
    public var isBrowserShortcut: Bool {
        let tabCycling: Set<UInt32> = [116, 121, 48] // PageUp, PageDown, Tab
        if tabCycling.contains(keyCode), modifiers & ~Self.shift == Self.control { return true }
        if keyCode == 3, modifiers == Self.control | Self.command { return true } // ⌃⌘F
        let groupKeys: Set<UInt32> = [8, 35, 13, 7, 6] // C, P, W, X, Z
        return groupKeys.contains(keyCode) && modifiers == Self.control | Self.command
    }

    /// A readable label for keys whose typed character is invisible or private
    /// (Space, Return, arrows, F-keys), else `typed` upper-cased.
    public static func label(keyCode: UInt32, typed: String) -> String {
        let named: [UInt32: String] = [49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋", 123: "←", 124: "→",
                                       125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
                                       122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
                                       101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        if let n = named[keyCode] { return n }
        let t = typed.uppercased()
        // Function keys type characters in the private-use area.
        if t.unicodeScalars.contains(where: { (0xF700...0xF8FF).contains($0.value) }) { return "" }
        return t
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
