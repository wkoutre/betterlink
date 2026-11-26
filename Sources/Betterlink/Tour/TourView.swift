import AppKit
import BetterlinkCore
import SwiftUI

// The tour's one look, whichever way it was opened (docs/tour.md): a tile, a
// title, a few sentences, and at most one card to act in. The first run,
// What's New and the replay all draw their steps with TourStepPage.

/// The sizes the tour is laid out to. Every step fits the window as it opens
/// with a control of `controlBudget` under it, and its words alone fit the
/// smallest window (TourLayoutTests); what is taller scrolls.
enum TourLayout {
    static let column: CGFloat = 520
    static let wideColumn: CGFloat = 640
    static let header: CGFloat = 44
    static let footer: CGFloat = 68
    static let controlBudget: CGFloat = 120
    static let tile: CGFloat = 56
}

extension TourTile {
    var color: Color {
        switch self {
        case .accent: DS.Palette.accent
        case .success: DS.Palette.success
        case .coral: DS.Palette.coral
        case .tileInk: DS.Palette.tileInk
        case .tileNeutral: DS.Palette.tileNeutral
        case .tileTeal: DS.Palette.tileTeal
        case .tileViolet: DS.Palette.tileViolet
        }
    }
}

/// A white symbol on a coloured rounded square: the sidebar's page tiles, larger.
struct TourTileView: View {
    let symbol: String
    let tile: TourTile
    var size: CGFloat = TourLayout.tile

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(tile.color.gradient))
            .accessibilityHidden(true)
    }
}

/// Sits over the window's pages while a tour is showing.
struct TourOverlay: View {
    @ObservedObject private var tour = TourModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let session = tour.session {
                TourView(session: session)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: tour.session != nil)
    }
}

