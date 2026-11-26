import AppKit
import BetterlinkCore
import SwiftUI
import TabSyncCore

/// One browser window's sidebar: its panel, what it shows, whether it is
/// hidden, how wide it is, and the width its window lent it. The settings all
/// sidebars share, and what goes on between windows, are SidebarController's.
@MainActor
final class SidebarInstance: ObservableObject {
    let window: TrackedWindow
    private unowned let sidebar: SidebarController
    private var tracker: WindowTracker { sidebar.tracker }

    /// What the panel shows. Set only when it differs (see SidebarLook).
    @Published private(set) var look = SidebarLook.notConnected
    @Published private(set) var placedSide: SidebarSide = .right
    /// Readable colors for the profile color (WCAG AA), or nil for the standard look.
    @Published private(set) var palette: SidebarPalette?
    @Published private(set) var width: Double
    /// Hidden with the shortcut or the menu: the window has its space back,
    /// and showing it again makes room again (like collapsing Arc's sidebar).
    private(set) var hidden: Bool
    private(set) var panel: SidebarPanel?
    /// On screen now, beside its window (SidebarPresence).
    private(set) var isShown = false
    /// The window as last reported, to tell what changed.
    var reported: WindowTracker.Target

    /// The width the window lent the sidebar. Mirrored into the controller's
    /// FitMemory, which outlives the app, once it has really been lent.
    private var loan: WidthLoan? {
        didSet { if loan != oldValue { sidebar.loanChanged(loan, of: window) } }
    }
    /// The narrowest the browser let this window get, once it stopped us.
    private var minWidth: CGFloat?
    private var askedAt = Date.distantPast
    /// The frame the window would not give up, so it isn't asked again.
    private var refused: CGRect?

    init(window: TrackedWindow, sidebar: SidebarController, hidden: Bool, width: Double) {
        self.window = window
        self.sidebar = sidebar
        self.hidden = hidden
        self.width = width
        reported = window.target
    }

    /// The window is no longer followed: its sidebar goes. One that closed
    /// has nothing to give back.
    func close(closed: Bool) {
        if closed { resizing = nil } else { endResize() } // a window that is gone is not read again
        outsideMove?.cancel()
        edgeTimer?.invalidate()
        edgeTimer = nil
        if closed { slideRun?.timer?.invalidate(); slideRun = nil } else { giveSpaceBack() }
        panelTokens.forEach(NotificationCenter.default.removeObserver)
        panelTokens = []
        panel?.orderOut(nil)
        panel = nil
        isShown = false
    }

    func show(_ new: SidebarLook) {
        guard new != look else { return }
        let color = new.match?.profile?.color
        if color != look.match?.profile?.color { setTint(color) }
        look = new
    }

    // MARK: - Show and hide as one slide

    /// The shortcut and the menu item: hide the sidebar and give the window its
    /// space back, or show it and make room again.
    func toggle() {
        DragTrace.log("toggle: window \(window.number) hidden \(hidden) -> \(!hidden)")
        if hidden { slideIn() } else { slideOut() }
    }

    /// A slide in progress: where the sidebar's outer edge is, the window's
    /// frames hidden and shown (equal when the window doesn't make room), and
    /// the timer stepping it.
    private struct SlideRun {
        var slide: SidebarSlide
        var side: SidebarSide
        var outer: CGFloat
        var hiddenWindow: CGRect
        var shownWindow: CGRect
        var timer: Timer?
        var frames = 0, started = CACurrentMediaTime(), worstGap: CGFloat = 0
        var fitted: Bool { hiddenWindow != shownWindow }
    }
    private var slideRun: SlideRun?

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Hides: the sidebar's inner edge and the window's edge slide toward the
    /// outer edge together; at the end the window fills the tile.
    private func slideOut() {
        endResize() // hiding mid-drag: the drag ends here
        hidden = true
        if var run = slideRun { // turning back mid-show
            run.slide.hide(at: CACurrentMediaTime(), reduceMotion: reduceMotion)
            slideRun = run
            return
        }
        // Out of sight (another Space, minimized): no slide to watch.
        guard isShown, let panel, panel.isVisible, let attached = panel.attachedSide else {
            giveSpaceBack(); layout(); return
        }
        let t = window.target
        let visible = panel.frame
        let outer = attached == .left ? visible.minX : visible.maxX
        // What the window lent comes back, wherever it has been since.
        let back = loan?.givenBack(from: t.frame, screen: screen(for: t.frame)) ?? t.frame
        var run = SlideRun(slide: SidebarSlide(shown: true), side: attached, outer: outer, hiddenWindow: back, shownWindow: t.frame)
        run.slide.hide(at: CACurrentMediaTime(), reduceMotion: reduceMotion)
        start(run)
    }

