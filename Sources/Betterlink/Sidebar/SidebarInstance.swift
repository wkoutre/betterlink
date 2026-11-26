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
    /// An open being carried out, until its last call (`answer()`): the
    /// frame the pair occupies (the window's with the sidebar closed), what
    /// the browser was asked for, and when the open's cap is reached
    /// (`WindowSteps.cap`, every call of it included).
    private struct Opening {
        var frame: CGRect
        var asked: CGRect
        var ends: Double
        /// The browser has answered and the sidebar stays open: from here a
        /// change by someone else leaves it open beside their frame (rule 3).
        var answered = false
        /// Its far edge was put back once.
        var corrected = false
    }
    private var opening: Opening?
    /// A refused open's window on its way back to the frame it had: a press
    /// meanwhile is held until it is there (the last press wins).
    private var restoring: CGRect?
    /// A new width (`refit`) closing the pair before it opens again: the
    /// frame it is closing to.
    private var refitting: CGRect?
    /// A hide being carried out: the frame it is closing to.
    private var closing: CGRect?

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
        if closed { slideRun = nil; steps = nil; afterSteps = nil; opening = nil; refitting = nil; closing = nil; stopTicker() } else { giveSpaceBack() }
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
    /// The longest a call of the last steps took to land.
    private var lastSlowest = 0.0
    /// The last steps ended at their cap, not where they were going.
    private var lastCapped = false
    private var afterSteps: (() -> Void)?
    private var ticker: Timer?

    /// Reduce Motion, and the clock. Tests set their own and step the slide
    /// and the browser's moves tick by tick (`stepSlide`), as the timer does.
    var reducesMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var clock: () -> CFTimeInterval = CACurrentMediaTime
    /// Waiting on the main thread, for quitting, which has no later.
    var pause: (Double) -> Void = AXWindow.sleep
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

    /// The browser's frame with its sidebar closed while betterlink is still
    /// carrying something out, nil when nothing is (then the pair as it is
    /// on screen decides, rule 4). The browser isn't where it is going yet,
    /// so a frame worked out from where it is would be wrong (review F1: a
    /// hide 50 ms into an open by `settle` widened a 1028 pt window to 1299):
    /// a new width closing the pair (`refit`), an open, or a hide: the frame
    /// it closes to, or opens in (rule 2).
    private var closedUnderWay: CGRect? { refitting ?? opening?.frame ?? closing }

    /// Moves the browser to `frame`, its far edge (away from `keep`) where
    /// `frame` has it whatever width it takes, then does `then`.
    /// `widest`: opening, the widest the browser may stop at and leave the
    /// sidebar its least width (`WindowSteps.widest`). `deadline`: when a
    /// show or hide is capped (`WindowSteps.cap`); with one, a change by
    /// someone else meanwhile ends it, and `then` is not done: `takenByOther()` is.
    /// `retreats`: false when giving space back (`WindowSteps.retreats`).
    private func move(to frame: CGRect, keep: SidebarSide?, widest: CGFloat? = nil, retreats: Bool = true, patience: Double = WindowSteps.timeout,
                      deadline: Double? = nil, then: @escaping () -> Void = {}) {
        steps = WindowSteps(target: frame, keep: keep, widest: widest, retreats: retreats, deadline: deadline, after: steps)
        steps?.patience = patience
        afterSteps = then
        stepWindow()
        runTicker()
    }

    /// The end of a show, a hide or a refusal, or a cap: `frame`, betterlink's
    /// final target for the window, sent once more whole (`WindowSteps.resends`),
    /// after every other call of betterlink's to it, so any of those still on
    /// its way lands before it. From then on whatever the window does is
    /// someone else's, and stands: nothing is sent to it again because it
    /// changed. `watching`: nothing of betterlink's can still be on its way
    /// (the last steps weren't capped, nor a drag's, which lets calls go),
    /// so someone else's change meanwhile ends it as it ends any steps.
    /// `settling`: every size held still before it counts (`WindowSteps.settles`).
    private func resend(_ frame: CGRect, watching: Bool, settling: Bool = false, then: @escaping () -> Void = {}) {
        steps = WindowSteps(target: frame, keep: nil, resends: true, watches: watching, settles: settling)
        afterSteps = then
        stepWindow()
        runTicker()
    }

    /// When a show or a hide begun now is capped.
    private var cap: Double { clock() + WindowSteps.cap }

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
        if resizing != nil { follow() } // mid-drag the panel follows the window's real edge, tick by tick
        if !sliding { stopTicker() }
    }

    private func stepWindow() {
        guard var s = steps else { return }
        if let call = s.step(seen: onScreenFrame, now: clock()) { AXWindow.send(call, to: window.handle) }
        guard s.done else { steps = s; return }
        steps = nil
        lastSlowest = s.slowest
        lastCapped = s.capped
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
        let giveUp = opening.map { !$0.answered } ?? false
        opening = nil
        refitting = nil
        closing = nil
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
    /// now, wherever the two have been moved or resized since. Capped
    /// (`WindowSteps.cap`), and ended by sending that frame once more.
    private func slideOut() {
        endResize() // hiding mid-drag: the drag ends here
        hidden = true
        // A refused open still going back: it stays closed once there.
        if restoring != nil { return }
        // An open or a new width still under way: closed in the frame it began in.
        let underWay = closedUnderWay
        opening = nil
        refitting = nil
        let ends = cap
        if var run = slideRun { // turning back mid-show
            run.slide.hide(at: clock(), reduceMotion: reducesMotion())
            slideRun = run
            let back = run.hiddenWindow
            closing = back
            return move(to: back, keep: run.side, retreats: false, deadline: ends) { [weak self] in self?.closed(at: back) }
        }
        guard paired else { return layout() }
        // Out of sight (another Space, minimized): no slide to watch.
        guard isShown, let panel, panel.isVisible else {
            let back = underWay ?? closedFrame(from: onScreenFrame, side: placedSide)
            closing = back
            move(to: back, keep: nil, retreats: false, deadline: ends) { [weak self] in self?.closed(at: back) { self?.unpair() } }
            return layout()
        }
        let side = panel.attachedSide
        let b = onScreenFrame
        let back = underWay ?? closedFrame(from: b, side: side)
        closing = back
        let outer = side == .left ? panel.frame.minX : panel.frame.maxX
        var run = SlideRun(slide: SidebarSlide(shown: true), side: side, outer: outer, hiddenWindow: back, shownWindow: b)
        run.slide.hide(at: clock(), reduceMotion: reducesMotion())
        slideRun = run
        move(to: back, keep: side, retreats: false, deadline: ends) { [weak self] in self?.closed(at: back) }
        stepPanel()
    }

    /// A hide's calls are over (landed, or capped): its frame sent once more, and the hide is done.
    private func closed(at back: CGRect, then: (() -> Void)? = nil) {
        if lastCapped { DragTrace.log("hide: window \(window.number) not at \(back) within \(WindowSteps.cap) s (at \(onScreenFrame)): sent once more") }
        resend(back, watching: !lastCapped) { [weak self] in
            self?.closing = nil
            then?()
        }
    }

    /// Shows (rule 2): the sidebar opens in the browser's frame, the browser
    /// narrowing from that side, the reverse of a hide.
    private func slideIn() {
        hidden = false
        // A refused open still going back: it opens once there (restored()).
        if restoring != nil { return }
        if var run = slideRun { // turning back mid-hide: open in the frame it was closing to (rule 2)
            closing = nil
            let browser = SidebarGeometry.opened(run.hiddenWindow, width: CGFloat(width), side: run.side)
            let panel = placePanel(placement(beside: browser))
            run.outer = run.side == .left ? panel.frame.minX : panel.frame.maxX
            run.shownWindow = browser
            run.slide.show(at: clock(), reduceMotion: reducesMotion())
            slideRun = run
            let o = Opening(frame: run.hiddenWindow, asked: browser, ends: cap)
            opening = o
            return move(to: browser, keep: run.side, widest: run.hiddenWindow.width - SidebarGeometry.widths.lowerBound, deadline: o.ends) { [weak self] in
                self?.answer()
            }
        }
        let t = window.target
        // Out of sight (another Space, minimized, full screen): it opens
        // without a slide, where that applies, and shows when its window does.
        guard !t.fullScreen, !t.minimized, !t.appHidden, sidebar.isOnScreen(window) else { settle(t); layout(); return }
        let from = closedUnderWay ?? onScreenFrame
        closing = nil
        open(from: from, slide: true)
        layout() // the list is on screen, and kept to the moment, from the first frame of the slide
    }

    /// Opens the sidebar in `frame`, the browser's frame with it closed: the
    /// browser is asked for the frame less the sidebar's width, its far edge
    /// kept. What it really takes decides the sidebar's width (`answer()`).
    private func open(from frame: CGRect, slide: Bool) {
        width = chosenWidth
        let side = sidebar.side
        let browser = SidebarGeometry.opened(frame, width: CGFloat(width), side: side)
        let o = Opening(frame: frame, asked: browser, ends: cap)
        opening = o
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
        move(to: browser, keep: side, widest: frame.width - SidebarGeometry.widths.lowerBound, deadline: o.ends) { [weak self] in self?.answer() }
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

    /// The browser's answer to opening, once its calls have landed: the pair
    /// stays in the frame it opened in (rule 2). The browser keeps its far
    /// edge at the width it really took, and the sidebar has the rest of the
    /// frame. One that took part and stopped is at its minimum, and is never
    /// asked again: if that leaves the sidebar less than its least width, or
    /// the browser took no size at all, or it didn't answer within the cap
    /// (`WindowSteps.cap`), the sidebar stays closed at once and the window
    /// goes back to its exact frame (`refuse`). Else its frame is sent once
    /// more (`resend`), and the open is over: nothing after it is answered.
    private func answer() {
        guard var o = opening, steps == nil else { return }
        let side = sidebar.side
        let real = onScreenFrame
        // Past the cap: a browser slower than that, or one that never took the size.
        if lastCapped { return refuse(o, real: real, .noSize) }
        if let notice = SidebarNotice.refusal(frame: o.frame, took: real.width) { return refuse(o, real: real, notice) }
        let room = o.frame.width - real.width
        // Its far edge where it was, at the width it really has.
        var at = real
        at.origin.x = side == .left ? o.frame.maxX - real.width : o.frame.minX
        let w = min(Double(room), Double(SidebarGeometry.widths.upperBound))
        if w != width { width = w }
        o.answered = true
        if abs(at.minX - real.minX) >= 0.5, !o.corrected {
            o.corrected = true
            opening = o
            move(to: at, keep: side, deadline: o.ends) { [weak self] in self?.answer() }
        } else {
            opening = o
            resend(at, watching: true) { [weak self] in
                guard let self else { return }
                self.opening = nil
                self.remember()
                self.follow()
            }
        }
        remember()
        follow()
    }

    /// The sidebar can't open: closed at once, the note saying why shown, and
    /// the window put back to the frame it had (waited for, one call at a
    /// time, then sent once more), unless someone else moves it meanwhile
    /// (`takenByOther()`). Past the cap, calls of the open may still be on
    /// their way: the frame is sent whole at once (`resend`), after them.
    private func refuse(_ o: Opening, real: CGRect, _ notice: SidebarNotice) {
        DragTrace.log("open: window \(window.number) took \(Int(real.width)) of \(Int(o.frame.width)) pt\(lastCapped ? " within \(WindowSteps.cap) s" : ""), leaving the sidebar "
                      + "\(Int(o.frame.width - real.width)), less than its least \(Int(SidebarGeometry.widths.lowerBound)): back to \(o.frame), the sidebar closed")
        opening = nil
        hidden = true
        sidebar.refused(self)
        closePanelNow()
        unpair()
        Self.tell(notice, o.frame)
        restoring = o.frame
        // Watching for someone else's change unless the open's calls, or the way back's, were capped.
        let back: () -> Void = { [weak self] in
            guard let self else { return }
            self.resend(o.frame, watching: !self.lastCapped) { [weak self] in self?.restored(o.frame) }
        }
        if lastCapped || SidebarGeometry.same(real, o.frame) { back() } else { move(to: o.frame, keep: nil, retreats: false, deadline: cap, then: back) }
        layout()
    }

    /// A refused open's window is back. Pressed again meanwhile (the last
    /// press asked for it open): tried again from there.
    private func restored(_ frame: CGRect) {
        restoring = nil
        guard !hidden else { return layout() }
        hidden = true
        slideIn()
    }

    /// Records where the open pair is, for a relaunch.
    private func remember() {
        guard paired else { return }
        let b = window.target.frame
        sidebar.paired(window, browser: b, pair: closedUnderWay ?? closedFrame(from: b, side: placedSide))
    }

    /// Its browser missed a call while every window was given back (quitting,
    /// the sidebar turned off): nothing more is sent to it, not even when it
    /// is let go, and its record is kept, so it is recognised later instead
    /// of narrowed again.
    func letAlone() { paired = false }

    func unpair() {
        guard paired else { return }
        paired = false
        sidebar.unpaired(window)
    }

    /// The browser takes the pair's frame (rule 4) at once, without a slide:
    /// the sidebar is turned off, its browser no longer attached, or the app
    /// quits. False when its browser didn't answer in time: then the window
    /// keeps its record, so it is recognised later instead of narrowed again.
    @discardableResult
    func giveSpaceBack() -> Bool {
        let missed = spaceBack().map { AXWindow.placeNow([$0], clock: clock, pause: pause) } ?? []
        let answered = missed.isEmpty
        if answered { unpair() }
        return answered
    }

    /// What giving the space back takes: the move that gives the browser
    /// the pair's frame (rule 4), nil when it has it already with nothing of
    /// betterlink's on its way, or nothing was taken from it. Ends whatever
    /// was under way: the caller makes the move, at once
    /// (`AXWindow.placeNow`), for every window together when betterlink
    /// quits, and then lets the window go (`unpair`) unless its browser
    /// didn't answer. Reads nothing from the browser: a hung one would hold
    /// quitting up.
    func spaceBack() -> AXWindow.Move? {
        let underWay = closedUnderWay
        opening = nil
        refitting = nil
        closing = nil
        let goingBack = restoring // a refused open's window on its way back
        restoring = nil
        let mid = slideRun
        let inFlight = steps
        slideRun = nil
        steps = nil
        afterSteps = nil
        stopTicker()
        panel?.reveal = nil
        // Mid-slide, the slide's closed frame; an open, a new width or a hide
        // under way, the frame it began in (review F1).
        let back = goingBack ?? mid?.hiddenWindow ?? underWay ?? (paired ? closedFrame(from: onScreenFrame, side: placedSide) : nil)
        guard let back, inFlight != nil || !SidebarGeometry.same(back, onScreenFrame) else { return nil }
        return AXWindow.Move(window: window.handle, frame: back, pid: window.target.pid, after: inFlight)
    }

    /// The display most of `frame` is on.
    private func display(for frame: CGRect) -> Display? { Displays.display(for: frame) }

    /// The window came to rest. Open: the person's moves and resizes stand
    /// (rule 3). Shown but not yet narrowed for it (a window just followed,
    /// or back from full screen): it opens. Nothing else: a window at rest
    /// is never moved because it changed.
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
        guard paired else {
            // Open since before betterlink last started, and still where it was: narrowed already.
            if let e = sidebar.narrowedBefore(window, at: t.frame) {
                paired = true
                width = min(max(Double(e.outer.width - e.inner.width), Double(SidebarGeometry.widths.lowerBound)),
                            Double(SidebarGeometry.widths.upperBound))
                return layout()
            }
            open(from: closedUnderWay ?? onScreenFrame, slide: false)
            return layout()
        }
        remember()
        layout()
    }

    /// The side or width changed: closed and opened again, without a slide.
    /// While it closes, the frame it closes to is the pair's (`refitting`):
    /// a hide, a quit or a press meanwhile closes there too (review F1). A
    /// browser that doesn't close within the cap stays closed in the pair's
    /// frame, with the note, as a refused open does.
    func refit() {
        guard paired, !hidden, !sliding else { return }
        let back = closedUnderWay ?? closedFrame(from: onScreenFrame, side: placedSide)
        opening = nil
        refitting = back
        move(to: back, keep: nil, retreats: false, deadline: cap) { [weak self] in
            guard let self else { return }
            guard self.lastCapped else { return self.refitted(back) }
            DragTrace.log("width: window \(self.window.number) not closed to \(back) within \(WindowSteps.cap) s: stays closed")
            self.hidden = true
            self.sidebar.refused(self)
            self.closePanelNow()
            self.unpair()
            Self.tell(.noSize, back)
            self.resend(back, watching: false) { [weak self] in self?.refitting = nil }
            self.layout()
        }
    }

    /// A new width's close is done, the window in the pair's frame: it
    /// opens again there.
    private func refitted(_ back: CGRect) {
        refitting = nil
        unpair()
        open(from: back, slide: false)
        layout()
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
    /// window is asked to make room, by the same one-call-at-a-time steps as
    /// a show (`WindowSteps`, its far edge kept): at most one call is out to
    /// the browser, the pointer's latest width is what the next call asks,
    /// and the next goes only once the window server shows the last landed.
    /// The sidebar is as wide as the room the window has really made (read
    /// off the screen, not Accessibility, which on macOS 27 reads back a size
    /// before it is on screen). On macOS 26 each call lands at once and the
    /// drag is live; on macOS 27 the window trails by its animation, and never
    /// cuts one short into a frame nobody asked for.
    private struct Resize {
        var drag: EdgeDrag
        /// How much wider than at the start the pointer wants the sidebar.
        var delta: CGFloat = 0
        /// The frame the pointer wants the window at now: the latest wins.
        var asked: CGRect
        /// The frame the steps out (or last run) are for.
        var ran: CGRect?
        /// A single step, open until its window answers (nudge(by:)).
        var waits = false
        /// The button is up: once the window has landed, it is checked (once
        /// more for what is missing, as a show is) and the drag ends.
        var ending = false
        var checked = false
        var resent = false
        var rechecked = false
        /// The widest it went when asked wider, this drag: a screen's edge stops
        /// it there. The narrowest it went when asked narrower: its minimum,
        /// for this drag only (it may have stopped only for a moment).
        var most: CGFloat?
        var least: CGFloat?
        /// The longest a call has taken to land, this drag: a call that
        /// changes nothing is waited for three times that (at least 0.15 s),
        /// not the full timeout, since the pointer's next width comes anyway
        /// and the end is checked.
        var slowest: Double?
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
        let t = onScreenFrame
        resizing = Resize(drag: EdgeDrag(window: t, width: width, side: placedSide), asked: t)
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
            }
            // Over: the button is up, or something else ended the resize.
            guard self.resizing == nil || NSEvent.pressedMouseButtons & 1 == 0 else { return }
            self.edgeTimer?.invalidate()
            self.edgeTimer = nil
            self.dragEnded()
            self.returnFocusToBrowser()
        }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in MainActor.assumeIsolated { step() } }
        RunLoop.main.add(t, forMode: .common)
        edgeTimer = t
    }

    /// The pointer wants the sidebar `delta` points wider than when the drag
    /// began. The window is asked for that room as soon as its last call has
    /// landed; the sidebar takes what the window has made (follow()).
    func resize(by delta: CGFloat) {
        guard var r = resizing, !r.ending else { return }
        r.delta = delta
        if browserAnswers, let ask = r.drag.ask(delta: delta) { r.asked = within(ask, r) }
        resizing = r
        stepResize()
        follow()
    }

    /// `ask`, never narrower than this browser has shown it goes, nor wider
    /// than it went this drag, its far edge where the drag keeps it: each ask
    /// past them would change nothing, and be waited out.
    private func within(_ ask: CGRect, _ r: Resize) -> CGRect {
        var w = ask.width
        if let least = r.least, w < least - 0.5 { w = least }
        if let most = r.most, w > most + 0.5 { w = most }
        guard w != ask.width else { return ask }
        var a = ask
        a.size.width = w
        a.origin.x = r.drag.side == .left ? ask.maxX - w : ask.minX
        return a
    }

    /// The window's next steps toward the width the pointer wants now, once
    /// nothing is out; and, the button up and the window landed, the check
    /// and the end.
    private func stepResize() {
        guard var r = resizing, steps == nil else { return }
        guard browserAnswers else { return r.ending ? endResize() : () }
        let real = onScreenFrame
        if r.ran != nil, lastSlowest > 0 { r.slowest = max(r.slowest ?? 0, lastSlowest); resizing = r }
        // The last steps asked it narrower than it went: that is its minimum.
        // Wider: that is as far as it goes from here, this drag.
        if let ran = r.ran, abs(ran.width - real.width) >= 2 {
            if ran.width < real.width { r.least = real.width } else { r.most = real.width }
            r.asked = within(r.asked, r)
            resizing = r
        }
        if r.ran != r.asked, !SidebarGeometry.same(onScreenFrame, r.asked) {
            r.ran = r.asked
            resizing = r
            let patience = r.slowest.map { min(WindowSteps.timeout, max(0.15, 3 * $0)) } ?? WindowSteps.timeout
            return move(to: r.asked, keep: r.drag.side, patience: patience) { [weak self] in self?.stepResize() }
        }
        guard r.ending else { return }
        // Landed. Its far edge not where the drag keeps it (a call dropped, or
        // put back by another app): asked once more, as a show is.
        if !r.checked, let at = r.drag.kept(onScreenFrame) {
            r.checked = true
            resizing = r
            return move(to: at, keep: r.drag.side) { [weak self] in self?.stepResize() }
        }
        // The drag's frame, sent once more: a call it stopped waiting for lands before it (`resend`).
        guard r.resent else {
            r.resent = true
            resizing = r
            return resend(onScreenFrame, watching: false, settling: true) { [weak self] in self?.stepResize() }
        }
        // Its far edge moved meanwhile (a browser that widened itself back to its minimum): checked and sent once more again.
        if !r.rechecked, r.drag.kept(onScreenFrame) != nil {
            r.rechecked = true
            r.checked = false
            r.resent = false
            resizing = r
            return stepResize()
        }
        endResize()
    }

    /// The button is up (or a single step's wait is over): the drag ends once
    /// the window has landed where it was last asked, and has been checked.
    func dragEnded() {
        stepEnd?.cancel()
        stepEnd = nil
        guard var r = resizing else { return }
        r.ending = true
        r.waits = false
        resizing = r
        stepResize()
    }

    /// Mid-drag the sidebar is as wide as the room the window has made.
    private func trackResize() {
        guard let r = resizing else { return }
        let w = Double(r.drag.width(delta: r.delta, beside: onScreenFrame))
        if w != width { width = w }
    }

    /// One step without a pointer (the edge's adjustable action: VoiceOver,
    /// the keyboard). There is no button to come up, so the resize stays open
    /// until the window has answered (follow()), or `EdgeDrag.answerWait` has
    /// passed, and then ends as a drag does. A step taken while the last one
    /// is still open, waiting or ending with a call out (key repeat,
    /// VoiceOver's increments), adds to the width last asked, and the wait
    /// starts again.
    func nudge(by step: CGFloat) {
        guard edgeTimer == nil else { return }
        if var open = resizing {
            // Still open (its window not answered yet, or ending while a call
            // is out): the step adds to the width last asked, never to the
            // window's width mid-call, and none is lost.
            open.ending = false
            open.checked = false
            open.resent = false
            open.rechecked = false
            resizing = open
        } else if !beginResize() {
            return
        }
        guard let open = resizing else { return }
        resize(by: open.drag.stepped(open.delta, by: step))
        guard let r = resizing else { return }
        if steps == nil, r.drag.answered(r.asked, by: onScreenFrame) { return dragEnded() }
        resizing?.waits = true
        stepEnd?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.dragEnded() } }
        stepEnd = work
        DispatchQueue.main.asyncAfter(deadline: .now() + EdgeDrag.answerWait, execute: work)
    }

    /// Ends the resize now, with the window as it is on screen: the width
    /// saved is the room it really made. A browser that has stopped answering
    /// is taken as last seen.
    func endResize() {
        stepEnd?.cancel()
        stepEnd = nil
        guard let r = resizing else { return }
        if browserAnswers { window.watcher?.refresh(window) }
        trackResize()
        resizing = nil
        chosenWidth = width
        sidebar.widthChosen(width, for: self)
        let now = onScreenFrame
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
        trackResize()
        // A single step still open: its answer ends the step.
        if let r = resizing, r.waits, steps == nil, r.drag.answered(r.asked, by: onScreenFrame) { dragEnded() }
        // A slide places the panel itself, frame by frame. Mid-drag, beside
        // the window as it is on screen.
        guard slideRun == nil, panel?.isVisible == true else { return }
        placePanel(placement(beside: resizing != nil ? onScreenFrame : window.target.frame))
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
        move(to: inner, keep: nil, deadline: cap) { [weak self] in self?.remember() }
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
