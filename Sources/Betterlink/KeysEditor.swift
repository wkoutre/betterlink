import BetterlinkCore
import SwiftUI

/// Four keys, ⌃ ⌥ ⇧ ⌘, each on or off. Used by the Modifier Keys editor and
/// the link tester.
struct KeyChips: View {
    @Binding var keys: ModifierKeys
    var body: some View {
        HStack(spacing: DS.Space.space1) {
            ForEach(ModifierKeys.ordered, id: \.name) { k in
                let on = keys.contains(k.key)
                Button {
                    if on { keys.remove(k.key) } else { keys.insert(k.key) }
                } label: {
                    Text(k.symbol).font(.system(size: 13, weight: .semibold)).frame(minWidth: 16)
                }
                .buttonStyle(DSButtonStyle(kind: on ? .primary : .secondary))
                .help(k.label)
                .accessibilityLabel(k.label)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// The Modifier Keys sheet: one row per combination,
/// "Hold [⌃][⌥][⇧][⌘] to open links in ● Profile ▾ ✕", then Add, Cancel and
/// Done, like the Link Rules sheet.
struct KeysEditor: View {
    @EnvironmentObject var model: AppModel
    @State private var rules: [ModifierRule]
    /// The keys as the sheet opened, so Done saves only this sheet's changes.
    private let initial: [ModifierRule]
    let dismiss: () -> Void

    init(initial: [ModifierRule], dismiss: @escaping () -> Void) {
        _rules = State(initialValue: initial)
        self.initial = initial
        self.dismiss = dismiss
    }

    var body: some View {
        let problems = ModifierRule.problems(in: rules)
        VStack(alignment: .leading, spacing: DS.Space.space4) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Modifier Keys").font(DS.TextStyle.title2).tracking(DS.TextStyle.title2Tracking)
                Text("Hold these keys while you click a link to open it in a profile. They win over config.ts and Link Rules. The keys must match exactly: ⌃⌘ doesn't match ⌃⌥⌘.")
                    .foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            List {
                if rules.isEmpty {
                    Text("No modifier keys. Links open by your Link Rules whatever keys you hold.")
                        .foregroundStyle(DS.Palette.textSecondary)
                        .padding(.vertical, DS.Space.space2)
                        .listRowBackground(DS.Palette.panel)
                }
                ForEach($rules) { $rule in
                    let i = rules.firstIndex { $0.id == rule.id }
                    KeysRow(rule: $rule, problem: i.flatMap { problems[$0] }) { rules.removeAll { $0.id == rule.id } }
                        .listRowSeparatorTint(DS.Palette.borderSubtle)
                        .listRowBackground(DS.Palette.panel)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(DS.Palette.panel)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.radiusLg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.radiusLg, style: .continuous)
                .strokeBorder(DS.Palette.borderSubtle, lineWidth: 1))
            .cardShadow()

            HStack {
                Button { add() } label: { Label("Add Keys", systemImage: "plus") }
                    .buttonStyle(.dsSecondaryLarge)
                    .keyboardShortcut("n", modifiers: .command)
                Spacer()
                Button { dismiss() } label: { HStack { Text("Cancel"); KeyHint("esc") } }
                    .buttonStyle(.dsSecondaryLarge)
                    .keyboardShortcut(.cancelAction)
                Button { model.saveModifierRules(rules, from: initial); dismiss() } label: { HStack { Text("Done"); Image(systemName: "return") } }
                    .buttonStyle(.dsPrimaryLarge)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!problems.isEmpty)
            }
        }
        .padding(DS.Space.space8)
        .frame(width: 720, height: 420)
        .background(DS.Palette.canvas)
    }

    /// A new row starts as ⌃⌘, or the first combination not yet used.
    private func add() {
        let target = model.catalog.profiles.first(where: { !$0.directory.isEmpty })?.ref ?? model.fallback
        let used = Set(rules.map(\.keys))
        let candidates: [ModifierKeys] = [[.control, .command], [.option, .command], [.control, .option],
                                          [.control, .option, .command], [.shift, .command]]
        let keys = candidates.first { !used.contains($0) } ?? []
        rules.append(ModifierRule(keys: keys, browser: target.browser, profile: target.directory))
    }
}

private struct KeysRow: View {
    @Binding var rule: ModifierRule
    let problem: String?
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.space1) {
            HStack(spacing: DS.Space.space2) {
                Text("Hold").foregroundStyle(DS.Palette.textSecondary)
                KeyChips(keys: $rule.keys)
                Text("to open links in").foregroundStyle(DS.Palette.textSecondary)
                ProfileMenu(selection: Binding(get: { rule.target },
                                               set: { rule.browser = $0.browser; rule.profile = $0.directory }),
                            width: 236)
                Spacer(minLength: 0)
                DSIconButton(symbol: "xmark", label: "Remove", action: remove)
            }
            if let problem {
                Text(problem).font(DS.TextStyle.caption).foregroundStyle(DS.Palette.danger).padding(.leading, 40)
            }
        }
        .padding(.vertical, DS.Space.space1)
    }
}
