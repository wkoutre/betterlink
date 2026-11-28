import BetterlinkCore
import SwiftUI

/// The Link Rules sheet, modelled on Dia's: one row per rule,
/// "Open [domains matching ▾] [example.com] in ● Profile ▾ ✕", then Add Rule,
/// Cancel (esc) and Done (return). Rules are checked top to bottom; drag a
/// row to reorder. Given a profile, it edits only that profile's rules:
/// they keep the places they had in the full list, new ones go last.
/// A rule's + adds another profile ("or in ● Brave Primary"), used on a Mac
/// that has none of the ones above it.
struct RulesEditor: View {
    @EnvironmentObject var model: AppModel
    @State private var rules: [Rule]
    /// All the rules as the sheet opened, so Done saves only this sheet's changes.
    private let initial: [Rule]
    /// The profile whose rules this sheet edits; nil edits them all.
    private let profile: ProfileRef?
    /// Which profile's page a rule is on (AppModel.ruleKey), as the sheet opened.
    private let key: RuleGroups.Key
    let dismiss: () -> Void

    init(initial: [Rule], profile: ProfileRef? = nil, addOne: Bool = false, key: @escaping RuleGroups.Key = { $0.target },
         dismiss: @escaping () -> Void) {
        self.key = key
        var shown = profile.map { p in initial.filter { key($0) == p } } ?? initial
        if addOne, let p = profile { shown.append(Rule(kind: .domain, pattern: "", browser: p.browser, profile: p.directory)) }
        _rules = State(initialValue: shown)
        self.initial = initial
        self.profile = profile
        self.dismiss = dismiss
    }

    private var profileName: String? {
        profile.map { model.groupName($0) ?? model.catalog.profile($0)?.name ?? $0.directory }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.space4) {
            VStack(alignment: .leading, spacing: 4) {
                Text(profileName.map { "Rules for \($0)" } ?? "Link Rules")
                    .font(DS.TextStyle.title2).tracking(DS.TextStyle.title2Tracking)
                Text(profile == nil
                     ? "The first rule that matches wins. Drag a rule to change the order."
                     : "Drag to change the order of these rules. Rules for other profiles keep their places, and new rules go last.")
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            List {
                if rules.isEmpty, let profileName {
                    Text("No rules for \(profileName). Add one, or Done removes this profile from Link Rules.")
                        .foregroundStyle(DS.Palette.textSecondary)
                        .padding(.vertical, DS.Space.space2)
                        .listRowBackground(DS.Palette.panel)
                } else if rules.isEmpty {
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
        let target = profile ?? model.catalog.profiles.first(where: { !$0.directory.isEmpty })?.ref ?? model.fallback
        rules.append(Rule(kind: .domain, pattern: "", browser: target.browser, profile: target.directory))
    }

    private func save() {
        let edited = rules.map { r in
            var r = r
            r.pattern = r.pattern.trimmingCharacters(in: .whitespaces)
            r.setTargets(r.targets)   // a profile picked twice keeps its first place
            return r
        }
        model.saveRules(profile.map { RuleGroups.splice(initial, profile: $0, edited: edited, key: key) } ?? edited, from: initial)
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
                DSIconButton(symbol: "plus", label: "Add another profile, for a Mac without this one", destructive: false,
                             action: addBackup)
                    .disabled(nextBackup == nil)
                DSIconButton(symbol: "xmark", label: "Remove rule", action: remove)
            }
            ForEach(rule.backups.indices, id: \.self) { i in
                HStack(spacing: DS.Space.space2) {
                    Spacer(minLength: 0)
                    Text("or in").foregroundStyle(DS.Palette.textSecondary)
                    ProfileMenu(selection: Binding(get: { rule.backup(i) },
                                                   set: { if rule.backups.indices.contains(i) { rule.backups[i] = $0 } }),
                                width: 236)
                    DSIconButton(symbol: "xmark", label: "Remove this profile from the rule") {
                        if rule.backups.indices.contains(i) { rule.backups.remove(at: i) }
                    }
                    Color.clear.frame(width: 22, height: 22).accessibilityHidden(true)
                }
            }
            if !rule.backups.isEmpty {
                Text("Opens in the first of these profiles the Mac has, so one rule works on Macs with different browsers.")
                    .font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 22 + DS.Space.space2)
            }
            if !rule.pattern.isEmpty, let problem = rule.problem {
                Text(problem).font(DS.TextStyle.caption).foregroundStyle(DS.Palette.danger).padding(.leading, 62)
            }
            UnresolvedRuleNote(rule: rule.id, leading: 62)
        }
        .padding(.vertical, DS.Space.space1)
    }

    /// The profile + adds: one the rule doesn't name yet, from another
    /// browser than the rule's first choice when there is one.
    private var nextBackup: ProfileRef? {
        let named = Set(rule.targets)
        let free = model.catalog.profiles.map(\.ref).filter { !named.contains($0) }
        return free.first { $0.browser != rule.browser } ?? free.first
    }

    private func addBackup() {
        if let next = nextBackup { rule.backups.append(next) }
    }

    private var placeholder: String {
        switch rule.kind {
        case .contains: "text"
        case .startsWith: "https://app.example.com/billing"
        case .domain: "example.com"
        }
    }
}

private extension Rule {
    /// Backup `i`, or the first choice while a removed row is still on screen.
    func backup(_ i: Int) -> ProfileRef { backups.indices.contains(i) ? backups[i] : target }
}