    /// Shows: the window narrows and the sidebar opens from its outer edge,
    /// together, the reverse of a hide.
    private func slideIn() {
        hidden = false
        if var run = slideRun { // turning back mid-hide
            run.slide.show(at: CACurrentMediaTime(), reduceMotion: reduceMotion)
            slideRun = run
            return
        }
        let t = window.target
        // Out of sight (another Space, minimized, full screen): it makes room
        // without a slide, where that applies, and shows when its window does.
        guard !t.fullScreen, !t.minimized, !t.appHidden, sidebar.isOnScreen(window) else { settle(t); layout(); return }
        // As settle() does: a refusal only holds for the frame it was made at (review N2).
        if let r = refused, !Self.same(r, t.frame) { refused = nil }
        // Where the window goes: narrowed to make room when it was given a
        // tile, else where it is.
        let screen = screen(for: t.frame)
        let inner = refused == nil ? SidebarGeometry.settled(window: t.frame, screen: screen, width: width, side: sidebar.side,
                                                             minWindowWidth: minWidth ?? 500) : nil
        // No room beside it and none it could give: the sidebar covers its edge.
        if inner == nil { coverIfNoRoom(t, on: screen) }
        let shown = inner ?? t.frame
        let panel = placePanel(placement(beside: shown))
        guard let attached = panel.attachedSide else { layout(); return }
        let outer = attached == .left ? panel.frame.minX : panel.frame.maxX
        if inner != nil {
            loan = .asking(outer: t.frame, inner: shown, side: attached)
            askedAt = Date()
        }
        panel.reveal = outer
        panel.showNow(at: place(panel))
        isShown = true
        var run = SlideRun(slide: SidebarSlide(shown: false), side: attached, outer: outer, hiddenWindow: t.frame, shownWindow: shown)
        run.slide.show(at: CACurrentMediaTime(), reduceMotion: reduceMotion)
        start(run)
        layout() // the list is on screen, and kept to the moment, from the first frame of the slide
    }

