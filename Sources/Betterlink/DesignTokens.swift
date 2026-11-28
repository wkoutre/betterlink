// Generated from Design/tokens.json by scripts/gen-tokens.py. Do not edit.
// Change the tokens there and run `make tokens`.

import AppKit
import SwiftUI

/// betterlink's design tokens. See Design/tokens.json for what each is for.
/// Text styles and sizes are at the chosen text size (TextScale.swift); the
/// numbers here are theirs at the standard one.
enum DS {
    enum Palette {
        /// The window background. Everything else sits on it.
        static let canvas = dynamic(light: 0xF5F7FB, dark: 0x0E1320)
        /// The sidebar column: one step darker than canvas, so content sits forward.
        static let sidebar = dynamic(light: 0xECEFF6, dark: 0x0A0E18)
        /// Section cards and sheets: the surface content lives on.
        static let panel = dynamic(light: 0xFFFFFF, dark: 0x151B2A)
        /// Menus, popovers and anything that floats; always with border-subtle and shadow-raised.
        static let raised = dynamic(light: 0xFFFFFF, dark: 0x1B2233)
        /// Fill of a row, menu item or plain button under the pointer.
        static let hover = dynamic(light: 0xEEF3FB, dark: 0x212A3D)
        /// Fill of the chosen row or option. Pair with text for its label.
        static let selected = dynamic(light: 0xE4EDFD, dark: 0x1E2C4A)
        /// Hairlines between rows and around cards. Divides; never the only sign of a control.
        static let borderSubtle = dynamic(light: 0xE4E9F2, dark: 0x242E43)
        /// Text field and control outlines, where a visible edge is needed.
        static let border = dynamic(light: 0xCFD8E6, dark: 0x323E57)
        /// Titles, rule patterns, profile names: what the eye lands on.
        static let text = dynamic(light: 0x141C33, dark: 0xEEF2FA)
        /// Body copy, the words around a value ("Open", "in"), menu text.
        static let textSecondary = dynamic(light: 0x434E68, dark: 0xBAC3D6)
        /// Meta: folder names, timestamps, file paths, captions.
        static let textTertiary = dynamic(light: 0x5C6781, dark: 0x959FB6)
        /// Placeholders and disabled labels only. Below 4.5:1; never for content.
        static let textPlaceholder = dynamic(light: 0x8B95AB, dark: 0x6C7790)
        /// The one primary action in a view (Done, Make Default Browser) and the switch tint.
        static let accent = dynamic(light: 0x2563EB, dark: 0x5B8DEF)
        /// Primary button under the pointer or pressed.
        static let accentHover = dynamic(light: 0x1D4FCB, dark: 0x7AA3F3)
        /// Text and glyphs on accent and accent-hover.
        static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x0B1222)
        /// Links and text buttons.
        static let accentText = dynamic(light: 0x1F55D0, dark: 0x8CB0F6)
        /// Quiet wash behind a selected chip or an info banner, with accent-text on it.
        static let accentTint = dynamic(light: 0xE6EEFD, dark: 0x1A2848)
        /// Second brand hue, from the icon's second path. Illustration and profile colour only; never a state.
        static let coral = dynamic(light: 0xF0735A, dark: 0xF2846D)
        /// Coral as text, for example a highlighted word in docs.
        static let coralText = dynamic(light: 0xB5432B, dark: 0xF6A592)
        /// Coral wash for illustration backgrounds.
        static let coralTint = dynamic(light: 0xFDECE7, dark: 0x3A2420)
        /// Granted, loaded, routed: text and glyphs, always beside a word.
        static let success = dynamic(light: 0x16754A, dark: 0x4DC28A)
        /// Background of a success badge, with success on it.
        static let successTint = dynamic(light: 0xE4F5EC, dark: 0x15302A)
        /// Needs attention but still works: text and glyphs, always beside a word.
        static let warning = dynamic(light: 0x8F5B00, dark: 0xE5B14C)
        /// Background of a warning banner, with warning or text on it.
        static let warningTint = dynamic(light: 0xFBF1DC, dark: 0x33291A)
        /// Failed or refused: text and glyphs, always beside a word.
        static let danger = dynamic(light: 0xBE3128, dark: 0xF38176)
        /// Background of an error banner, with danger or text on it.
        static let dangerTint = dynamic(light: 0xFCE8E6, dark: 0x3A1F21)
        /// Keyboard focus outline, 2px, on every focusable control.
        static let focusRing = dynamic(light: 0x2563EB, dark: 0x7AA3F3)
        /// Sidebar icon tile behind a white symbol, for code and advanced pages. The same in both themes, like System Settings' tiles.
        static let tileInk = dynamic(light: 0x2C3650, dark: 0x2C3650)
        /// Sidebar icon tile behind a white symbol, for general settings. The same in both themes.
        static let tileNeutral = dynamic(light: 0x6B7590, dark: 0x6B7590)
        /// Sidebar icon tile behind a white symbol, for the Agents page. The same in both themes.
        static let tileViolet = dynamic(light: 0x6F4FD8, dark: 0x6F4FD8)
        /// Sidebar icon tile behind a white symbol, for the Sidebar page. The same in both themes.
        static let tileTeal = dynamic(light: 0x0F7C8A, dark: 0x0F7C8A)
    }
    enum Space {
        /// Between a dot and its label; icon to text.
        static let space1: CGFloat = 4
        /// Between words and controls in a rule row; list item gaps.
        static let space2: CGFloat = 8
        /// Between rows in a card; banner padding.
        static let space3: CGFloat = 12
        /// Card padding and the gap between a section title and its card.
        static let space4: CGFloat = 16
        /// Window padding and the gap between sections.
        static let space6: CGFloat = 24
        /// Sheet padding.
        static let space8: CGFloat = 32
    }
    enum Radius {
        /// Text fields, small buttons, key hints.
        static let radiusSm: CGFloat = 6
        /// Rows, banners, menu items.
        static let radiusMd: CGFloat = 10
        /// Section cards and sheets.
        static let radiusLg: CGFloat = 14
        /// Profile chips and status badges.
        static let radiusPill: CGFloat = 999
    }
    enum Size {
        /// Height of every button, field and select.
        static var sizeControl: CGFloat { DS.scaled(28) }
        /// Height of the buttons that finish a sheet (Cancel, Done, Add).
        static var sizeControlLg: CGFloat { DS.scaled(32) }
        /// Height of a sidebar row.
        static var sizeRow: CGFloat { DS.scaled(30) }
        /// Sidebar icon tile: a white symbol on a coloured rounded square.
        static var sizeTile: CGFloat { DS.scaled(20) }
        /// Width of the sidebar column.
        static var sizeSidebar: CGFloat { DS.scaled(224) }
    }
    enum TextStyle {
        /// The window title. Once per window.
        static var title1: Font { Font.system(size: DS.text(28), weight: .semibold, design: .default) }
        static let title1Tracking: CGFloat = -0.4
        /// Sheet titles.
        static var title2: Font { Font.system(size: DS.text(20), weight: .semibold, design: .default) }
        static let title2Tracking: CGFloat = -0.2
        /// Section titles above cards.
        static var headline: Font { Font.system(size: DS.text(13), weight: .semibold, design: .default) }
        /// Everything you read: rows, descriptions, menus. The macOS standard size.
        static var body: Font { Font.system(size: DS.text(13), weight: .regular, design: .default) }
        /// The value in a sentence: a rule's pattern, a profile name.
        static var bodyStrong: Font { Font.system(size: DS.text(13), weight: .medium, design: .default) }
        /// Meta under or beside a value. The smallest readable size.
        static var caption: Font { Font.system(size: DS.text(11), weight: .medium, design: .default) }
        static let captionTracking: CGFloat = 0.1
        /// Links, paths, config.ts errors.
        static var code: Font { Font.system(size: DS.text(12), weight: .regular, design: .monospaced) }
    }
    enum Shadow {
        /// Section cards: barely there, so the page stays airy.
        static let shadowCard = (light: [Layer(x: 0, y: 1, blur: 2, red: 0.0784, green: 0.1098, blue: 0.2000, alpha: 0.05), Layer(x: 0, y: 6, blur: 20, red: 0.0784, green: 0.1098, blue: 0.2000, alpha: 0.05)], dark: [Layer(x: 0, y: 1, blur: 2, red: 0.0000, green: 0.0000, blue: 0.0000, alpha: 0.35)])
        /// Menus, popovers and sheets.
        static let shadowRaised = (light: [Layer(x: 0, y: 8, blur: 28, red: 0.0784, green: 0.1098, blue: 0.2000, alpha: 0.14)], dark: [Layer(x: 0, y: 8, blur: 28, red: 0.0000, green: 0.0000, blue: 0.0000, alpha: 0.5)])
        struct Layer { let x, y, blur, red, green, blue, alpha: CGFloat }
    }
}

private func dynamic(light: UInt32, dark: UInt32) -> Color {
    func ns(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
    return Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? ns(dark) : ns(light)
    })
}
