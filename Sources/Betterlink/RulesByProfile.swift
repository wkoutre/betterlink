import BetterlinkCore
import SwiftUI

// Link Rules, one profile at a time. The rules are still one list checked
// top to bottom, so a profile's page keeps each rule's number in that list
// and says where a rule for another profile decides first.

/// "● Brave Work   ⚠ 1 hidden   12 rules  ›", a row that opens the profile's rules.
struct ProfileRulesRow: View {
    let group: RuleGroups.Group
    /// How many of the profile's rules another profile's rule hides.
    let hidden: Int
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: DS.Space.space2) {
                ProfileLabel(ref: group.target)
                Spacer(minLength: DS.Space.space2)
                if hidden > 0 {
                    Label("\(hidden) hidden", systemImage: "exclamationmark.triangle.fill")
                        .font(DS.TextStyle.caption)
                        .foregroundStyle(DS.Palette.warning)
                        .help("A rule for another profile, checked first, takes the links \(hidden == 1 ? "one of these rules is" : "\(hidden) of these rules are") written for.")
                }
                Text(group.positions.count == 1 ? "1 rule" : "\(group.positions.count) rules")
                    .monospacedDigit()
                    .foregroundStyle(DS.Palette.textSecondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.Palette.textTertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows this profile's rules")
    }
}

/// "+ Add Rules for…": the profiles that have no rules yet.
struct AddRulesMenu: View {
    @EnvironmentObject var model: AppModel
    let without: Set<ProfileRef>
    let add: (ProfileRef) -> Void

    var body: some View {
        let choices = model.catalog.profiles.filter { !without.contains($0.ref) }
        DSSelect(accessibility: "Add rules for a profile") {
            ForEach(groupedProfiles(choices), id: \.browser) { group in
                Section(model.browserName(group.browser)) {
                    ForEach(group.profiles) { p in
                        Button { add(p.ref) } label: {
                            Label { Text(p.name) } icon: { Image(nsImage: dotImage(p.swiftUIColor)) }
                        }
                    }
                }
            }
        } label: {
            Label("Add Rules for…", systemImage: "plus")
        }
        .fixedSize()
        .disabled(choices.isEmpty)
        .help(choices.isEmpty ? "Every profile has rules. Open one to add more." : "Start rules for a profile that has none yet.")
    }
}

/// A page title with a way back to the profile list (⌘[).
struct BackHeader<Leading: View>: View {
    let title: String
    let back: () -> Void
    @ViewBuilder var leading: Leading

    var body: some View {
        HStack(spacing: DS.Space.space2) {
            Button(action: back) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Palette.accentText)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("[", modifiers: .command)
            .help("Back to Link Rules (⌘[)")
            .accessibilityLabel("Back to Link Rules")
            leading
            Text(title).font(DS.TextStyle.title2).tracking(DS.TextStyle.title2Tracking)
                .foregroundStyle(DS.Palette.text)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
        }
        .padding(.leading, -DS.Space.space1)
    }
}

extension BackHeader where Leading == EmptyView {
    init(title: String, back: @escaping () -> Void) {
        self.init(title: title, back: back) { EmptyView() }
    }
}

/// One profile's rules, each with its number in the full order and a note
/// where a rule for another profile shares its links.
struct ProfileRulesDetail: View {
    @EnvironmentObject var model: AppModel
    let target: ProfileRef
    let back: () -> Void
    let edit: () -> Void
    let showAll: () -> Void

    var body: some View {
        let rules = model.rules
        let crossings = RuleGroups.crossings(rules)
        let mine = rules.indices.filter { rules[$0].target == target }
        let profile = model.catalog.profile(target)
        let name = profile?.name ?? target.directory
        VStack(alignment: .leading, spacing: DS.Space.space6) {
            VStack(alignment: .leading, spacing: 4) {
                BackHeader(title: name, back: back) {
                    ProfileDot(color: profile?.swiftUIColor ?? DS.Palette.textPlaceholder)
                }
                Text("Links that match one of these rules open in \(model.browserName(target.browser)) \(name). Each number is the rule's place in the full order: a rule for another profile with a lower number is checked first.")
                    .foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, DS.Space.space2)
            DSSection {
                ForEach(mine, id: \.self) { i in
                    ProfileRuleRow(index: i, rules: rules,
                                   crossings: crossings.filter { $0.earlier == i || $0.later == i })
                }
            } footer: {
                HStack {
                    Button("All Rules in Order", action: showAll).buttonStyle(.dsSecondary)
                    Spacer()
                    Button("Edit Rules…", action: edit)
                        .buttonStyle(.dsPrimary)
                        .disabled(model.rulesError != nil)
                        .keyboardShortcut("e", modifiers: .command)
                }
            }
        }
    }
}