    private func start(_ run: SlideRun) {
        slideRun = run
        stepSlide()
        guard slideRun != nil else { return } // Reduce Motion: done in one step
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepSlide() }
        }
        RunLoop.main.add(timer, forMode: .common)
        slideRun?.timer = timer
    }

    /// One frame: the window to its frame for this moment, then the sidebar
    /// revealed up to where the window really is, so the seam stays tight
    /// even when the browser lags behind.
    private func stepSlide() {
        guard var run = slideRun, let panel else { return }
        let now = CACurrentMediaTime()
        let p = run.slide.progress(at: now)
        let f = SidebarSlide.frames(hiddenWindow: run.hiddenWindow, shownWindow: run.shownWindow,
                                    outerEdge: run.outer, width: CGFloat(width), side: run.side, progress: p)
        var seam = f.innerEdge
        if run.fitted {
            // Hiding widens the window; showing narrows it.
            AXWindow.slide(window.element, to: f.window, moveOrigin: run.side == .left,
                           growing: run.slide.phase == .hiding || run.slide.phase == .hidden)
            if let real = WindowServer.frame(window.number) {
                let edge = run.side == .left ? real.minX : real.maxX
                run.worstGap = max(run.worstGap, abs(edge - f.innerEdge))
                seam = SidebarSlide.seam(windowEdge: edge, innerEdge: f.innerEdge,
                                         hiddenEdge: run.side == .left ? run.hiddenWindow.minX : run.hiddenWindow.maxX, side: run.side)
            }
        }
        panel.reveal = seam
        run.frames += 1
        if run.slide.done(at: now) {
            run.slide.settle(at: now)
            run.timer?.invalidate()
            slideRun = nil
            finishSlide(run)
            return
        }
        slideRun = run
    }

    private func finishSlide(_ run: SlideRun) {
        let ms = (CACurrentMediaTime() - run.started) * 1000
        DragTrace.log(String(format: "slide %@: %d frames in %.0f ms (%.0f fps), worst seam gap %.1f pt, window %@",
                             run.slide.phase == .hidden ? "out" : "in", run.frames, ms, Double(run.frames) / max(ms / 1000, 0.001),
                             run.worstGap, run.fitted ? "resized" : "unchanged"))
        if run.slide.phase == .hidden {
            // Closed first, then the mask lifted: the whole panel never flashes.
            panel?.hideNow()
            panel?.reveal = nil
            isShown = false
            loan = nil
            // A browser that answered late or not at all is asked once more:
            // the window must end up with what it lent.
            if run.fitted, let now = AXWindow.frame(of: window.element), !Self.same(now, run.hiddenWindow) {
                tracker.setFrame(run.hiddenWindow, of: window)
            }
        } else {
            panel?.reveal = nil
            if run.fitted, let now = AXWindow.frame(of: window.element) { slidIn(run, at: now) }
        }
        layout()
    }

    /// The window's answer to a slide in: what it lent, or a refusal.
    private func slidIn(_ run: SlideRun, at now: CGRect) {
        let asked = loan?.inner
        let at = observe(at: now)
        guard let l = loan else { return }
        // Not narrowed, so the sidebar covers its edge for now. A browser that
        // answers late has lent it then.
        if l.phase == .asked { refused = at; return }
        // A browser at its minimum width: the pair shifts to fit the screen.
        if let asked, SidebarGeometry.room(beside: at, screen: screen(for: at), side: run.side) < width - 2 {
            _ = learnMinWidth(asked: asked, got: window.target, wasWidth: run.hiddenWindow.width)
            fit(window.target, into: l.outer)
        }
    }

    /// Brings the loan up to date with where the window is, putting it right
    /// if it narrowed from the wrong side. Returns where it is then.
    @discardableResult
    private func observe(at frame: CGRect) -> CGRect {
        guard let l = loan else { return frame }
        let seen = l.seen(at: frame, screen: screen(for: frame))
        loan = seen.loan
        guard let place = seen.correction else { return frame }
        tracker.setFrame(place, of: window)
        return place
    }

    private func coverIfNoRoom(_ t: WindowTracker.Target, on screen: CGRect) {
        // Dragged past that edge by hand, the pair runs off together instead.
        if (0..<CGFloat(width - 2)).contains(SidebarGeometry.room(beside: t.frame, screen: screen, side: sidebar.side)) { refused = t.frame }
    }

    /// Gives the window its space back, if it is still as narrowed: the
    /// sidebar is turned off, its browser no longer attached, or the app quits.
    /// False when the window couldn't be read.
    @discardableResult
    func giveSpaceBack() -> Bool {
        // Mid-slide the window goes back to its full frame first, since it is
        // at neither the narrowed nor the full width.
        if let run = slideRun {
            run.timer?.invalidate()
            slideRun = nil
            if run.fitted { tracker.setFrame(run.hiddenWindow, of: window) }
            loan = nil
            panel?.reveal = nil
        }
        // A window that can't be read now (a hung browser) keeps its record,
        // so it is recognised later instead of narrowed again.
        guard let l = loan else { return true }
        guard let now = AXWindow.frame(of: window.element) else { return false }
        let back = l.givenBack(from: now, screen: screen(for: now))
        if !Self.same(back, now) { tracker.setFrame(back, of: window) }
        loan = nil
        return true
    }

    // MARK: - Fitting the window

    /// Frames within a point count as the same: the browser rounds.
    private static func same(_ a: CGRect, _ b: CGRect) -> Bool { WidthLoan.same(a, b) }

    private func screen(for frame: CGRect) -> CGRect {
        (NSScreen.screens.max { $0.frame.intersection(frame).area < $1.frame.intersection(frame).area }
            ?? NSScreen.main)?.visibleFrame ?? frame
    }

    /// The window came to rest: make the pair fill the space the window was given.
    func settle(_ t: WindowTracker.Target) {
        // A resize by the edge still open ends with the loan read off the window.
        guard resizing == nil else { return }
        guard !hidden, !t.fullScreen, !t.minimized, !t.appHidden else { return }
        if let r = refused, !Self.same(r, t.frame) { refused = nil }
        let screen = screen(for: t.frame)
        if let l = loan {
            if l.rests(at: t.frame) { return layout() }
            if refused != nil { return layout() } // still the answer it gave
            if l.phase == .asked, learnMinWidth(asked: l.inner, got: t, wasWidth: l.outer.width) {
                loan = nil
                fit(t, into: l.outer) // it stops there: place the pair knowing that
                return layout()
            }
            let at = observe(at: t.frame)
            if let now = loan {
                // Moved to where the sidebar has no room beside it: the window
                // makes that room, out of what hiding would give back.
                if now.phase == .lent, (0..<CGFloat(width - 2)).contains(SidebarGeometry.room(beside: at, screen: screen, side: sidebar.side)) {
                    fit(t, into: now.givenBack(from: at, screen: screen))
                }
                return layout()
            }
            // Snapped again, or moved before it ever narrowed: that space is the pair's.
        }
        guard refused == nil else { return }
        // Narrowed before (this launch or an earlier one) and not moved since: keep it.
        if loan == nil, let e = sidebar.narrowedBefore(window, at: t.frame) {
            loan = .lent(outer: e.outer, inner: t.frame, side: sidebar.side)
            return layout()
        }
        fit(t, into: t.frame)
        layout()
    }

    /// Narrows the window so it and the sidebar fill `outer`. A browser that
    /// stops at its minimum width is asked once more, with that width known, so
    /// the pair stays on the screen.
    private func fit(_ t: WindowTracker.Target, into outer: CGRect) {
        let screen = screen(for: outer)
        // Back where it was, its edge covered. What was asked stands, for a
        // browser that answers late.
        func putBack(from now: CGRect) {
            if !Self.same(now, t.frame) { tracker.setFrame(t.frame, of: window) }
            observe(at: t.frame)
            refused = t.frame
        }
        for pass in 0..<2 {
            guard let inner = SidebarGeometry.settled(window: outer, screen: screen, width: width, side: sidebar.side,
                                                      minWindowWidth: minWidth ?? 500) else {
                // At its minimum width the pair has no place on this screen.
                if pass > 0 { return putBack(from: window.target.frame) }
                return coverIfNoRoom(t, on: screen)
            }
            loan = .asking(outer: outer, inner: inner, side: sidebar.side)
            askedAt = Date()
            tracker.setFrame(inner, of: window)
            let now = window.target
            if Self.same(now.frame, inner) { observe(at: now.frame); return }
            // Where it was: it has not answered, or won't narrow.
            if Self.same(now.frame, t.frame) { return putBack(from: now.frame) }
            // It narrowed, as far as it goes: asked again knowing that, as after a slide.
            if learnMinWidth(asked: inner, got: now, wasWidth: t.frame.width) { continue }
            // It would not narrow, only move.
            if SidebarGeometry.leaves(screen, from: t.frame, to: now.frame) { return putBack(from: now.frame) }
            observe(at: now.frame)
            return
        }
        observe(at: window.target.frame)
    }

    /// True when the window shows the browser's minimum width, not known yet
    /// (`SidebarGeometry.minimumWidth`): `wasWidth` is how wide it was before
    /// it was asked. Only right after asking; later, it is the user widening
    /// the window. Never from a drag of the edge (EdgeDrag): mid-drag a window
    /// that has not answered yet looks the same.
    private func learnMinWidth(asked: CGRect, got t: WindowTracker.Target, wasWidth: CGFloat) -> Bool {
        guard Date().timeIntervalSince(askedAt) < 0.5,
              let w = SidebarGeometry.minimumWidth(asked: asked, got: t.frame, wasWidth: wasWidth),
              w > (minWidth ?? 0) + 2 else { return false }
        minWidth = w
        return true
    }

    /// The side or width changed: start again from the space the pair was given.
    func refit() {
        refused = nil
        let t = window.target
        if let l = loan {
            loan = nil
            tracker.setFrame(l.givenBack(from: t.frame, screen: screen(for: t.frame)), of: window)
        }
        settle(window.target)
        layout()
    }

    /// The width every window's sidebar was given (`betterlink sidebar
    /// settings set --width`). Mid-drag, the drag's own width stands.
    func setWidth(_ w: Double) {
        guard resizing == nil, w != width else { return }
        width = w
        refit()
    }

    // MARK: - Resizing by the edge

    /// A drag of the edge between the sidebar and the window (EdgeDrag): the
    /// window is asked to make room, and the sidebar is as wide as the room it
    /// has really made.
    private struct Resize {
        var drag: EdgeDrag
        /// The space a narrowed window gave up, to give back later.
        var outer: CGRect?
        /// How much wider than at the start the pointer wants the sidebar.
        var delta: CGFloat = 0
        /// The frame last asked of the window, so it isn't asked twice.
        var asked: CGRect
        /// Where it was last put back for that ask, so a browser that won't
        /// go there isn't told again every tick.
        var put: CGRect?
        /// A single step, open until its window answers (nudge(by:)).
        var waits = false
    }
    private var resizing: Resize?
    /// False while the browser has stopped answering (BrowserWatcher): each
    /// call to its window would wait out a second, so the resize leaves it
    /// alone until it speaks again.
    private var browserAnswers: Bool { window.watcher?.isStalled != true }
    /// Ends a single step whose window has not answered in time.
    private var stepEnd: DispatchWorkItem?

    /// Starts resizing. False when there is no window at rest to resize against.
    func beginResize() -> Bool {
        endResize() // a single step still waiting for its window ends when a drag begins
        guard slideRun == nil, !hidden, isShown, let panel, panel.isVisible else { return false }
        let t = window.target
        let l = loan?.seen(at: t.frame, screen: screen(for: t.frame)).loan
        resizing = Resize(drag: EdgeDrag(window: t.frame, width: width, side: placedSide, covers: panel.attachedSide == nil),
                          outer: l?.phase == .lent ? l?.outer : nil, asked: t.frame)
        return true
    }

    private var edgeTimer: Timer?

    /// The edge was pressed at `start` (screen x): follows the pointer until
    /// the button is up. Here and by the button's state, not by the view's
    /// events: the view can be rebuilt, and a mouse-up lost, mid-drag.
    func dragEdge(from start: CGFloat) {
        guard edgeTimer == nil, beginResize() else { return }
        var last: CGFloat?
        let step = { [weak self] in
            guard let self else { return }
            let x = NSEvent.mouseLocation.x
            if x != last {
                last = x
                self.resize(by: self.placedSide == .right ? start - x : x - start)
            } else {
                self.keepFarEdge() // an answer that came after the pointer stopped
            }
            // Over: the button is up, or something else ended the resize.
            guard self.resizing == nil || NSEvent.pressedMouseButtons & 1 == 0 else { return }
            self.edgeTimer?.invalidate()
            self.edgeTimer = nil
            self.endResize()
            self.returnFocusToBrowser()
        }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in MainActor.assumeIsolated { step() } }
        RunLoop.main.add(t, forMode: .common)
        edgeTimer = t
    }

    /// The pointer wants the sidebar `delta` points wider than when the drag
    /// began. The window is asked for that room; the sidebar takes what the
    /// window has made (follow()), not what was asked.
    func resize(by delta: CGFloat) {
        guard var r = resizing else { return }
        r.delta = delta
        let ask = browserAnswers ? r.drag.ask(delta: delta).flatMap { $0 == r.asked ? nil : $0 } : nil
        if let ask { r.asked = ask; r.put = nil }
        resizing = r
        if let ask {
            // One step that keeps the far edge whatever width the browser
            // takes: a window at its minimum is not moved off its tile.
            AXWindow.slide(window.element, to: ask, moveOrigin: r.drag.side == .left,
                           growing: ask.width > window.target.frame.width)
            window.watcher?.refresh(window)
        }
        keepFarEdge()
        follow()
    }

    /// Mid-drag: a window that narrowed where it stood (an answer that came
    /// late) goes back to the far edge the drag began with.
    private func keepFarEdge() {
        guard browserAnswers, var r = resizing, let at = r.drag.kept(window.target.frame), at != r.put else { return }
        r.put = at
        resizing = r
        tracker.setFrame(at, of: window)
    }

    /// Mid-drag the sidebar is as wide as the room the window has made.
    private func trackResize() {
        guard let r = resizing else { return }
        let w = Double(r.drag.width(delta: r.delta, beside: window.target.frame))
        if w != width { width = w }
    }

    /// One step without a pointer (the edge's adjustable action: VoiceOver,
    /// the keyboard). There is no button to come up, so the resize stays open
    /// until the window has answered (follow()), or `EdgeDrag.answerWait` has
    /// passed, and then ends from the window's frame as a drag does. A step
    /// taken while the last one still waits (key repeat) adds to what is
    /// asked, and the wait starts again.
    func nudge(by step: CGFloat) {
        guard edgeTimer == nil, resizing?.waits == true || beginResize(), let open = resizing else { return }
        resize(by: open.drag.stepped(open.delta, by: step))
        guard let r = resizing else { return }
        if r.drag.answered(r.asked, by: window.target.frame) { return endResize() }
        resizing?.waits = true
        stepEnd?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.endResize() } }
        stepEnd = work
        DispatchQueue.main.asyncAfter(deadline: .now() + EdgeDrag.answerWait, execute: work)
    }

    func endResize() {
        stepEnd?.cancel()
        stepEnd = nil
        resizing?.waits = false
        guard let r = resizing else { return }
        // Where the window is now, an answer still on its way included: the
        // width saved and the loan are what it really gave. A browser that
        // has stopped answering is taken as last seen.
        if browserAnswers { window.watcher?.refresh(window) }
        if browserAnswers, let at = r.drag.kept(window.target.frame) { tracker.setFrame(at, of: window) }
        trackResize()
        resizing = nil
        sidebar.widthChosen(width, for: self)
        let now = window.target.frame
        if let l = r.drag.loan(lent: r.outer, at: now) { loan = l }
        DragTrace.log("edge drag: window \(window.number) \(r.drag.side) wanted \(Int(r.delta)), window \(r.drag.window) -> \(now), "
                      + "sidebar \(Int(r.drag.width)) -> \(Int(width)), lent \(Int(loan?.taken ?? 0))")
        layout()
    }

    // MARK: - Layout

    /// Every sidebar to its place: beside its window and among the other
    /// windows, or out of sight. One reading of the window list for them all.
    private func layout() { sidebar.arrange() }

    /// The window moved or resized: the panel stays beside it, on a Space
    /// that isn't showing too.
    func follow() {
        trackResize()
        // A single step still open: the window goes back to its far edge, and
        // its answer ends the step.
        if let r = resizing, r.waits {
            keepFarEdge()
            if r.drag.answered(r.asked, by: window.target.frame) { endResize() }
        }
        // A slide places the panel itself, frame by frame.
        guard slideRun == nil, panel?.isVisible == true else { return }
        placePanel(placement(beside: window.target.frame))
    }

    /// Shows the panel in its place, lets it sleep on its window's Space, or
    /// takes it away (SidebarPresence). `onScreen`: the windows on screen,
    /// front to back. `settled`: the Spaces have stopped moving.
    func present(onScreen: [UInt32], settled: Bool) {
        guard slideRun == nil else { return }
        let t = window.target
        let p = placement(beside: t.frame)
        let decision = SidebarPresence.decide(window: window.number, panel: panel.flatMap { $0.isVisible ? UInt32(exactly: $0.windowNumber) : nil },
                                              onScreen: onScreen, hidden: hidden || t.fullScreen || t.minimized || t.appHidden,
                                              attached: !p.overlaps, settled: settled)
        switch decision {
        case .away:
            isShown = false
            panel?.fadeOut()
        case .asleep:
            isShown = false
            if panel?.isVisible == true { placePanel(p) }
        case .shown(let rehome, let reorder):
            isShown = true
            let panel = placePanel(p)
            if rehome { panel.reenter(at: place(panel)) } else if reorder, panel.isVisible { panel.order(at: place(panel)) }
            panel.fadeIn(at: place(panel))
        }
    }

    /// The panel's place among the windows: next to this one.
    private func place(_ panel: SidebarPanel) -> SidebarPanel.Place {
        .init(relation: SidebarPresence.relation(attached: panel.attachedSide != nil), window: window.number)
    }

    /// Where the panel goes beside a window at `frame` (this window's, or
    /// where it is about to be).
    private func placement(beside frame: CGRect) -> SidebarPlacement {
        let l = loan.flatMap { Self.same($0.inner, frame) ? $0 : nil }
        return SidebarGeometry.place(window: frame, screen: screen(for: frame), width: width, side: l?.side ?? sidebar.side,
                                     keepOnScreen: refused.map { Self.same($0, frame) } ?? false)
    }

    /// Puts the panel there, attached to the window's edge. Returns the panel.
    @discardableResult
    private func placePanel(_ p: SidebarPlacement) -> SidebarPanel {
        if placedSide != p.side { placedSide = p.side }
        let fresh = self.panel == nil
        let panel = self.panel ?? makePanel()
        let attached: SidebarSide? = p.overlaps ? nil : p.side
        if fresh || panel.attachedSide != attached { panel.attach(to: attached) }
        // Beside the window, the panel reaches under the window's rounded
        // corners to fill them (see SidebarPanel), so it is that much wider.
        let reach = attached == nil ? 0 : panel.reach
        var frame = p.sidebar
        frame.size.width += reach
        if attached == .right { frame.origin.x -= reach }
        // Set first: the move notifications arrive inside setFrame.
        placedPanelFrame = frame
        // A pure move is cheap; only a real resize lays the tab list out again.
        if panel.frame.size != frame.size {
            panel.setFrame(frame, display: true, animate: false)
        } else if panel.frame.origin != frame.origin {
            panel.setFrameOrigin(frame.origin)
        }
        return panel
    }

    private func makePanel() -> SidebarPanel {
        let host = NSHostingView(rootView: SidebarView().environmentObject(self))
        // The browser window sets the panel's size; the content must never grow it.
        host.sizingOptions = []
        let panel = SidebarPanel(contentView: host)
        panel.setTint(tint)
        // A press brings the panel in front of every window: back to its place.
        panel.onClick = { [weak self] in self?.tracker.orderMayHaveChanged() }
        self.panel = panel
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            panelTokens.append(NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.panelFrameChanged() }
            })
        }
        return panel
    }

    // MARK: - Moved from outside

    /// The frame the panel was last given here. Any other frame came from
    /// outside: a window-snapping tool or anything else using Accessibility.
    private var placedPanelFrame: CGRect?
    private var panelTokens: [NSObjectProtocol] = []
    private var outsideMove: DispatchWorkItem?

    /// A snap or move aimed at the sidebar is meant for the pair: once the
    /// tool is done (it may set the position and the size separately), the
    /// browser window and the sidebar fill the panel's new frame together, the
    /// sidebar keeping its width on its side, as snapping the browser does.
    private func panelFrameChanged() {
        guard let panel, let placed = placedPanelFrame, !Self.same(panel.frame, placed) else { return }
        // macOS moves windows itself when displays change; that is no snap.
        guard Date().timeIntervalSince(sidebar.screensChangedAt) > 1 else { return }
        outsideMove?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.movePairToPanel() } }
        outsideMove = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func movePairToPanel() {
        guard let panel, let placed = placedPanelFrame, !Self.same(panel.frame, placed), !hidden, isShown else { return }
        let t = window.target
        let rect = panel.frame
        let side = placedSide
        let inner = SidebarGeometry.windowAfterPanelMoved(from: placed, to: rect, window: t.frame, width: width, side: side,
                                                          minWindowWidth: minWidth ?? 500)
        let before = loan
        if abs(rect.width - placed.width) >= 2 {
            // Given a tile: hiding the sidebar later gives the browser all of it.
            loan = .asking(outer: rect, inner: inner, side: side)
        } else if let l = before {
            // Carried along: the space to give back moves with the window.
            loan = l.moved(by: inner.minX - t.frame.minX, to: inner)
        }
        askedAt = Date()
        tracker.setFrame(inner, of: window)
        observe(at: window.target.frame)
        // It would not go there: what it had lent still stands.
        if loan == nil, let before { loan = before }
        layout()
    }

    // MARK: - Actions from the sidebar

    /// Paints the sidebar in the browser profile's frame color (nil: the
    /// standard sidebar material), so it reads as part of that window.
    private func setTint(_ rgb: UInt32?) {
        let p = rgb.map { SidebarPalette(profileColor: $0) }
        if palette != p { palette = p }
        tint = p?.background.hex
        panel?.setTint(tint)
    }
    private var tint: UInt32?

    /// After a click or a typed link in the sidebar, hand the keyboard back to
    /// the browser, in this window.
    func returnFocusToBrowser() {
        window.watcher?.activate(window)
        // The browser is usually the active app already, so activating it takes
        // nothing from this non-activating panel: let the keyboard go by hand.
        if let panel, panel.isKeyWindow { panel.reenter(at: place(panel)) }
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
