import AppKit
import BetterlinkCore
import SwiftUI

// The design system's components (Design/tokens.json; the "betterlink"
// Design System artifact): ProfileChip, StatusBadge, Banner, KeyHint.

extension BrowserProfile {
    var swiftUIColor: Color {
        guard let c = color else { return DS.Palette.textPlaceholder }
        return Color(red: Double((c >> 16) & 0xFF) / 255, green: Double((c >> 8) & 0xFF) / 255, blue: Double(c & 0xFF) / 255)
    }
}

/// Profiles grouped by browser, in the catalog's order.
func groupedProfiles(_ profiles: [BrowserProfile]) -> [(browser: String, profiles: [BrowserProfile])] {
    var order: [String] = []
    var groups: [String: [BrowserProfile]] = [:]
    for p in profiles {
        if groups[p.browser] == nil { order.append(p.browser) }
        groups[p.browser, default: []].append(p)
    }
    return order.map { ($0, groups[$0]!) }
}

/// A profile's colour dot: 9pt beside standard text, never an icon.
struct ProfileDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: DS.scaled(9), height: DS.scaled(9))
            .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

/// ● Google Chrome **Work**. The browser name is left out inside its own group.
struct ProfileLabel: View {
    @EnvironmentObject var model: AppModel
    let ref: ProfileRef
    var showBrowser = true
    var body: some View {
        let p = model.catalog.profile(ref)
        let browser = model.browserName(ref.browser)
        HStack(spacing: DS.Space.space1 + 2) {
            ProfileDot(color: p?.swiftUIColor ?? DS.Palette.textPlaceholder)
            // One Text, so a Menu label shows all of it.
            if let p {
                if showBrowser && !ref.directory.isEmpty {
                    Text("\(Text(browser).foregroundStyle(DS.Palette.textSecondary)) \(Text(p.name).fontWeight(.medium))")
                } else {
                    Text(p.name).fontWeight(.medium)
                }
            } else if ref.directory == "Default" || ref.directory.isEmpty {
                // A browser's own default profile, before betterlink knows its name.
                Text("\(Text(browser).fontWeight(.medium)) \(Text("default profile").foregroundStyle(DS.Palette.textSecondary))")
            } else {
                Text("\(browser) \(ref.directory) (missing)").foregroundStyle(DS.Palette.textTertiary)
            }
        }
        .lineLimit(1)
    }
}

/// Profile picker grouped by browser, with each profile's colour.
struct ProfileMenu: View {
    @EnvironmentObject var model: AppModel
    @Binding var selection: ProfileRef
    /// A fixed width keeps rows of menus aligned; nil sizes to the label.
    var width: CGFloat?
    var body: some View {
        DSSelect(accessibility: "Profile: \(model.catalog.profile(selection)?.name ?? selection.directory)") {
            ForEach(groupedProfiles(model.catalog.profiles), id: \.browser) { group in
                Section(model.browserName(group.browser)) {
                    ForEach(group.profiles) { p in
                        Button { selection = p.ref } label: {
                            Label { Text(p.name) } icon: { Image(nsImage: dotImage(p.swiftUIColor)) }
                        }
                    }
                }
            }
        } label: {
            ProfileLabel(ref: selection)
        }
        .frame(width: width)
        .fixedSize(horizontal: width == nil, vertical: false)
    }
}

func dotImage(_ color: Color) -> NSImage {
    let img = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { r in
        NSColor(color).setFill()
        NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
        return true
    }
    img.isTemplate = false
    return img
}

/// A state as a word and a colour, never colour alone.
struct StatusBadge: View {
    enum Kind { case success, warning, danger, neutral }
    let text: String
    let kind: Kind
    var symbol: String?

    var body: some View {
        let (fg, bg): (Color, Color) = switch kind {
        case .success: (DS.Palette.success, DS.Palette.successTint)
        case .warning: (DS.Palette.warning, DS.Palette.warningTint)
        case .danger: (DS.Palette.danger, DS.Palette.dangerTint)
        case .neutral: (DS.Palette.textTertiary, DS.Palette.hover)
        }
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text)
        }
        .font(DS.TextStyle.caption.weight(.semibold))
        .foregroundStyle(fg)
        .padding(.horizontal, DS.Space.space2)
        .padding(.vertical, 3)
        .background(Capsule().fill(bg))
        .fixedSize()
    }
}

/// A message to read before anything else: an error or a setting that needs attention.
struct Banner: View {
    enum Style { case error, warning, info }
    let text: String
    let style: Style
    var onClose: (() -> Void)?

    var body: some View {
        let (glyph, tint, fill): (String, Color, Color) = switch style {
        case .error: ("xmark.octagon.fill", DS.Palette.danger, DS.Palette.dangerTint)
        case .warning: ("exclamationmark.triangle.fill", DS.Palette.warning, DS.Palette.warningTint)
        case .info: ("info.circle.fill", DS.Palette.accentText, DS.Palette.accentTint)
        }
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.space2) {
            Image(systemName: glyph).foregroundStyle(tint)
            Text(text).foregroundStyle(DS.Palette.text).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let onClose {
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: DS.text(10), weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(DS.Palette.textSecondary)
                    .accessibilityLabel("Dismiss")
            }
        }
        .padding(DS.Space.space3)
        .background(RoundedRectangle(cornerRadius: DS.Radius.radiusMd, style: .continuous).fill(fill))
        .transition(.opacity)
    }
}

struct KeyHint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: DS.text(10), weight: .semibold)).padding(.horizontal, 4).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.5)))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }
}

/// A page's title and one line saying what the page is for, on the canvas
/// (not in a card), like System Settings' page headers.
struct PageHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(DS.TextStyle.title2).tracking(DS.TextStyle.title2Tracking)
            Text(subtitle).font(DS.TextStyle.body).foregroundStyle(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(DS.Palette.text)
        .textCase(nil)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, DS.Space.space2)
        .accessibilityAddTraits(.isHeader)
    }
}
