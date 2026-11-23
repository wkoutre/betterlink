import AppKit
import SwiftUI

// betterlink's controls, drawn from the design system (Design/tokens.json)
// rather than the system's: Button, TextField, Select, Toggle, Swatch picker.
// Every state (rest, hover, pressed, focused, disabled) comes from tokens.

// MARK: Button

struct DSButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, destructive }
    enum Size { case regular, large }
    var kind: Kind = .secondary
    var size: Size = .regular

    func makeBody(configuration: Configuration) -> some View {
        DSButtonBody(configuration: configuration, kind: kind, size: size)
    }
}

private struct DSButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: DSButtonStyle.Kind
    let size: DSButtonStyle.Size
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(size == .large ? DS.TextStyle.bodyStrong : DS.TextStyle.bodyStrong)
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, size == .large ? 14 : 10)
            .frame(height: size == .large ? 30 : 26)
            .background(RoundedRectangle(cornerRadius: DS.Radius.radiusSm + 1, style: .continuous).fill(fill(pressed: pressed)))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.radiusSm + 1, style: .continuous)
                .strokeBorder(border, lineWidth: kind == .secondary ? 1 : 0))
            .shadow(color: kind == .primary && enabled ? DS.Palette.accent.opacity(0.25) : .clear, radius: 3, y: 1)
            .scaleEffect(pressed ? 0.98 : 1)
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.08), value: pressed)
    }

    private var foreground: Color {
        switch kind {
        case .primary: DS.Palette.onAccent
        case .secondary: DS.Palette.text
        case .ghost: DS.Palette.accentText
        case .destructive: DS.Palette.danger
        }
    }

    private func fill(pressed: Bool) -> Color {
        let active = enabled && (hovering || pressed)
        switch kind {
        case .primary: return active ? DS.Palette.accentHover : DS.Palette.accent
        case .secondary: return active ? DS.Palette.hover : DS.Palette.panel
        case .ghost: return active ? DS.Palette.accentTint : .clear
        case .destructive: return active ? DS.Palette.dangerTint : .clear
        }
    }

    private var border: Color { kind == .secondary ? DS.Palette.border : .clear }
}

extension ButtonStyle where Self == DSButtonStyle {
    static var dsPrimary: DSButtonStyle { DSButtonStyle(kind: .primary) }
    static var dsSecondary: DSButtonStyle { DSButtonStyle(kind: .secondary) }
    static var dsGhost: DSButtonStyle { DSButtonStyle(kind: .ghost) }
    static var dsDestructive: DSButtonStyle { DSButtonStyle(kind: .destructive) }
    static var dsPrimaryLarge: DSButtonStyle { DSButtonStyle(kind: .primary, size: .large) }
    static var dsSecondaryLarge: DSButtonStyle { DSButtonStyle(kind: .secondary, size: .large) }
}

/// A round icon-only button (remove a row): ghost until hovered.
struct DSIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(hovering ? DS.Palette.danger : DS.Palette.textTertiary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(hovering ? DS.Palette.dangerTint : DS.Palette.hover))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: Field chrome (shared by TextField and Select)

private struct FieldChrome: ViewModifier {
    var focused: Bool
    var invalid: Bool = false
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: DS.Radius.radiusSm, style: .continuous).fill(DS.Palette.canvas))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.radiusSm, style: .continuous)
                .strokeBorder(invalid ? DS.Palette.danger : focused ? DS.Palette.focusRing
                              : hovering ? DS.Palette.textPlaceholder : DS.Palette.border,
                              lineWidth: focused || invalid ? 1.5 : 1))
            .background(RoundedRectangle(cornerRadius: DS.Radius.radiusSm + 3, style: .continuous)
                .fill(DS.Palette.focusRing.opacity(focused ? 0.18 : 0)).padding(-3))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: focused)
    }
}

// MARK: TextField

struct DSTextField: View {
    let label: String
    @Binding var text: String
    var prompt: String = ""
    var monospaced = false
    var invalid = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField(label, text: $text, prompt: Text(prompt).font(DS.TextStyle.body).foregroundStyle(DS.Palette.textPlaceholder))
            .textFieldStyle(.plain)
            .labelsHidden()
            // The placeholder is a sentence in the body face; what the user
            // types (a link, a path) is code. A field's font also sets its
            // placeholder's, so switch only once there is text.
            .font(monospaced && !text.isEmpty ? DS.TextStyle.code : DS.TextStyle.body)
            .foregroundStyle(DS.Palette.text)
            .focused($focused)
            .modifier(FieldChrome(focused: focused, invalid: invalid))
            .accessibilityLabel(label)
    }
}

// MARK: Select

/// A pop-up choice drawn as a field with a chevron. The menu itself is the
/// system's (it floats above every window), the control is ours.
struct DSSelect<Label: View, Content: View>: View {
    let accessibility: String
    @ViewBuilder let content: Content
    @ViewBuilder let label: Label
    var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: DS.Space.space2) {
                label.lineLimit(1).foregroundStyle(DS.Palette.text)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DS.Palette.textTertiary)
            }
            .modifier(FieldChrome(focused: false))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel(accessibility)
    }
}

/// A Select over an enum-like set of values.
struct DSPicker<Value: Hashable>: View {
    let accessibility: String
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String
    var body: some View {
        DSSelect(accessibility: accessibility) {
            ForEach(options, id: \.self) { v in
                Button { selection = v } label: {
                    if v == selection { Label(title(v), systemImage: "checkmark") } else { Text(title(v)) }
                }
            }
        } label: {
            Text(title(selection)).font(DS.TextStyle.body)
        }
    }
}

// MARK: Toggle

struct DSToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { DSToggleBody(configuration: configuration) }
}

private struct DSToggleBody: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.labelsVisibility) private var labelsVisibility
    var body: some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: DS.Space.space3) {
                if labelsVisibility != .hidden {
                    configuration.label
                    Spacer(minLength: 0)
                }
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? DS.Palette.accent : DS.Palette.border)
                        .frame(width: 34, height: 20)
                    Circle().fill(.white).frame(width: 16, height: 16).padding(2)
                        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                }
                .animation(.spring(response: 0.25, dampingFraction: 0.85), value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

extension ToggleStyle where Self == DSToggleStyle {
    static var ds: DSToggleStyle { DSToggleStyle() }
}

// MARK: Swatch picker

/// The profile colours the design system offers. A profile's colour is
/// otherwise the one its browser records.
let profileSwatches: [UInt32] = [0x5B8DEF, 0xF0735A, 0x4DC28A, 0xE5B14C, 0xA77BEB, 0x3FB8C4, 0xE86FA6, 0x8A94AB]

struct DSSwatchPicker: View {
    @Binding var color: Color
    var body: some View {
        DSSelect(accessibility: "Colour") {
            ForEach(profileSwatches, id: \.self) { hex in
                Button { color = Color(hex: hex) } label: {
                    Label { Text(swatchName(hex)) } icon: { Image(nsImage: dotImage(Color(hex: hex))) }
                }
            }
        } label: {
            ProfileDot(color: color).scaleEffect(1.3)
        }
        .frame(width: 52)
    }

    private func swatchName(_ hex: UInt32) -> String {
        ["Blue", "Coral", "Green", "Amber", "Violet", "Teal", "Pink", "Grey"][profileSwatches.firstIndex(of: hex) ?? 0]
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}