struct TourView: View {
    @ObservedObject private var tour = TourModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: TourSession

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                if let entry = session.entry {
                    TourStepPage(entry: entry) { TourControlCard(step: entry.step) }
                        .id(entry.id)
                        .transition(stepTransition)
                } else {
                    TourMoreList(mode: session.plan.mode, topics: session.plan.more, opened: tour.opened) { tour.open(topic: $0) }
                        .id("more")
                        .transition(stepTransition)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .background(DS.Palette.canvas)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: session.place)
    }

    /// A step fades in, sliding a little from the side the person is heading to.
    private var stepTransition: AnyTransition {
        .asymmetric(insertion: .offset(x: tour.movedForward ? 28 : -28).combined(with: .opacity), removal: .opacity)
    }

    private var heading: String {
        if let topic = session.detourTopic { return topic.title }
        switch session.plan.mode {
        case .welcome: return "Welcome to betterlink"
        case .whatsNew: return "What's New in betterlink"
        case .replay: return "The betterlink Tour"
        case .topic: return session.entry?.topic.title ?? "betterlink"
        }
    }

    private var header: some View {
        ZStack {
            Text(heading)
                .font(DS.TextStyle.headline)
                .foregroundStyle(DS.Palette.textTertiary)
                .accessibilityAddTraits(.isHeader)
            HStack {
                Spacer()
                // Skipping is always one click away, and never loses anything:
                // every step stays under About.
                Button(session.plan.mode == .welcome ? "Skip Tour" : "Close") { tour.finish() }
                    .buttonStyle(.dsGhost)
                    .keyboardShortcut(.cancelAction)
                    .help("Every step stays under About, to open again.")
            }
            .padding(.horizontal, DS.Space.space4)
        }
        .frame(height: TourLayout.header)
    }

    private var nextTitle: String {
        if case .detour = session.place, let p = session.progress, p.index == p.count - 1 { return "All Topics" }
        return session.isLast ? "Done" : "Continue"
    }

    private var footer: some View {
        ZStack {
            if let p = session.progress, p.count > 1 {
                HStack(spacing: 6) {
                    ForEach(0..<p.count, id: \.self) { i in
                        Circle()
                            .fill(i == p.index ? DS.Palette.accent : DS.Palette.border)
                            .frame(width: 6, height: 6)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Step \(p.index + 1) of \(p.count)")
            }
            HStack {
                if session.canGoBack {
                    Button("Back") { tour.back() }.buttonStyle(.dsSecondaryLarge)
                }
                Spacer()
                Button(nextTitle) { tour.next() }
                    .buttonStyle(.dsPrimaryLarge)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, DS.Space.space8)
        .frame(height: TourLayout.footer, alignment: .top)
    }
}

/// One step: tile, title, what it is for, then the card to act in and the
/// command that does the same. Centred when it fits, scrolling when a control
/// grows past the window.
struct TourStepPage<Control: View>: View {
    let entry: TourPlan.Entry
    @ViewBuilder let control: Control

    var body: some View {
        ViewThatFits(in: .vertical) {
            TourStepContent(entry: entry) { control }
            ScrollView { TourStepContent(entry: entry) { control } }
        }
    }
}

struct TourStepContent<Control: View>: View {
    let entry: TourPlan.Entry
    @ViewBuilder let control: Control

    var body: some View {
        VStack(spacing: DS.Space.space3) {
            TourTileView(symbol: entry.step.symbol, tile: entry.topic.tile)
                .padding(.bottom, DS.Space.space1)
            if let note = entry.note {
                // Why this step is here again, as a word and a colour.
                switch note {
                case .new: StatusBadge(text: "New", kind: .success)
                case .updated: StatusBadge(text: "Updated", kind: .warning)
                }
            }
            Text(entry.step.title)
                .font(DS.TextStyle.title1).tracking(DS.TextStyle.title1Tracking)
                .foregroundStyle(DS.Palette.text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(entry.step.body)
                .font(DS.TextStyle.body)
                .foregroundStyle(DS.Palette.textSecondary)
                .lineSpacing(4)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if case .updated(let changed?) = entry.note {
                Text(changed)
                    .font(DS.TextStyle.bodyStrong)
                    .foregroundStyle(DS.Palette.text)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            control
                .padding(.top, DS.Space.space2)
            TourCommandHint(step: entry.step)
        }
        .frame(maxWidth: TourLayout.column)
        .padding(.horizontal, DS.Space.space8)
        .padding(.vertical, DS.Space.space2)
        .frame(maxWidth: .infinity)
    }
}

/// The betterlink command that does what the step's control does, to copy;
/// or one line saying why no command can.
struct TourCommandHint: View {
    let step: TourStep
    @State private var copied = false

    var body: some View {
        if let cli = step.cli {
            HStack(spacing: DS.Space.space2) {
                Image(systemName: "terminal").foregroundStyle(DS.Palette.textTertiary).accessibilityHidden(true)
                Text(cli)
                    .font(DS.TextStyle.code)
                    .foregroundStyle(DS.Palette.textTertiary)
                    // A long command shrinks a little before it loses its middle.
                    .lineLimit(1).minimumScaleFactor(0.85).truncationMode(.middle)
                    .textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(cli, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(DS.Palette.textTertiary)
                .help("Copy the command that does the same")
                .accessibilityLabel(copied ? "Copied" : "Copy the command that does the same")
            }
        } else if let why = step.cliWhy, step.control != nil {
            Text("No command for this step. \(why)")
                .font(DS.TextStyle.caption)
                .foregroundStyle(DS.Palette.textTertiary)
                .multilineTextAlignment(.center)
        }
    }
}

/// After the essentials: everything else betterlink does, to open or leave.
struct TourMoreList: View {
    let mode: TourPlan.Mode
    let topics: [TourTopic]
    let opened: Set<String>
    let open: (String) -> Void

    var body: some View {
        VStack(spacing: DS.Space.space3) {
            Text("There is more when you want it")
                .font(DS.TextStyle.title1).tracking(DS.TextStyle.title1Tracking)
                .foregroundStyle(DS.Palette.text)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text("betterlink is routing your links. Open any of these now, or leave them: each stays under About, and nothing here is switched on until you do it.")
                .font(DS.TextStyle.body)
                .foregroundStyle(DS.Palette.textSecondary)
                .lineSpacing(4)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: TourLayout.column)
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: DS.Space.space3), GridItem(.flexible())], spacing: DS.Space.space3) {
                    ForEach(topics) { topic in
                        TourTopicCard(topic: topic, opened: opened.contains(topic.id)) { open(topic.id) }
                    }
                }
                .padding(.vertical, DS.Space.space2)
                .padding(.horizontal, 2)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: TourLayout.wideColumn)
        .padding(.horizontal, DS.Space.space8)
        .padding(.top, DS.Space.space2)
    }
}

private struct TourTopicCard: View {
    let topic: TourTopic
    let opened: Bool
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: DS.Space.space3) {
                TourTileView(symbol: topic.symbol, tile: topic.tile, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(topic.title).font(DS.TextStyle.bodyStrong).foregroundStyle(DS.Palette.text).lineLimit(1)
                    Text(topic.summary).font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
                        // Always two lines tall, so every card in the grid
                        // is the same height whatever its summary's length.
                        .lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: opened ? "checkmark" : "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(opened ? DS.Palette.success : DS.Palette.textTertiary)
                    // One width for both symbols, so a card's words don't
                    // rewrap or cut off once it has been opened.
                    .frame(width: 8)
                    .accessibilityLabel(opened ? "Seen" : "")
            }
            .padding(.horizontal, DS.Space.space3)
            .padding(.vertical, DS.Space.space2)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.Radius.radiusMd, style: .continuous)
                .fill(hovering ? DS.Palette.hover : DS.Palette.panel))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.radiusMd, style: .continuous)
                .strokeBorder(DS.Palette.borderSubtle, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: Ways in

/// What's New, offered at the top of the window after an update: one line
/// that opens the steps or dismisses them. Never a window of its own.
struct TourNewsBanner: View {
    @ObservedObject private var tour = TourModel.shared

    var body: some View {
        let news = tour.news
        if let first = news.first, tour.session == nil {
            HStack(alignment: .center, spacing: DS.Space.space2) {
                Image(systemName: "sparkles").foregroundStyle(DS.Palette.accentText).accessibilityHidden(true)
                Text("New in betterlink: \(first.step.title)\(news.count > 1 ? ", and \(news.count - 1) more" : "")")
                    .foregroundStyle(DS.Palette.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: DS.Space.space2)
                Button("Show Me") { tour.start(.whatsNew) }.buttonStyle(.dsPrimary)
                Button { withAnimation(.easeOut(duration: 0.15)) { tour.catchUp() } } label: {
                    Image(systemName: "xmark").font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain).foregroundStyle(DS.Palette.textSecondary)
                .help("Dismiss. The steps stay under About.")
                .accessibilityLabel("Dismiss What's New")
            }
            .padding(DS.Space.space3)
            .background(RoundedRectangle(cornerRadius: DS.Radius.radiusMd, style: .continuous).fill(DS.Palette.accentTint))
            .padding(.horizontal, DS.Space.space8).padding(.top, DS.Space.space8)
            .transition(.opacity)
        }
    }
}

/// About › Tour: the tour again, What's New when there is any, or one topic.
struct TourAboutSection: View {
    @ObservedObject private var tour = TourModel.shared

    var body: some View {
        DSSection("Tour") {
            HStack(spacing: DS.Space.space2) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("The betterlink tour")
                    Text(summary).font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: DS.Space.space2)
                if !tour.news.isEmpty {
                    Button("What's New") { tour.start(.whatsNew) }.buttonStyle(.dsPrimary)
                }
                // The window's button style draws no menu arrow (menuIndicator
                // does nothing under it), so the label carries one, as DSSelect's does.
                Menu {
                    ForEach(TourRegistry.topics.filter { topic in topic.steps.contains { $0.requires.map(tour.met.contains) ?? true } }) { topic in
                        Button(topic.title) { tour.start(.topic, topic: topic.id) }
                    }
                } label: {
                    HStack(spacing: DS.Space.space1) {
                        Text("Open a Topic")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(DS.Palette.textTertiary)
                    }
                }
                .menuIndicator(.hidden)
                .accessibilityLabel("Open a Topic")
                .fixedSize()
                Button("Show the Tour") { tour.start(.replay) }
            }
        }
    }

    private var summary: String {
        let new = tour.news.count
        if new > 0 { return "\(new) step\(new == 1 ? " is" : "s are") new since you last looked." }
        return "What betterlink does and how to set it up, a step at a time."
    }
}
