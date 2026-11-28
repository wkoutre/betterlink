import BetterlinkCore
import SwiftUI

/// Edits betterlink's copy of the browsers' profile lists: for each profile,
/// its browser, the name and color shown in betterlink, and what the browser
/// needs to pick it (a folder for Chromium browsers, a profile name for
/// Firefox ones). With browser data access allowed (Permissions), betterlink
/// fills this in by itself.
struct ProfilesEditor: View {
    @EnvironmentObject var model: AppModel
    @State private var rows: [Row]
    /// The profiles as the sheet opened, so Done saves only this sheet's changes.
    private let initial: [BrowserProfile]
    let dismiss: () -> Void

    struct Row: Identifiable {
        let id = UUID()
        var browser: String
        var name: String
        var directory: String
        var color: Color
        /// The stored color when the row was loaded, kept as is unless the
        /// color is changed, so an untouched profile saves unchanged.
        var storedColor: UInt32?? = nil
        var loadedColor: Color? = nil
    }

    init(initial: [BrowserProfile], dismiss: @escaping () -> Void) {
        _rows = State(initialValue: initial.map {
            Row(browser: $0.browser, name: $0.name, directory: $0.directory, color: $0.swiftUIColor,
                storedColor: .some($0.color), loadedColor: $0.swiftUIColor)
        })
        self.initial = initial
        self.dismiss = dismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.space4) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Profiles").font(DS.TextStyle.title2).tracking(DS.TextStyle.title2Tracking)
                Text("Chromium browsers tell profiles apart by folder (\"Default\", \"Profile 1\"); see chrome://version, "
                     + "the end of Profile Path. Firefox browsers use the profile's name, shown at about:profiles.")
                    .foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                HStack(spacing: DS.Space.space2) {
                    Text("Colour").frame(width: 52, alignment: .leading)
                    Text("Browser").frame(width: DS.scaled(170), alignment: .leading)
                    Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Folder or profile name").frame(width: DS.scaled(150), alignment: .leading)
                    Color.clear.frame(width: DS.scaled(22), height: 1)
                }
                .font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
                .padding(.horizontal, DS.Space.space4).padding(.vertical, DS.Space.space2)
                Rectangle().fill(DS.Palette.borderSubtle).frame(height: 1)
                ScrollView {
                    VStack(spacing: 0) {
                        if rows.isEmpty {
                            Text("No profiles. Add the ones your rules should open links in.")
                                .foregroundStyle(DS.Palette.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(DS.Space.space4)
                        }
                        ForEach($rows) { $row in
                            VStack(alignment: .leading, spacing: DS.Space.space1) {
                                HStack(spacing: DS.Space.space2) {
                                    DSSwatchPicker(color: $row.color).frame(width: 52, alignment: .leading)
                                    DSPicker(accessibility: "Browser", selection: $row.browser,
                                             options: browserChoices(including: row.browser).map(\.bundleId)) {
                                        model.browserName($0)
                                    }
                                    .frame(width: DS.scaled(170))
                                    DSTextField(label: "Name", text: $row.name, prompt: "Work")
                                    DSTextField(label: "Folder or profile name", text: $row.directory,
                                                prompt: family(row) == .firefox ? "default-release" : "Profile 1",
                                                invalid: !row.directory.isEmpty && problem(row) != nil)
                                        .frame(width: DS.scaled(150))
                                        .disabled(family(row) == .plain)
                                    DSIconButton(symbol: "xmark", label: "Remove \(row.name)") {
                                        rows.removeAll { $0.id == row.id }
                                    }
                                }
                                if let problem = problem(row) {
                                    Text(problem).font(DS.TextStyle.caption).foregroundStyle(DS.Palette.danger)
                                        .padding(.leading, 238)
                                }
                            }
                            .padding(.horizontal, DS.Space.space4).padding(.vertical, DS.Space.space2)
                            if row.id != rows.last?.id {
                                Rectangle().fill(DS.Palette.borderSubtle).frame(height: 1).padding(.leading, DS.Space.space4)
                            }
                        }
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: DS.Radius.radiusLg, style: .continuous).fill(DS.Palette.panel))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.radiusLg, style: .continuous)
                .strokeBorder(DS.Palette.borderSubtle, lineWidth: 1))
            .cardShadow()
            HStack {
                Button { addProfile() } label: { Label("Add Profile", systemImage: "plus") }
                    .buttonStyle(.dsSecondaryLarge)
                    .keyboardShortcut("n", modifiers: .command)
                Spacer()
                Button { dismiss() } label: { HStack { Text("Cancel"); KeyHint("esc") } }
                    .buttonStyle(.dsSecondaryLarge)
                    .keyboardShortcut(.cancelAction)
                Button { save() } label: { HStack { Text("Done"); Image(systemName: "return") } }
                    .buttonStyle(.dsPrimaryLarge)
                    .keyboardShortcut(.defaultAction)
                    .disabled(rows.contains { problem($0) != nil })
            }
        }
        .padding(DS.Space.space8)
        .frame(width: DS.scaled(800), height: DS.scaled(480))
        .background(DS.Palette.canvas)
        .font(DS.TextStyle.body)
    }

    private func addProfile() {
        let b = model.browsers.first { $0.family != .plain } ?? Browser.brave
        let used = Set(rows.filter { $0.browser == b.bundleId }.map(\.directory))
        let next = used.contains("Default") ? (1...999).map { "Profile \($0)" }.first { !used.contains($0) } ?? "" : "Default"
        rows.append(Row(browser: b.bundleId, name: "", directory: b.family == .chromium ? next : "", color: Color(hex: profileSwatches[rows.count % profileSwatches.count])))
    }

    /// Installed browsers, plus the row's own browser if it isn't installed.
    private func browserChoices(including current: String) -> [Browser] {
        var list = model.browsers.filter { $0.family != .plain }
        if !list.contains(where: { $0.bundleId == current }), let b = Browser.known(bundleId: current) { list.append(b) }
        return list
    }

    private func family(_ row: Row) -> Browser.Family { Browser.known(bundleId: row.browser)?.family ?? .chromium }

    private func problem(_ row: Row) -> String? {
        let dir = row.directory.trimmingCharacters(in: .whitespaces)
        if row.name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give this profile a name." }
        switch family(row) {
        case .chromium where !BrowserProfile.isValid(directory: dir, family: .chromium):
            return "The folder must be \"Default\" or \"Profile\" and a number."
        case .firefox where !BrowserProfile.isValid(directory: dir, family: .firefox):
            return "Enter the Firefox profile's name. It can't start with \"-\"."
        default: break
        }
        let same = rows.filter { $0.browser == row.browser }
        if same.filter({ $0.directory.trimmingCharacters(in: .whitespaces) == dir }).count > 1 {
            return family(row) == .plain ? "\(model.browserName(row.browser)) is listed twice." : "Two profiles use \(dir)."
        }
        if same.filter({ $0.name == row.name }).count > 1 { return "Two \(model.browserName(row.browser)) profiles are named \(row.name)." }
        return nil
    }

    private func save() {
        model.saveProfiles(rows.map { r in
            let c = NSColor(r.color).usingColorSpace(.sRGB) ?? .gray
            var rgb: UInt32? = (UInt32(c.redComponent * 255) << 16) | (UInt32(c.greenComponent * 255) << 8) | UInt32(c.blueComponent * 255)
            if let stored = r.storedColor, r.color == r.loadedColor { rgb = stored }
            return BrowserProfile(browser: r.browser,
                                  directory: family(r) == .plain ? "" : r.directory.trimmingCharacters(in: .whitespaces),
                                  name: r.name.trimmingCharacters(in: .whitespaces), color: rgb)
        }, from: initial)
        dismiss()
    }
}
