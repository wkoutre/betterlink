import BetterlinkCore
import SwiftUI

/// A saved link's or a tab's icon: the first of `icons` that is an inline image (the one
/// it was saved with, its open tab's), else the first letter of its name. An
/// imported link has no icon until its page has been open once, and a grid of
/// identical globes says nothing.
struct SavedIcon: View {
    let icons: [String?]
    let title: String
    @Environment(\.sidebarColors) private var pal

    private var shown: String? {
        for case let icon? in icons where Favicon.inlineImage(icon) != nil { return icon }
        return nil
    }

    var body: some View {
        if let shown {
            Favicon(url: shown)
        } else {
            Text(Self.letter(title))
                .font(DS.TextStyle.caption)
                .foregroundStyle(pal.textSecondary)
                .frame(width: DS.scaled(16), height: DS.scaled(16))
                .background(RoundedRectangle(cornerRadius: DS.Space.space1, style: .continuous).fill(pal.hover))
                .accessibilityHidden(true)
        }
    }

    /// The first letter or digit of a name, skipping "www." and a scheme when
    /// the name is an address.
    static func letter(_ title: String) -> String {
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://", "www."] where t.lowercased().hasPrefix(prefix) { t = String(t.dropFirst(prefix.count)) }
        guard let c = t.first(where: { $0.isLetter || $0.isNumber }) else { return "•" }
        return String(c).uppercased()
    }
}
