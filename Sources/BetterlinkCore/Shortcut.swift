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
    /// Control-Option-F (kVK_ANSI_F is 3): the Find Tab panel.
    public static let findTabDefault = Shortcut(keyCode: 3, modifiers: control | option, key: "F")

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

    /// Reads a shortcut as a person or an agent writes it: "ctrl+opt+f",
    /// "control+shift+1", or the menu glyphs "⌃⌥F". Nil for anything else or
    /// a shortcut that isn't `isValid`. Letters, digits and Space only.
    public static func parse(_ text: String) -> Shortcut? {
        let glyphs: [Character: UInt32] = ["⌃": control, "⌥": option, "⇧": shift, "⌘": command]
        let names: [String: UInt32] = ["ctrl": control, "control": control, "opt": option, "option": option, "alt": option,
                                       "shift": shift, "cmd": command, "command": command]
        var mods: UInt32 = 0
        var key: String
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.contains("+") {
            var parts = t.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard parts.count >= 2, let last = parts.popLast() else { return nil }
            for part in parts {
                guard let m = names[part] else { return nil }
                mods |= m
            }
            key = last
        } else {
            var rest = Substring(t)
            while let c = rest.first, let m = glyphs[c] { mods |= m; rest = rest.dropFirst() }
            key = String(rest).lowercased()
        }
        let codes: [String: UInt32] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
            "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
            "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
            "n": 45, "m": 46, "space": 49,
        ]
        guard let code = codes[key] else { return nil }
        let s = Shortcut(keyCode: code, modifiers: mods, key: key == "space" ? "Space" : key.uppercased())
        return s.isValid ? s : nil
    }

    public static func load(_ defaults: UserDefaults, key k: String) -> Shortcut? {
        defaults.data(forKey: k).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }.flatMap { $0.isValid ? $0 : nil }
    }

    public func save(_ defaults: UserDefaults, key k: String) {
        if let d = try? JSONEncoder().encode(self) { defaults.set(d, forKey: k) }
    }
}
