import BetterlinkCore
import SwiftUI

/// Every release of betterlink, newest first, with what it changed. Read from
/// the changelog built into the app (scripts/gen-changelog.py writes it from
/// git history at build time), so it is never out of step with the releases.
struct ChangelogPage: View {
    /// Built in, so read once.
    private static let changelog = Changelog.bundled()
    private var installed: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        PageForm {
            PageHeader(title: "Changelog",
                       subtitle: "What changed in each release of betterlink, newest first. betterlink updates itself, so this is also what reached your Mac.")
            if let log = Self.changelog, !(log.releases.isEmpty && (log.unreleased ?? []).isEmpty) {
                if let unreleased = log.unreleased, !unreleased.isEmpty {
                    ChangelogSection(title: "Not released yet", detail: "In this build only", badge: nil,
                                     changes: unreleased, log: log)
                }
                ForEach(log.releases) { release in
                    ChangelogSection(title: "betterlink \(release.version)",
                                     detail: release.day?.formatted(date: .long, time: .omitted) ?? release.date,
                                     badge: release.version == installed ? "This Version" : nil,
                                     changes: release.changes, log: log)
                }
            } else {
                DSSection {
                    Text("This copy of betterlink was built without its release history, so it has no changelog. Every release lists its changes on GitHub.")
                        .foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// One release: its version and date, then a row per change.
private struct ChangelogSection: View {
    let title: String
    let detail: String
    let badge: String?
    let changes: [Changelog.Change]
    let log: Changelog

    var body: some View {
        DSSection {
            if changes.isEmpty {
                Text("Maintenance: nothing you would notice changed.")
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.space3) {
                    Text(change.text)
                        .foregroundStyle(DS.Palette.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: DS.Space.space2)
                    if let pr = change.pr, let url = log.link(for: change) {
                        Link("#\(pr)", destination: url)
                            .font(DS.TextStyle.caption)
                            .foregroundStyle(DS.Palette.accentText)
                            .help("Open pull request #\(pr) on GitHub")
                    }
                }
            }
        } header: {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.space2) {
                Text(title)
                Text(detail).font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
                if let badge { StatusBadge(text: badge, kind: .success) }
            }
        }
    }
}
