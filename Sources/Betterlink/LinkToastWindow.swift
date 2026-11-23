import AppKit
import QuartzCore
import BetterlinkCore
import SwiftUI

/// A small capsule at the top or bottom middle of the screen the pointer is
/// on: "● Work · Holding ⌃⌘". It never takes focus or clicks, sits on every
/// Space and over full-screen apps, and fades out after a moment.
@MainActor
final class LinkToastWindow {
    static let shared = LinkToastWindow()

    private var panel: NSPanel?

    /// Bumped by every toast, so a fade-out still running from the last one
    /// never hides the new one.
    private var generation = 0

    /// Fades in while sliding a few points in from its edge, stays
    /// `LinkToast.duration`, then fades out. With Reduce Motion on it only
    /// fades. A new toast replaces one still showing.
    func show(profile: BrowserProfile, detail: String, position: LinkToast.Position) {
        generation += 1
        let mine = generation
        let host = NSHostingView(rootView: LinkToastView(profile: profile, detail: detail))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let p = panel ?? makePanel()
        p.contentView = host
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        let margin: CGFloat = 8
        let y = position == .top ? area.maxY - size.height - margin : area.minY + margin
        let final = NSRect(x: (area.midX - size.width / 2).rounded(), y: y, width: size.width, height: size.height)
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Start slightly toward the screen edge it belongs to.
        let slide: CGFloat = still ? 0 : (position == .top ? 8 : -8)
        p.setFrame(final.offsetBy(dx: 0, dy: slide), display: false)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
            p.animator().setFrame(final, display: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22 + LinkToast.duration) { [weak self] in
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

private struct LinkToastView: View {
    let profile: BrowserProfile
    let detail: String
    var body: some View {
        HStack(spacing: DS.Space.space2) {
            ProfileDot(color: profile.swiftUIColor)
            Text(profile.name).font(DS.TextStyle.bodyStrong).foregroundStyle(DS.Palette.text)
            Text(detail).font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
        }
        .lineLimit(1)
        .padding(.horizontal, DS.Space.space3)
        .padding(.vertical, 6)
        .background(Capsule().fill(DS.Palette.raised))
        .overlay(Capsule().strokeBorder(DS.Palette.borderSubtle, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        .padding(10)   // room for the shadow inside the window
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}
