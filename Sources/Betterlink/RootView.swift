import BetterlinkCore
import SwiftUI

/// The window: a sidebar of pages, like System Settings.
struct RootView: View {
    @EnvironmentObject var model: AppModel
    /// The open page, remembered between launches. BETTERLINK_PAGE picks the
    /// first page (a development aid for screenshots).
    @State private var pageRaw = ProcessInfo.processInfo.environment["BETTERLINK_PAGE"]
        ?? UserDefaults.standard.string(forKey: "page") ?? Page.rules.rawValue

    enum Page: String, CaseIterable, Identifiable {
        case rules, profiles, permissions, agents, config, general, log, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .rules: "Link Rules"
            case .profiles: "Profiles"
            case .permissions: "Permissions"
            case .agents: "Agents"
            case .config: "config.ts"
            case .general: "General"
            case .log: "Log"
            case .about: "About"
            }
        }
        /// The tile colour behind the symbol, System Settings style.
        var tile: Color {
            switch self {
            case .rules: DS.Palette.accent
            case .profiles: DS.Palette.coral
            case .permissions: DS.Palette.success
            case .agents: DS.Palette.tileViolet
            case .config: DS.Palette.tileInk
            case .general, .log: DS.Palette.tileNeutral
            case .about: DS.Palette.accentText
            }
        }
        var symbol: String {
            switch self {
            case .rules: "arrow.triangle.branch"
            case .profiles: "person.2.fill"
            case .permissions: "lock.fill"
            case .agents: "terminal.fill"
            case .config: "chevron.left.forwardslash.chevron.right"
            case .general: "gearshape.fill"
            case .log: "list.bullet"
            case .about: "info"
            }
        }
    }

    private var page: Binding<Page?> {
        Binding(get: { Page(rawValue: pageRaw) ?? .rules }, set: {
            pageRaw = ($0 ?? .rules).rawValue
            UserDefaults.standard.set(pageRaw, forKey: "page")
        })
    }

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(selection: page)
                .frame(width: DS.Size.sizeSidebar)
                .background(DS.Palette.sidebar)
            Rectangle().fill(DS.Palette.borderSubtle).frame(width: 1)
            VStack(spacing: 0) {
                if let err = model.launchError {
                    Banner(text: err, style: .error) { withAnimation(.easeOut(duration: 0.15)) { model.clearLaunchError() } }
                        .padding(.horizontal, DS.Space.space8).padding(.top, DS.Space.space8)
                }
                detail(for: page.wrappedValue ?? .rules)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.Palette.canvas)
        }
        .ignoresSafeArea()
        .buttonStyle(.dsSecondary)
        .toggleStyle(.ds)
        .tint(DS.Palette.accent)
        .frame(minWidth: 780, minHeight: 540)
    }

    @ViewBuilder private func detail(for p: Page) -> some View {
        switch p {
        case .rules: RulesPage()
        case .profiles: ProfilesPage()
        case .permissions: PermissionsPage()
        case .agents: AgentsPage()
        case .config: ConfigPage()
        case .general: GeneralPage()
        case .log: LogPage()
        case .about: AboutPage()
        }
    }
}

/// A white SF Symbol on a small coloured rounded square, like System
/// Settings' sidebar: every icon the same size, so the labels line up.
private struct SidebarTile: View {
    let symbol: String
    let color: Color
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: DS.Size.sizeTile, height: DS.Size.sizeTile)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(color.gradient))
            .accessibilityHidden(true)
    }
}

/// The sidebar, drawn from tokens: groups of size-row rows, space-1 apart,
/// space-6 between groups, a caption title space-1 above its rows.
private struct Sidebar: View {
    @EnvironmentObject var model: AppModel
    @Binding var selection: RootView.Page?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.space6) {
                SidebarHeader()
                group(nil, [.rules, .profiles, .permissions, .agents])
                group("Advanced", [.config, .general] + (model.showLog ? [.log] : []))
                group(nil, [.about])
            }
            .padding(.horizontal, DS.Space.space3)
            // Clear the window's traffic lights.
            .padding(.top, 44)
            .padding(.bottom, DS.Space.space4)
        }
        .scrollIndicators(.never)
    }

    private func group(_ title: String?, _ pages: [RootView.Page]) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.space1) {
            if let title {
                Text(title)
                    .font(DS.TextStyle.caption)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .padding(.horizontal, DS.Space.space2)
                    .accessibilityAddTraits(.isHeader)
            }
            ForEach(pages) { p in
                SidebarRow(page: p, selected: selection == p,
                           attention: p == .permissions && model.permissionsNeedAttention) { selection = p }
            }
        }
    }
}

private struct SidebarRow: View {
    let page: RootView.Page
    let selected: Bool
    let attention: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: DS.Space.space2) {
                SidebarTile(symbol: page.symbol, color: page.tile)
                Text(page.title)
                    .font(selected ? DS.TextStyle.bodyStrong : DS.TextStyle.body)
                    .foregroundStyle(DS.Palette.text)
                Spacer(minLength: 0)
                if attention {
                    Circle().fill(DS.Palette.warning).frame(width: 7, height: 7)
                        .accessibilityLabel("Needs attention")
                }
            }
            .padding(.horizontal, DS.Space.space2)
            .frame(height: DS.Size.sizeRow)
            .background(RoundedRectangle(cornerRadius: DS.Radius.radiusSm + 1, style: .continuous)
                .fill(selected ? DS.Palette.selected : hovering ? DS.Palette.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// App icon, name and whether betterlink is the default browser.
private struct SidebarHeader: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: DS.Space.space3) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 36, height: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("betterlink").font(DS.TextStyle.headline)
                HStack(spacing: 4) {
                    Circle().fill(model.isDefaultBrowser ? DS.Palette.success : DS.Palette.warning).frame(width: 6, height: 6)
                    Text(model.isDefaultBrowser ? "Default browser" : "Not default browser")
                }
                .font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.space2)
    }
}
