import AppKit
import QuartzCore
import SwiftUI
import TabSyncCore

/// The note a sidebar shows when it can't open (SidebarNotice): a small
/// capsule over the browser window, near its top. Like the link toast it
/// never takes focus or clicks and never activates betterlink: the browser
/// stays the front app with the keyboard. It fades in, stays
/// `SidebarNotice.duration`, and fades out; a new note replaces one showing.
@MainActor
final class SidebarNoticeWindow {
    static let shared = SidebarNoticeWindow()

    private var panel: NSPanel?
    private var generation = 0

    func show(_ text: String, over window: CGRect) {
        generation += 1
        let mine = generation
        let display = NSScreen.screens.max { $0.frame.intersection(window).area < $1.frame.intersection(window).area }
        guard let visible = display?.visibleFrame else { return }
        let (p, final) = prepare(text, over: window, visible: visible)
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        p.setFrame(final.offsetBy(dx: 0, dy: still ? 0 : 6), display: false)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
            p.animator().setFrame(final, display: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18 + SidebarNotice.duration) { [weak self] in
            guard let self, self.generation == mine else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                p.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated { if self.generation == mine { p.orderOut(nil) } }
            })
        }
    }

    /// The panel with the note in it, at its place (not yet shown).
    func prepare(_ text: String, over window: CGRect, visible: CGRect) -> (NSPanel, CGRect) {
        let host = Self.host(text)
        let p = panel ?? makePanel()
        p.contentView = host
        let final = SidebarNotice.frame(size: Self.size(of: text), window: window, visible: visible)
        p.setFrame(final, display: false)
        host.layoutSubtreeIfNeeded()
        return (p, final)
    }

    static func host(_ text: String) -> NSHostingView<SidebarNoticeView> {
        let host = NSHostingView(rootView: SidebarNoticeView(text: text))
        // The panel is sized here, to the capsule, never by SwiftUI: its size
        // constraints, worked out once at a width of nothing (a word to a
        // line), grew the panel to 368 x 1048 pt on screen.
        host.sizingOptions = []
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// The panel's size for the note: the capsule's, its text wrapped at 320 pt.
    static func size(of text: String) -> CGSize {
        let measure = NSHostingController(rootView: SidebarNoticeView(text: text, pinned: false))
        let s = measure.sizeThatFits(in: CGSize(width: 368, height: 2000))
        return CGSize(width: s.width.rounded(.up), height: s.height.rounded(.up))
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel = p
        return p
    }
}

struct SidebarNoticeView: View {
    let text: String
    /// At the top of whatever it is given (the panel); off when measured.
    var pinned = true
    var body: some View {
        if pinned {
            capsule.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            capsule
        }
    }

    private var capsule: some View {
        Text(text)
            .font(DS.TextStyle.body)
            .foregroundStyle(DS.Palette.text)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 320)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, DS.Space.space4)
            .padding(.vertical, DS.Space.space3)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.Palette.border, lineWidth: 1))
            .padding(8)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isStaticText)
    }
}
