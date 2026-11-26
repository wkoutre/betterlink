import AppKit
import BetterlinkCore
import SwiftUI
import TabSyncCore

/// One browser window's sidebar: its panel, what it shows, whether it is
/// hidden, and how wide it is. The settings all sidebars share, and what goes
/// on between windows, are SidebarController's.
///
/// Showing and hiding keep four rules (Nick, 2026-11-26), in every browser,
/// wherever the window is: (1) the browser's width with its sidebar closed is
/// where it starts; (2) open, the sidebar and the browser share that frame,
/// the browser's far edge where it was; (3) while open, the person moves and
/// resizes either as they like; (4) closed, the browser takes the pair's frame.
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

    /// The width this window's sidebar opens at; `width` is what it has now,
    /// less when the browser couldn't give it all.
    private(set) var chosenWidth: Double
    /// The browser is narrowed for its open sidebar: closing gives it the
    /// pair's frame. Mirrored into the controller's FitMemory, which outlives the app.
    private var paired = false
    /// Opening, until the browser has answered: the frame the pair occupies
    /// (the window's with the sidebar closed), what the browser was asked
    /// for, and when.
    private struct Opening {
        var frame: CGRect
        var asked: CGRect
        var at: Date
        var tries = 0
        /// Where the browser was put back to keep its far edge: once it rests
        /// there, opening is over.
        var left: CGRect?
        var corrections = 0
        /// Where it was at the last look.
        var seen: CGRect?
    }
    private var opening: Opening?
    /// A refused open's window on its way back to the frame it had: a press
    /// meanwhile is held until it is there (the last press wins).
    private var restoring: CGRect?

    /// Shows the note saying why a sidebar didn't open (SidebarNotice), over
    /// its window. Tests record it instead.
    static var tell: (SidebarNotice, CGRect) -> Void = { notice, window in
        SidebarNoticeWindow.shared.show(notice.text, over: window)
    }

    init(window: TrackedWindow, sidebar: SidebarController, hidden: Bool, width: Double) {
        self.window = window
        self.sidebar = sidebar
        self.hidden = hidden
        self.width = width
        chosenWidth = width
        reported = window.target
        cornerDisplay = display(for: window.target.frame)?.number
        readCorner("followed")
    }

    // MARK: - The window's corner

    /// The radius of this window's corners: what the seam's notches and the
    /// sidebar's outer corners are cut for. From the window server
    /// (`WindowServer.cornerRadius`), or the fallback while it has never said.
    private(set) var cornerRadius = SidebarSeam.fallbackRadius
    /// The last radius the window server gave for this window.
    private var cornerRead: CGFloat?
    /// The display the window was on when its corner was last read.
    private var cornerDisplay: CGDirectDisplayID?

    /// Asks the window server once: when the window is first followed, when
    /// it enters or leaves full screen, and each time it comes to rest (the
    /// moment it leaves full screen the window server may not have its
    /// corner back yet). Never per frame or on a timer. A read that gives
    /// nothing keeps the last one that did (`SidebarSeam.radius(read:lastRead:)`).
    func readCorner(_ why: String) {
        let began = CACurrentMediaTime()
        let read = WindowServer.cornerRadius(window.number)
        let ms = (CACurrentMediaTime() - began) * 1000
        let radius = SidebarSeam.radius(read: read, lastRead: cornerRead)
        if DragTrace.enabled {
            let nothing = WindowServer.cornersUnreadBecause ?? "the window server gave no radius between 4 and 40 pt"
            let from = read != nil ? "from the window server" : cornerRead != nil ? "kept from the last read (\(nothing))" : "the fallback (\(nothing))"
            DragTrace.log(String(format: "corner: window %u (%@) radius %.2f pt %@, read in %.3f ms (%@)", window.number, window.target.appName,
                                 Double(radius), from, ms, why))
        }
        if let read { cornerRead = read }
        // The same radius: the panel is left as it is.
        guard radius != cornerRadius else { return }
        cornerRadius = radius
        follow() // a panel on screen takes the new shape now
    }

    /// The window is no longer followed: its sidebar goes. One that closed
    /// has nothing to give back.
    func close(closed: Bool) {
        if closed { resizing = nil } else { endResize() } // a window that is gone is not read again
        outsideMove?.cancel()
        edgeTimer?.invalidate()
        edgeTimer = nil
        restoring = nil
        if closed { slideRun = nil; steps = nil; afterSteps = nil; stopTicker() } else { giveSpaceBack() }
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

    /// The shortcut and the menu item: hide the sidebar, the browser taking the
    /// pair's frame, or show it in the browser's frame.
    func toggle() {
        DragTrace.log("toggle: window \(window.number) hidden \(hidden) -> \(!hidden)")
        if hidden { slideIn() } else { slideOut() }
    }

    /// A slide in progress: where the sidebar's outer edge is, and the
    /// browser's frames closed and open. Only the panel slides, revealed up to
    /// where the browser really is; the browser is moved by `steps`.
    private struct SlideRun {
        var slide: SidebarSlide
        var side: SidebarSide
        var outer: CGFloat
        var hiddenWindow: CGRect
        var shownWindow: CGRect
        var frames = 0, started = CACurrentMediaTime(), worstGap: CGFloat = 0
    }
    private var slideRun: SlideRun?

    /// The browser on its way somewhere, one Accessibility call at a time,
    /// each waited for on screen (`WindowSteps`), and what follows once it is
    /// there. Never a call per frame: on macOS 27 each call is animated, and
    /// the next one cuts it short where it has got to.
    private var steps: WindowSteps?
    private var afterSteps: (() -> Void)?
    private var ticker: Timer?

    /// Reduce Motion, and the clock. Tests set their own and step the slide
    /// and the browser's moves tick by tick (`stepSlide`), as the timer does.
    var reducesMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var clock: () -> CFTimeInterval = CACurrentMediaTime
    /// The panel sliding, or the browser being moved.
    var sliding: Bool { slideRun != nil || steps != nil }

    /// The window as the window server shows it. Accessibility can read back
    /// a size or position before it is on screen (on macOS 27 at once, while
    /// the change is still animating), so what is on screen decides.
    private var onScreenFrame: CGRect { AXWindow.shownFrame(of: window.handle) ?? window.target.frame }

    /// The browser's frame when the sidebar closes from a browser at `b` (rule 4).
    private func closedFrame(from b: CGRect, side: SidebarSide) -> CGRect {
        SidebarGeometry.closed(browser: b, width: CGFloat(width), side: side, displays: Displays.all.map(\.frame))
    }

    /// Moves the browser to `frame`, its far edge (away from `keep`) where
    /// `frame` has it whatever width it takes, then does `then`.
    /// `widest`: opening, the widest the browser may stop at and leave the
    /// sidebar its least width (`WindowSteps.widest`). Moved meanwhile by
    /// someone else, `then` is not done: `takenByOther()` is.
    private func move(to frame: CGRect, keep: SidebarSide?, widest: CGFloat? = nil, then: @escaping () -> Void = {}) {
        steps = WindowSteps(target: frame, keep: keep, widest: widest, after: steps)
        afterSteps = then
        stepWindow()
        runTicker()
    }

    private func runTicker() {
        guard sliding, ticker == nil else { return }
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepSlide() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    /// One tick: the browser's next call once its last is on screen, then the
    /// panel's slide.
    func stepSlide() {
        stepWindow()
        stepPanel()
        if !sliding { stopTicker() }
    }

    private func stepWindow() {
        guard var s = steps else { return }
        if let call = s.step(seen: onScreenFrame, now: clock()) { AXWindow.send(call, to: window.handle) }
        guard s.done else { steps = s; return }
        steps = nil
        let then = afterSteps
        afterSteps = nil
        if s.interrupted { takenByOther() } else { then?() }
    }

    /// Someone else moved or resized the window while betterlink was moving
    /// it (the person, or another app: `WindowSteps.interrupted`): nothing
    /// more is sent, and their frame stands. An open not yet answered is
    /// given up, the sidebar closed; a hide, or a refused open going back,
    /// ends where the window is; an open sidebar stays open beside it (rule 3).
    /// A press held meanwhile goes with it: theirs is the latest word.
    private func takenByOther() {
        DragTrace.log("moved by someone else: window \(window.number) at \(onScreenFrame), left there")
        let giveUp = opening.map { $0.left == nil } ?? false
        opening = nil
        if restoring != nil { restoring = nil; hidden = true }
        if giveUp { hidden = true; sidebar.refused(self) }
        if hidden {
            closePanelNow()
            unpair()
        } else if slideRun != nil {
            slideRun = nil
            panel?.reveal = nil
        }
        layout()
    }

    /// The panel gone at once, mid-slide too.
    private func closePanelNow() {
        slideRun = nil
        panel?.reveal = nil
        panel?.hideNow()
        isShown = false
    }

    /// Hides (rule 4): the browser takes the pair's frame, read off the screen
    /// now, wherever the two have been moved or resized since.
    private func slideOut() {
        endResize() // hiding mid-drag: the drag ends here
        hidden = true
        // A refused open still going back: it stays closed once there.
        if restoring != nil { return }
        opening = nil
        if var run = slideRun { // turning back mid-show
            run.slide.hide(at: clock(), reduceMotion: reducesMotion())
            slideRun = run
            return move(to: run.hiddenWindow, keep: run.side)
        }
        guard paired else { return layout() }
        // Out of sight (another Space, minimized): no slide to watch.
        guard isShown, let panel, panel.isVisible else {
            let back = closedFrame(from: onScreenFrame, side: placedSide)
            move(to: back, keep: nil) { [weak self] in self?.unpair() }
            return layout()
        }
        let side = panel.attachedSide
        let b = onScreenFrame
        let back = closedFrame(from: b, side: side)
        let outer = side == .left ? panel.frame.minX : panel.frame.maxX
        var run = SlideRun(slide: SidebarSlide(shown: true), side: side, outer: outer, hiddenWindow: back, shownWindow: b)
        run.slide.hide(at: clock(), reduceMotion: reducesMotion())
        slideRun = run
        move(to: back, keep: side)
        stepPanel()
    }

    /// Shows (rule 2): the sidebar opens in the browser's frame, the browser
    /// narrowing from that side, the reverse of a hide.
    private func slideIn() {
        hidden = false
        // A refused open still going back: it opens once there (restored()).
        if restoring != nil { return }
        if var run = slideRun { // turning back mid-hide: open in the frame it was closing to (rule 2)
            if tooNarrow(run.hiddenWindow) { return }
            let browser = SidebarGeometry.opened(run.hiddenWindow, width: CGFloat(width), side: run.side)
            let panel = placePanel(placement(beside: browser))
            run.outer = run.side == .left ? panel.frame.minX : panel.frame.maxX
            run.shownWindow = browser
            run.slide.show(at: clock(), reduceMotion: reducesMotion())
            slideRun = run
            opening = Opening(frame: run.hiddenWindow, asked: browser, at: Date())
            return move(to: browser, keep: run.side, widest: run.hiddenWindow.width - SidebarGeometry.widths.lowerBound) { [weak self] in
                self?.answer()
            }
        }
        let t = window.target
        // Out of sight (another Space, minimized, full screen): it opens
        // without a slide, where that applies, and shows when its window does.
        guard !t.fullScreen, !t.minimized, !t.appHidden, sidebar.isOnScreen(window) else { settle(t); layout(); return }
        open(from: onScreenFrame, slide: true)
        layout() // the list is on screen, and kept to the moment, from the first frame of the slide
    }

    /// Opens the sidebar in `frame`, the browser's frame with it closed: the
    /// browser is asked for the frame less the sidebar's width, its far edge
    /// kept. What it really takes decides the sidebar's width (`answer()`).
    private func open(from frame: CGRect, slide: Bool) {
        if tooNarrow(frame) { return layout() }
        width = chosenWidth
        let side = sidebar.side
        let browser = SidebarGeometry.opened(frame, width: CGFloat(width), side: side)
        opening = Opening(frame: frame, asked: browser, at: Date())
        paired = true
        let panel = placePanel(placement(beside: browser))
        if slide {
            let outer = side == .left ? panel.frame.minX : panel.frame.maxX
            panel.reveal = outer
            panel.showNow(at: place(panel))
            isShown = true
            var run = SlideRun(slide: SidebarSlide(shown: false), side: side, outer: outer, hiddenWindow: frame, shownWindow: browser)
            run.slide.show(at: clock(), reduceMotion: reducesMotion())
            slideRun = run
        }
        move(to: browser, keep: side, widest: frame.width - SidebarGeometry.widths.lowerBound) { [weak self] in self?.answer() }
        stepPanel()
    }

    /// One frame of the panel's slide: revealed up to where the browser
    /// really is, so the seam stays tight however the browser moves. Over
    /// once the panel has slid and the browser is where it was going.
    private func stepPanel() {
        guard var run = slideRun, let panel else { return }
        let now = clock()
        let inner = SidebarSlide.innerEdge(outerEdge: run.outer, width: CGFloat(width), side: run.side, progress: run.slide.progress(at: now))
        var seam = inner
        if run.hiddenWindow != run.shownWindow, let real = AXWindow.shownFrame(of: window.handle) {
            let edge = run.side == .left ? real.minX : real.maxX
            run.worstGap = max(run.worstGap, abs(edge - inner))
            seam = SidebarSlide.seam(windowEdge: edge, innerEdge: inner,
                                     hiddenEdge: run.side == .left ? run.hiddenWindow.minX : run.hiddenWindow.maxX, side: run.side)
        }
        panel.reveal = seam
        run.frames += 1
        guard run.slide.done(at: now), steps == nil else { slideRun = run; return runTicker() }
        run.slide.settle(at: now)
        slideRun = nil
        finishSlide(run)
    }

    private func finishSlide(_ run: SlideRun) {
        let ms = (CACurrentMediaTime() - run.started) * 1000
        let out = run.slide.phase == .hidden
        let asked = out ? run.hiddenWindow : run.shownWindow
        // What the window did, as the window server shows it, not what was asked.
        let got = onScreenFrame
        DragTrace.log(String(format: "slide %@: %d frames in %.0f ms, worst seam gap %.1f pt, window asked %@ got %@ (%@)",
                             out ? "out" : "in", run.frames, ms, run.worstGap,
                             "\(asked)", "\(got)", SidebarGeometry.same(asked, got) ? "as asked" : "not as asked"))
        panel?.reveal = nil
        if out {
            // Closed first, then the mask lifted: the whole panel never flashes.
            panel?.hideNow()
            isShown = false
            unpair()
        }
        layout()
    }

    /// The browser's answer to opening, once it is where it was asked to go,
    /// or rests: the pair stays in the frame it opened in (rule 2). The
    /// browser keeps its far edge at the width it really took, and the
    /// sidebar has the rest of the frame. One that took none of what it was
    /// asked, though it did something since the last look (a tiling app put
    /// it back, a request was dropped), is asked again. One that took part
    /// and stopped is at its minimum, and is never asked again: if that
    /// leaves the sidebar less than its least width, or the browser took no
    /// size at all, the sidebar stays closed at once and the window goes back
    /// to its frame (`refuse`).
    /// `atRest`: the window tracker says it has stopped moving. Opening ends
    /// at the first rest that finds it where it was left. Found with its top
    /// left moved, and not back in its old frame, it was moved or resized by
    /// the person: open, that stands (rule 3).
    private func answer(atRest: Bool = false) {
        guard var o = opening, steps == nil else { return }
        let side = sidebar.side
        let real = onScreenFrame
        if let left = o.left {
            if SidebarGeometry.same(real, left) || o.corrections >= 3 {
                guard atRest else { return }
                opening = nil // it rests where it was put
                return remember()
            }
            // Moved from where it was left (its top left elsewhere), and not
            // back in its old frame (a tiling app putting it back in its
            // tile): the person's move or resize. It is open: theirs stands
            // (rule 3). A browser keeps its top left whatever size it takes.
            let movedAway = abs(real.minX - left.minX) >= 2 || abs(real.maxY - left.maxY) >= 2
            if movedAway, !SidebarGeometry.same(real, o.frame) {
                opening = nil
                remember()
                return follow()
            }
        }
        let moved = !SidebarGeometry.same(o.seen ?? o.frame, real)
        o.seen = real
        opening = o
        let tookNothing = abs(real.width - o.frame.width) < 2
        // Took part and stopped: its minimum.
        if !tookNothing, real.width > o.asked.width + 2 { least = real.width }
        if real.width > o.asked.width + 2, tookNothing, moved, o.tries < 3 {
            o.tries += 1
            o.at = Date()
            opening = o
            return move(to: o.asked, keep: side, widest: o.frame.width - SidebarGeometry.widths.lowerBound) { [weak self] in self?.answer() }
        }
        if let notice = SidebarNotice.refusal(frame: o.frame, took: real.width) { return refuse(o, real: real, notice) }
        let room = o.frame.width - real.width
        // Its far edge where it was, at the width it really has.
        var at = real
        at.origin.x = side == .left ? o.frame.maxX - real.width : o.frame.minX
        let w = min(Double(room), Double(SidebarGeometry.widths.upperBound))
        if w != width { width = w }
        if abs(at.minX - real.minX) < 0.5 {
            o.left = real
            opening = o
        } else {
            o.left = at
            o.corrections += 1
            o.at = Date()
            opening = o
            move(to: at, keep: side) { [weak self] in self?.answer() }
        }
        remember()
        follow()
    }

    /// The sidebar can't open: closed at once, the note saying why shown, and
    /// the window put back to the frame it had (waited for, one call at a
    /// time), unless someone else moves it meanwhile (`takenByOther()`).
    private func refuse(_ o: Opening, real: CGRect, _ notice: SidebarNotice) {
        DragTrace.log("open: window \(window.number) took \(Int(real.width)) of \(Int(o.frame.width)) pt, leaving the sidebar "
                      + "\(Int(o.frame.width - real.width)), less than its least \(Int(SidebarGeometry.widths.lowerBound)): back to \(o.frame), the sidebar closed")
        opening = nil
        hidden = true
        sidebar.refused(self)
        closePanelNow()
        unpair()
        Self.tell(notice, o.frame)
        if !SidebarGeometry.same(real, o.frame) {
            restoring = o.frame
            move(to: o.frame, keep: nil) { [weak self] in self?.restored() }
        }
        layout()
    }

    /// The narrowest this window has been seen to go when asked to go
    /// narrower: its browser's minimum, learned from a refused or short
    /// open. Seen narrower since (the person resized it), that is its least.
    private var least: CGFloat?

    /// Too narrow, by what this window has shown it can't go below, to leave
    /// the sidebar its least width out of `frame`: it stays closed at once,
    /// with its note, and nothing is asked of the browser.
    private func tooNarrow(_ frame: CGRect) -> Bool {
        guard let least, frame.width - least < SidebarGeometry.widths.lowerBound - 0.5 else { return false }
        DragTrace.log("open: window \(window.number) goes no narrower than \(Int(least)) pt, leaving the sidebar \(Int(frame.width - least)) of \(Int(frame.width)): stays closed")
        hidden = true
        sidebar.refused(self)
        Self.tell(.noRoom, frame)
        return true
    }

    /// A refused open's window is back. Pressed again meanwhile (the last
    /// press asked for it open): tried again from there.
    private func restored() {
        restoring = nil
        guard !hidden else { return layout() }
        hidden = true
        slideIn()
    }

    /// Records where the open pair is, for a relaunch.
    private func remember() {
        guard paired else { return }
        let b = window.target.frame
        sidebar.paired(window, browser: b, pair: closedFrame(from: b, side: placedSide))
    }

    private func unpair() {
        guard paired else { return }
        paired = false
        sidebar.unpaired(window)
    }

    /// The browser takes the pair's frame (rule 4) at once, without a slide:
    /// the sidebar is turned off, its browser no longer attached, or the app
    /// quits. False when the window couldn't be read.
    @discardableResult
    func giveSpaceBack() -> Bool {
        opening = nil
        let goingBack = restoring // a refused open's window on its way back
        restoring = nil
        let mid = slideRun
        slideRun = nil
        steps = nil
        afterSteps = nil
        stopTicker()
        panel?.reveal = nil
        guard mid != nil || paired || goingBack != nil else { return true }
        // A window that can't be read now (a hung browser) keeps its record,
        // so it is recognised later instead of narrowed again.
        guard AXWindow.frame(of: window.handle) != nil else { return false }
        // Mid-slide, the slide's closed frame.
        let back = goingBack ?? mid?.hiddenWindow ?? closedFrame(from: onScreenFrame, side: placedSide)
        if !SidebarGeometry.same(back, onScreenFrame) { AXWindow.placeNow(window.handle, to: back, keep: nil) }
        unpair()
        return true
    }

    /// The display most of `frame` is on.
    private func display(for frame: CGRect) -> Display? { Displays.display(for: frame) }

    /// The window came to rest. Opening: the browser's answer. Open: the
    /// person's moves and resizes stand (rule 3). Shown but not yet narrowed
    /// for it (a window just followed, or back from full screen): it opens.
    func settle(_ t: WindowTracker.Target) {
        // At rest, its corner is asked again: not while it is dragged, slid
        // or its edge is dragged (it comes to rest again after those).
        if slideRun == nil, resizing == nil, !tracker.isDragging(window) {
            let on = display(for: t.frame)?.number
            readCorner(on != cornerDisplay ? "settled on another display" : "settled")
            cornerDisplay = on
        }
        guard resizing == nil, !sliding else { return }
        guard !hidden, !t.fullScreen, !t.minimized, !t.appHidden else { return }
        if let o = opening {
            if Date().timeIntervalSince(o.at) < 2 { answer(atRest: true); return layout() }
            opening = nil // long since: what it does now is the person's
        }
        guard paired else {
            // Open since before betterlink last started, and still where it was: narrowed already.
            if let e = sidebar.narrowedBefore(window, at: t.frame) {
                paired = true
                width = min(max(Double(e.outer.width - e.inner.width), Double(SidebarGeometry.widths.lowerBound)),
                            Double(SidebarGeometry.widths.upperBound))
                return layout()
            }
            open(from: onScreenFrame, slide: false)
            return layout()
        }
        remember()
        layout()
    }

    /// The side or width changed: closed and opened again, without a slide.
    func refit() {
        guard paired, !hidden, !sliding else { return }
        opening = nil
        let back = closedFrame(from: onScreenFrame, side: placedSide)
        move(to: back, keep: nil) { [weak self] in
            guard let self else { return }
            self.unpair()
            self.open(from: back, slide: false)
            self.layout()
        }
    }

    /// The width every window's sidebar was given (`betterlink sidebar
    /// settings set --width`). Mid-drag, the drag's own width stands.
    func setWidth(_ w: Double) {
        guard resizing == nil, w != chosenWidth else { return }
        chosenWidth = w
        if paired { refit() } else { width = w }
    }

    // MARK: - Resizing by the edge

    /// A drag of the edge between the sidebar and the window (EdgeDrag): the
    /// window is asked to make room, and the sidebar is as wide as the room it
    /// has really made.
    private struct Resize {
        var drag: EdgeDrag
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
        guard !sliding, !hidden, isShown, let panel, panel.isVisible else { return false }
        let t = window.target
        resizing = Resize(drag: EdgeDrag(window: t.frame, width: width, side: placedSide), asked: t.frame)
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
            AXWindow.slide(window.handle, to: ask, side: r.drag.side, moveOrigin: r.drag.side == .left,
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
        // width saved is what it really gave. A browser that has stopped
        // answering is taken as last seen.
        if browserAnswers { window.watcher?.refresh(window) }
        if browserAnswers, let at = r.drag.kept(window.target.frame) { tracker.setFrame(at, of: window) }
        trackResize()
        resizing = nil
        chosenWidth = width
        sidebar.widthChosen(width, for: self)
        let now = window.target.frame
        DragTrace.log("edge drag: window \(window.number) \(r.drag.side) wanted \(Int(r.delta)), window \(r.drag.window) -> \(now), "
                      + "sidebar \(Int(r.drag.width)) -> \(Int(width))")
        remember()
        layout()
    }

    // MARK: - Layout

    /// Every sidebar to its place: beside its window and among the other
    /// windows, or out of sight. One reading of the window list for them all.
    private func layout() { sidebar.arrange() }

    /// The window moved or resized: the panel stays beside it, on a Space
    /// that isn't showing too.
    func follow() {
        if let l = least, window.target.frame.width < l - 1 { least = window.target.frame.width }
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
                                              settled: settled)
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
        .init(relation: SidebarPresence.relation, window: window.number)
    }

    /// Where the panel goes beside a window at `frame` (this window's, or
    /// where it is about to be).
    private func placement(beside frame: CGRect) -> SidebarPlacement {
        SidebarGeometry.place(window: frame, width: width, side: sidebar.side, scale: display(for: frame)?.scale ?? 1)
    }

    /// Puts the panel there, attached to the window's edge. Returns the panel.
    @discardableResult
    private func placePanel(_ p: SidebarPlacement) -> SidebarPanel {
        if placedSide != p.side { placedSide = p.side }
        let fresh = self.panel == nil
        let panel = self.panel ?? makePanel()
        let attached = p.side
        // Beside the window, the panel reaches over the window's rounded
        // corners to fill what they leave open (SidebarSeam), so it is that
        // much wider.
        let reach = SidebarSeam.reach(for: p, radius: cornerRadius)
        if fresh || panel.attachedSide != attached || panel.reach != reach || panel.radius != cornerRadius || panel.scale != p.scale {
            panel.attach(to: attached, reach: reach, radius: cornerRadius, scale: p.scale)
        }
        let frame = SidebarSeam.panel(for: p, reach: reach)
        // Set first: the move notifications arrive inside setFrame.
        placedPanelFrame = frame
        let was = panel.frame
        // A pure move is cheap; only a real resize lays the tab list out again.
        if panel.frame.size != frame.size {
            panel.setFrame(frame, display: true, animate: false)
        } else if panel.frame.origin != frame.origin {
            panel.setFrameOrigin(frame.origin)
        }
        if DragTrace.enabled, panel.frame != was, !tracker.isDragging(window) {
            DragTrace.log("place: window \(window.number) reported \(window.target.frame), on screen \(WindowServer.frame(window.number).map { "\($0)" } ?? "?"), "
                + "panel asked \(frame) got \(panel.frame), scale \(p.scale), over the window \(reach) pt")
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
        guard let panel, let placed = placedPanelFrame, !SidebarGeometry.same(panel.frame, placed) else { return }
        // macOS moves windows itself when displays change; that is no snap.
        guard Date().timeIntervalSince(sidebar.screensChangedAt) > 1 else { return }
        outsideMove?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.movePairToPanel() } }
        outsideMove = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func movePairToPanel() {
        guard let panel, let placed = placedPanelFrame, !SidebarGeometry.same(panel.frame, placed), !hidden, isShown else { return }
        let inner = SidebarGeometry.windowAfterPanelMoved(from: placed, to: panel.frame, window: window.target.frame, width: width,
                                                          side: placedSide)
        move(to: inner, keep: nil) { [weak self] in self?.remember() }
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