/// "3  Open domains matching app.example.com", then a line for each rule
/// of another profile that can take the same links.
private struct ProfileRuleRow: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var sync = SyncController.shared
    let index: Int
    let rules: [Rule]
    let crossings: [RuleGroups.Crossing]

    var body: some View {
        let rule = rules[index]
        VStack(alignment: .leading, spacing: DS.Space.space2) {
            HStack(spacing: DS.Space.space2) {
                RuleNumber(number: index + 1, count: rules.count)
                Text("Open \(rule.kind.label)").foregroundStyle(DS.Palette.textSecondary)
                Text(rule.pattern).font(DS.TextStyle.bodyStrong).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            // A synced rule whose profile this Mac lacks (docs/sync.md, Rules on another Mac).
            if sync.unresolvedRules.contains(rule.id) {
                Text("This profile isn't on this Mac; links open in the fallback.")
                    .font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
                    .padding(.leading, DS.Space.space6)
            }
            ForEach(crossings, id: \.self) { x in
                note(x, rule: rule)
                    // Under the sentence, past the number column.
                    .padding(.leading, DS.Space.space6)
            }
        }
    }

    @ViewBuilder private func note(_ x: RuleGroups.Crossing, rule: Rule) -> some View {
        let isLater = x.later == index
        let other = isLater ? x.earlier : x.later
        let them = Text("rule \(other + 1) for \(profileText(rules[other].target))")
        let link = Text(Self.short(x.example)).font(DS.TextStyle.code)
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.space2) {
            switch (isLater, x.hidesLater) {
            case (true, true):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.Palette.warning)
                Text("Hidden: \(them) is checked first and opens \(link) there.")
                    .foregroundStyle(DS.Palette.text)
                Spacer(minLength: DS.Space.space2)
                Button("Move Above Rule \(other + 1)") { model.moveRule(rule.id, above: rules[other].id) }
                    .buttonStyle(.dsSecondary)
                    .disabled(model.rulesError != nil)
            case (true, false):
                Image(systemName: "arrow.turn.left.up").foregroundStyle(DS.Palette.textTertiary)
                Text("Except what \(them) takes first, such as \(link).")
                    .foregroundStyle(DS.Palette.textSecondary)
            case (false, true):
                Image(systemName: "arrow.turn.right.down").foregroundStyle(DS.Palette.textTertiary)
                Text("Checked before \(them), so it also takes \(link).")
                    .foregroundStyle(DS.Palette.textSecondary)
            case (false, false):
                Image(systemName: "arrow.turn.right.down").foregroundStyle(DS.Palette.textTertiary)
                Text("Keep it above \(them), which matches \(link) too.")
                    .foregroundStyle(DS.Palette.textSecondary)
            }
        }
        .font(DS.TextStyle.caption)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// "● Personal" with the profile's colour.
    private func profileText(_ ref: ProfileRef) -> Text {
        let p = model.catalog.profile(ref)
        return Text("\(Text("●").foregroundStyle(p?.swiftUIColor ?? DS.Palette.textPlaceholder)) \(Text(p?.name ?? ref.directory).fontWeight(.semibold))")
    }

    /// "https://app.example.com/" -> "app.example.com".
    static func short(_ href: String) -> String {
        var s = href
        if s.hasPrefix("https://") { s.removeFirst(8) }
        if s.hasSuffix("/"), s.firstIndex(of: "/") == s.index(before: s.endIndex) { s.removeLast() }
        return s
    }
}
