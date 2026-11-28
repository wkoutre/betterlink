import BetterlinkCore
import SwiftUI

/// The window: a column of pages, like System Settings.
struct RootView: View {
    @EnvironmentObject var model: AppModel
    /// The open page, remembered between launches. BETTERLINK_PAGE picks the
    /// first page (a development aid for screenshots).
    @State private var pageRaw = ProcessInfo.processInfo.environment["BETTERLINK_PAGE"]
        ?? MenuBarIcon.defaults().string(forKey: "page") ?? Page.rules.rawValue

    /// In the order the navigation column lists them (NavColumn has the groups).
    enum Page: String, CaseIterable, Identifiable {
        case rules, profiles
        /// The sidebar beside the browser. Saved as "tabs", its page's first name.
        case sidebar = "tabs"
        /// Sharing settings between Macs, and the settings folder (SyncPage).
        case sync
        case general, permissions
        case config, agents, log
        /// Every release and what it changed (ChangelogPage).
        case changelog
        case about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .rules: "Link Rules"
            case .profiles: "Profiles"
            case .permissions: "Permissions"
            case .agents: "Agents"
            case .sidebar: "Sidebar"
            case .sync: "Sync"
            case .config: "config.ts"
            case .general: "General"
            case .log: "Log"
            case .changelog: "Changelog"
            case .about: "About"
            }
        }
        /// The tile colour behind the symbol, System Settings style.
        var tile: Color {
            switch self {
            case .rules, .sync: DS.Palette.accent
            case .profiles: DS.Palette.coral
            case .permissions: DS.Palette.success
            case .agents: DS.Palette.tileViolet
            case .sidebar: DS.Palette.tileTeal
            case .config: DS.Palette.tileInk
            case .general, .log, .changelog: DS.Palette.tileNeutral
            case .about: DS.Palette.accentText
            }
        }
        var symbol: String {
            switch self {
            case .rules: "arrow.triangle.branch"
            case .profiles: "person.2.fill"
            case .permissions: "lock.fill"
            case .agents: "terminal.fill"
            case .sidebar: "sidebar.left"
            case .sync: "arrow.triangle.2.circlepath"
            case .config: "chevron.left.forwardslash.chevron.right"
            case .general: "gearshape.fill"
            case .log: "list.bullet"
            case .changelog: "clock.arrow.circlepath"
            case .about: "info"
            }
        }
        /// Still a preview: its row carries a badge that says so.
        var isPreview: Bool { self == .sidebar }
    }

    private var page: Binding<Page?> {
        Binding(get: { Page(rawValue: pageRaw) ?? .rules }, set: {
            pageRaw = ($0 ?? .rules).rawValue
            MenuBarIcon.defaults().set(pageRaw, forKey: "page")
        })
    }

    var body: some View {
        HStack(spacing: 0) {
            NavColumn(selection: page)
                .frame(width: DS.Size.sizeSidebar)
                .background(DS.Palette.sidebar)
            Rectangle().fill(DS.Palette.borderSubtle).frame(width: 1)
            VStack(spacing: 0) {
                if let err = model.launchError {
                    Banner(text: err, style: .error) { withAnimation(.easeOut(duration: 0.15)) { model.clearLaunchError() } }
                        .padding(.horizontal, DS.Space.space8).padding(.top, DS.Space.space8)
                }
                // What's New, offered after an update; never a window of its own.
                TourNewsBanner()
                detail(for: page.wrappedValue ?? .rules)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.Palette.canvas)
        }
        // The sidebar's "Sidebar Settings…" opens a page here.
        .onReceive(NotificationCenter.default.publisher(for: .betterlinkOpenPage)) { note in
            if let raw = note.object as? String, Page(rawValue: raw) != nil { page.wrappedValue = Page(rawValue: raw) }
        }
        // The tour (first run, What's New, replay) sits over the pages, which
        // stay as they are underneath.
        .overlay { TourOverlay() }
        .ignoresSafeArea()
        .buttonStyle(.dsSecondary)
        .toggleStyle(.ds)
        .tint(DS.Palette.accent)
        .frame(minWidth: BetterlinkWindow.minSize.width, minHeight: BetterlinkWindow.minSize.height)
    }

    @ViewBuilder private func detail(for p: Page) -> some View {
        switch p {
        case .rules: RulesPage()
        case .profiles: ProfilesPage()
        case .permissions: PermissionsPage()
        case .agents: AgentsPage()
        case .sidebar: SidebarPage()
        case .sync: SyncPage()
        case .config: ConfigPage()
        case .general: GeneralPage()
        case .log: LogPage()
        case .changelog: ChangelogPage()
        case .about: AboutPage()
        }
    }
}

/// A white SF Symbol on a small coloured rounded square, like System
/// Settings' sidebar: every icon the same size, so the labels line up.
private struct NavTile: View {
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

/// The navigation column, drawn from tokens: groups of size-row rows, space-1 apart,
/// space-4 between groups, a caption title space-1 above its rows. Every row,
/// the Log's included, fits the window's minimum height without scrolling.
private struct NavColumn: View {
    @EnvironmentObject var model: AppModel
    @Binding var selection: RootView.Page?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.space4) {
                NavHeader()
                // What betterlink does, then how it runs on this Mac, then
                // the parts for people who write code, then the app itself.
                group(nil, [.rules, .profiles, .sidebar, .sync])
                group(nil, [.general, .permissions])
                group("Advanced", [.config, .agents] + (model.showLog ? [.log] : []))
                group(nil, [.changelog, .about])
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
                NavRow(page: p, selected: selection == p,
                           attention: p == .permissions && model.permissionsNeedAttention) { selection = p }
            }
        }
    }
}

private struct NavRow: View {
    let page: RootView.Page
    let selected: Bool
    let attention: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: DS.Space.space2) {
                NavTile(symbol: page.symbol, color: page.tile)
                Text(page.title)
                    .font(selected ? DS.TextStyle.bodyStrong : DS.TextStyle.body)
                    .foregroundStyle(DS.Palette.text)
                Spacer(minLength: 0)
                if page.isPreview {
                    Text("Preview")
                        .font(DS.TextStyle.caption.weight(.semibold))
                        .foregroundStyle(DS.Palette.textTertiary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().strokeBorder(DS.Palette.borderSubtle, lineWidth: 1))
                }
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
private struct NavHeader: View {
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

/// Opens betterlink's window on a page, from outside it (the sidebar).
@MainActor
enum BetterlinkWindow {
    /// The smallest the window gets. A tour step's words fit it; a step with a
    /// tall control scrolls (TourLayoutTests).
    static let minSize = CGSize(width: 780, height: 540)
    /// The size the window opens at. The tour's steps fit it without scrolling
    /// (TourLayoutTests).
    static let defaultSize = CGSize(width: 880, height: 640)

    static func open(_ page: RootView.Page) {
        MenuBarIcon.defaults().set(page.rawValue, forKey: "page")
        // Someone asked for this page: not the moment for the first-run tour.
        (NSApp.delegate as? AppDelegate)?.showWindow(offerTour: false)
        NotificationCenter.default.post(name: .betterlinkOpenPage, object: page.rawValue)
    }
}
