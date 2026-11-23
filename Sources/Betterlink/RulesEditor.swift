import BetterlinkCore
import SwiftUI

/// The Link Rules sheet, modelled on Dia's: one row per rule,
/// "Open [domains matching ▾] [example.com] in ● Profile ▾ ✕", then Add Rule,
/// Cancel (esc) and Done (return). Rules are checked top to bottom; drag a
/// row to reorder.
struct RulesEditor: View {
    @EnvironmentObject var model: AppModel
    @State private var rules: [Rule]
    /// The rules as the sheet opened, so Done saves only this sheet's changes.
    private let initial: [Rule]
    let dismiss: () -> Void

    init(initial: [Rule], dismiss: @escaping () -> Void) {
        _rules = State(initialValue: initial)
        self.initial = initial
        self.dismiss = dismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.space4) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Link Rules").font(DS.TextStyle.title2).tracking(DS.TextStyle.title2Tracking)
                Text("The first rule that matches wins. Drag a rule to change the order.")
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            List {
                if rules.isEmpty {
                    Text("No rules. Every link opens in \(model.fallbackProfile?.name ?? model.browserName(model.fallback.browser)).")
                        .foregroundStyle(DS.Palette.textSecondary)
                        .padding(.vertical, DS.Space.space2)
                        .listRowBackground(DS.Palette.panel)
                }
                ForEach($rules) { $rule in
                    RuleRow(rule: $rule) { rules.removeAll { $0.id == rule.id } }
                        .listRowSeparatorTint(DS.Palette.borderSubtle)
                        .listRowBackground(DS.Palette.panel)
                }
                .onMove { rules.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(DS.Palette.panel)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.radiusLg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.radiusLg, style: .continuous)
                .strokeBorder(DS.Palette.borderSubtle, lineWidth: 1))
            .cardShadow()

            HStack {
                Button { addRule() } label: { Label("Add Rule", systemImage: "plus") }
                    .buttonStyle(.dsSecondaryLarge)
                    .keyboardShortcut("n", modifiers: .command)
                Spacer()
                Button { dismiss() } label: { HStack { Text("Cancel"); KeyHint("esc") } }
                    .buttonStyle(.dsSecondaryLarge)
                    .keyboardShortcut(.cancelAction)
                Button { save() } label: { HStack { Text("Done"); Image(systemName: "return") } }
                    .buttonStyle(.dsPrimaryLarge)
                    .keyboardShortcut(.defaultAction)
                    .disabled(rules.contains { $0.problem != nil })
            }
        }
        .padding(DS.Space.space8)
        .frame(width: 800, height: 480)
        .background(DS.Palette.canvas)
        .toggleStyle(.ds)
    }

    private func addRule() {
        let target = model.catalog.profiles.first(where: { !$0.directory.isEmpty })?.ref ?? model.fallback
        rules.append(Rule(kind: .domain, pattern: "", browser: target.browser, profile: target.directory))
    }

    private func save() {
        model.saveRules(rules.map { r in var r = r; r.pattern = r.pattern.trimmingCharacters(in: .whitespaces); return r },
                        from: initial)
        dismiss()
    }
}

private struct RuleRow: View {
    @EnvironmentObject var model: AppModel
    @Binding var rule: Rule
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.space1) {
            HStack(spacing: DS.Space.space2) {
                Image(systemName: "line.3.horizontal").foregroundStyle(DS.Palette.textPlaceholder)
                    .accessibilityHidden(true)
                Text("Open").foregroundStyle(DS.Palette.textSecondary)
                DSPicker(accessibility: "Match type", selection: $rule.kind, options: Rule.Kind.allCases) { $0.label }
                    .frame(width: 164)
                DSTextField(label: "Pattern", text: $rule.pattern, prompt: placeholder,
                            invalid: !rule.pattern.isEmpty && rule.problem != nil)
                    .frame(minWidth: 150)
                Text("in").foregroundStyle(DS.Palette.textSecondary)
                ProfileMenu(selection: Binding(get: { rule.target },
                                               set: { rule.browser = $0.browser; rule.profile = $0.directory }),
                            width: 236)
                DSIconButton(symbol: "xmark", label: "Remove rule", action: remove)
            }
            if !rule.pattern.isEmpty, let problem = rule.problem {
                Text(problem).font(DS.TextStyle.caption).foregroundStyle(DS.Palette.danger).padding(.leading, 62)
            }
        }
        .padding(.vertical, DS.Space.space1)
    }

    private var placeholder: String {
        switch rule.kind {
        case .contains: "text"
        case .startsWith: "https://app.example.com/billing"
        case .domain: "example.com"
        }
    }
}
