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

    /// What the panel shows. Set only when it differs (see SidebarLook). The
    /// view is told when it changes (`show`), except for new titles alone.
    private(set) var look = SidebarLook.notConnected
    /// Each shown tab's title, by tab id: its row watches its own, so new
    /// titles redraw those titles and nothing else.
    private var titles: [Int: TabTitle] = [:]
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
        refitWait = nil
        systemSlack = 0
        window.readOwed = false // a window that is gone, or let go, is not read for a slide
        flagWatch = nil
        if closed { slideRun = nil; steps = nil; afterSteps = nil; opening = nil; refitting = nil; closing = nil; stopTicker() } else { giveSpaceBack() }
        releaseFlag()
        panelTokens.forEach(NotificationCenter.default.removeObserver)
        panelTokens = []
        panel?.orderOut(nil)
        panel = nil
        isShown = false
    }

    /// A window of 56 tabs changing their titles brings a new look every 2 s
    /// with another app in front, and every title in it new. Working the
    /// whole sidebar out again for that (every row, folder and Favorite, and
    /// each row's menu) was most of what the app spent: new titles alone go
    /// to the titles' rows (`TabTitle`), and the view is told nothing.
    func show(_ new: SidebarLook) {
        guard new != look else { return }
        let color = new.match?.profile?.color
        if color != look.match?.profile?.color { setTint(color) }
        if !look.differsOnlyInTitles(from: new) { objectWillChange.send() }
        look = new
        var kept: [Int: TabTitle] = [:]
        for t in new.match?.window?.tabs ?? [] {
            guard let title = titles[t.id] else { continue }
            title.set(t.title)
            kept[t.id] = title
        }
        titles = kept
    }

    /// The title a row of this tab shows, kept up to date by `show`. Made
    /// from the newest look, not from `tab`: after new titles alone the view
    /// keeps the tab list it last drew, and a lazy row built later (scrolled
    /// to) is made from that list.
    func title(of tab: BrowserTab) -> TabTitle {
        if let title = titles[tab.id] { return title }
        let title = TabTitle(current(tab).title)
        titles[tab.id] = title
        return title
    }

    /// The tab as the browser last said, its title included: a row's actions
    /// were made when the row was last drawn, which new titles don't do.
    func current(_ tab: BrowserTab) -> BrowserTab {
        look.match?.window?.tabs.first { $0.id == tab.id } ?? tab
    }

    // MARK: - Show and hide: the panel slides over the browser

    /// The shortcut and the menu item: hide the sidebar, the browser taking the
    /// pair's frame, or show it in the browser's frame.
    func toggle() {
        refitWait = nil
        systemSlack = 0
        DragTrace.log("toggle: window \(window.number) hidden \(hidden) -> \(!hidden)")
        if hidden { slideIn() } else { slideOut() }
    }

    /// A slide in progress (Nick's recording of 0.3.34 on macOS 27: Brave
    /// can't repaint its page 60 times a second under a set per frame). The
    /// panel, ordered above the browser, slides over the browser's near edge,
    /// its outer edge still and its inner edge moving at full frame rate,
    /// while the browser stays where it is: the browser is moved under the
    /// panel in one set (`WindowSet`), never frame by frame. A show sends that
    /// set once the panel covers what the browser gives up (`pending`); a hide
    /// sends it first, and slides the panel out only once the browser is
    /// under it at its full frame (`out`, its slide not begun: `slideOutNow`).
    private struct SlideRun {
        var slide: SidebarSlide
        var side: SidebarSide
        var outer: CGFloat
        var hiddenWindow: CGRect
        var shownWindow: CGRect
        /// How much of the sidebar's width the panel covers, shown: what the
        /// browser gives up, as far as is known (`cover(of:)`).
        var cover: CGFloat
        /// Going closed: the panel slides out once the browser's set has landed.
        var out: Bool
        /// A show's set, sent once the panel covers.
        var pending: (() -> Void)?
        /// Going closed: when the browser's calls were over (`slideOutNow`), and
        /// when the window server first showed the window at its frame since.
        /// The panel begins to uncover only once that frame has been on screen
        /// a display frame (`SidebarSlide.landedMargin`), or the wait is capped
        /// (`SidebarSlide.landedWait`).
        var ready: Double?
        var landed: Double?
        var frames = 0, started = CACurrentMediaTime()
    }
    private var slideRun: SlideRun? {
        didSet { if slideRun == nil { quiet(false) } }
    }

    /// The browser on its way somewhere, one Accessibility call at a time
    /// (or a slide-over's one set), each waited for on screen
    /// (`WindowSteps`), and what follows once it is there.
    private var steps: WindowSteps?
    /// The longest a call of the last steps took to land.
    private var lastSlowest = 0.0
    /// The last steps ended at their cap, not where they were going.
    private var lastCapped = false
    /// The last steps ended because the window stopped short (`WindowSteps.stoppedShort`).
    private var lastStoppedShort = false
    /// The last steps were one set that landed at once and whole (`WindowSteps.clean`): no final resend is owed.
    private var lastClean = false
    /// The width this window's browser was seen to stop at when asked
    /// narrower, opening: its minimum as far as anything has shown. It
    /// shapes the next open (`WindowSteps.stops`: a window already that
    /// narrow that doesn't move when asked twice has stopped there, refused
    /// for want of room at once, not at the cap; and the panel covers no
    /// more than it leaves, `cover(of:)`), and never skips asking the
    /// browser. Seen narrower since (the person resized it), it is forgotten.
    private var stops: CGFloat?
    private var afterSteps: (() -> Void)?
    private var ticker: Timer?

    /// The browser's enhanced user interface held off for this window's
    /// motion (`EnhancedUI`), from right before its first set until its
    /// final target has landed; and whether the flag is off now, so its sets
    /// aren't animated by it.
    private var holdsFlag = false
    private(set) var flagOff = false

    /// Holds the flag off, right before a set is sent. Once per motion.
    private func holdFlag() {
        guard !holdsFlag else { return }
        holdsFlag = true
        flagOff = EnhancedUI.shared.hold(window.target.pid, by: self).off
    }

    /// The motion is over: the flag goes back to what it was. `wait`: how
    /// long the call may wait for the browser (quitting has its bound).
    /// Quitting or turning off (`within`): one set back at most, and each
    /// call only when it can end within the bound (`EnhancedUI.release`).
    func releaseFlag(wait: Double = AXWindow.callLimit, within: (() -> Bool)? = nil) {
        guard holdsFlag else { return }
        holdsFlag = false
        if let within {
            EnhancedUI.shared.release(window.target.pid, by: self, wait: wait, retries: 0, sets: within, readsBack: within)
        } else {
            EnhancedUI.shared.release(window.target.pid, by: self, wait: wait)
        }
    }

    /// Released once nothing of this window is moving: no steps, no set
    /// still on the window's queue, no drag of the edge.
    private func releaseFlagIfIdle() {
        // Never while the panel slides: the flag's calls are made on the main thread, and wait for the browser.
        let still = slideRun.map { $0.pending == nil && ($0.slide.phase == .shown || $0.slide.phase == .hidden) } ?? true
        if steps == nil, resizing == nil, flagWatch == nil, !window.handle.sending, still { releaseFlag() }
    }

    /// Calls of betterlink's may still be on their way to the window: its
    /// last steps sent its final target once more and let those calls go
    /// without seeing the window take them (a browser late or busy past the
    /// cap). The flag stays held until the window shows `target`, or
    /// `until`, so a browser that does them late does them as sets that land
    /// at once: with the flag back on, each was animated and cut short by the
    /// next, and a busy browser was left a sidebar's width off its frame.
    /// Nothing is sent meanwhile; a new motion, or someone else's change, ends it.
    private var flagWatch: (target: CGRect, until: Double)?

    private func stepFlagWatch() {
        guard let w = flagWatch, SidebarGeometry.same(onScreenFrame, w.target) || clock() >= w.until else { return }
        flagWatch = nil
        releaseFlagIfIdle()
    }

    /// Reduce Motion, and the clock. Tests set their own and step the slide
    /// and the browser's moves tick by tick (`stepSlide`), as the timer does.
    var reducesMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var clock: () -> CFTimeInterval = CACurrentMediaTime
    /// Whether the person is dragging the window now: the window tracker's
    /// live drag, unless a test sets its own.
    var isDragged: (() -> Bool)?
    /// Waiting on the main thread, for quitting, which has no later.
    var pause: (Double) -> Void = AXWindow.sleep
    /// An open without a slide is under way (a new width, a window followed
    /// or back from full screen): for the guard, which checks the panel is
    /// never shown over the browser then.
    var opensWithoutSlide: Bool { opening != nil && slideRun == nil }
    /// A show or hide is under way, the panel over the browser's near edge
    /// by design: for the guard.
    var slidesOver: Bool { slideRun != nil }

    /// The panel sliding, or the browser being moved.
    var sliding: Bool { slideRun != nil || steps != nil || refitWait != nil || window.handle.sending }
    /// Ticking: sliding, or the flag held for calls that may still land (`flagWatch`), which moves nothing.
    private var ticking: Bool { sliding || flagWatch != nil }

    /// This window's one set was seen partway (`WindowSteps.partway`): its
    /// sets animate, and its next show or hide moves it by `WindowSteps`, one
    /// call at a time, instead of one set (whose second call would cut its
    /// first short). Cleared as soon as a motion's calls land at once. A set
    /// that shows late but whole is no such sign, and nothing is given up for
    /// good (MINI-16, 1df43a3: one late set, and every motion after was the
    /// two steps).
    private var setsSlow = false

    /// The right edge of the displays side by side at `frame`'s height.
    private func rightEdge(of frame: CGRect) -> CGFloat? { SidebarGeometry.span(at: frame, of: Displays.all.map(\.frame))?.upperBound }

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

    /// While the panel slides, the window isn't read through Accessibility
    /// (`TrackedWindow.quiet`): a read waits for the browser, and a browser
    /// laying its page out after a set would hold the slide up. A read owed
    /// meanwhile is made once the panel is still.
    private func quiet(_ q: Bool) {
        guard window.quiet != q else { return }
        window.quiet = q
        guard !q, window.readOwed else { return }
        window.readOwed = false
        window.watcher?.refresh(window)
    }

    /// Moves the browser to `frame`, its far edge (away from `keep`) where
    /// `frame` has it whatever width it takes, then does `then`.
    /// `widest`: opening, the widest the browser may stop at and leave the
    /// sidebar its least width (`WindowSteps.widest`). `deadline`: when a
    /// show or hide is capped (`WindowSteps.cap`); with one, a change by
    /// someone else meanwhile ends it, and `then` is not done: `takenByOther()` is.
    /// `retreats`: false when giving space back (`WindowSteps.retreats`).
    /// `oneSet`: a show or hide under the panel: with nothing of betterlink's
    /// on its way to the window, and its sets landing at once (its enhanced UI
    /// off, and not seen to animate), its size and position go in one set,
    /// back to back (`WindowSet`), and `WindowSteps` watch it land and finish
    /// from there; else the steps move it one call at a time.
    private func move(to frame: CGRect, keep: SidebarSide?, widest: CGFloat? = nil, retreats: Bool = true, patience: Double = WindowSteps.timeout,
                      deadline: Double? = nil, oneSet: Bool = false, then: @escaping () -> Void = {}) {
        // Opening (only an open has `widest`): what this window's browser was seen to stop at.
        let stops = widest == nil ? nil : self.stops
        let earlier = steps
        afterSteps = then
        flagWatch = nil // this motion's own landing decides now
        if oneSet, earlier == nil {
            holdFlag()
            let seen = onScreenFrame
            let calls = WindowSet.calls(from: seen, to: frame, keep: keep, right: rightEdge(of: seen))
            // Where the far edge is kept, or nothing is (a refusal's way back, in `WindowSet`'s order for that): a
            // hide's pair moved back on screen as it closes goes a call at a time, each waited for, so no frame
            // between is further off screen than its ends under an animation.
            let kept = keep.map { abs($0 == .left ? seen.maxX - frame.maxX : seen.minX - frame.minX) < 1 } ?? true
            if flagOff, !setsSlow, kept, let first = calls.first {
                var s = WindowSteps(target: frame, keep: keep, widest: widest, retreats: retreats, deadline: deadline, stops: stops,
                                    sending: calls.count > 1 ? .frame(frame) : first, from: seen, at: clock(),
                                    between: WindowSet.between(from: seen, calls: calls))
                s.patience = patience
                s.slack = systemSlack
                steps = s
                window.handle.send(calls.flatMap { AXWindow.sets($0, of: window.handle) })
                let between = WindowSet.between(from: seen, calls: calls).map { ", between them \($0)" } ?? ""
                DragTrace.log("set: window \(window.number) from \(seen) to \(frame), \(calls)\(between)")
                return runTicker()
            }
        }
        steps = WindowSteps(target: frame, keep: keep, widest: widest, retreats: retreats, deadline: deadline, stops: stops, after: earlier)
        steps?.patience = patience
        steps?.slack = systemSlack
        stepWindow()
        runTicker()
    }

    /// Sends one of the steps' calls on the window's own queue (`WindowHandle.send`).
    private func send(_ call: WindowSteps.Call, keep: SidebarSide?) {
        window.handle.send(AXWindow.sets(call, of: window.handle, keep: keep))
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
        steps?.slack = systemSlack
        afterSteps = then
        stepWindow()
        runTicker()
    }

    /// When a show or a hide begun now is capped.
    private var cap: Double { clock() + WindowSteps.cap }

    private func runTicker() {
        guard ticking, ticker == nil else { return }
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
        stepFlagWatch()
        stepRefitWait()
        stepWindow()
        stepPanel()
        if resizing != nil { follow() } // mid-drag the panel follows the window's real edge, tick by tick
        revealOpening()
        if holdsFlag { releaseFlagIfIdle() } // a set the window's queue answered only now
        if !ticking { stopTicker() }
    }

    /// An open without a slide (a new width, a window followed or back from
    /// full screen): the panel is shown beside the frame the browser was
    /// asked for, and until the browser has made room it is revealed only up
    /// to where the browser really is: a slow or unmoving browser shows no
    /// panel over its content (the guard's panel property, seed 20261126
    /// case 408: a new width's open lay 281 pt over a late browser for over
    /// 0.9 s). Its whole shape, the seam's notches included, once the
    /// browser's edge is at its inner edge. `ordering`: the panel is about to
    /// be ordered in: masked first, so it is never drawn whole over the
    /// browser for a moment (a browser that reads back the size asked before
    /// it takes it has the panel placed beside that frame, over itself).
    private func revealOpening(ordering: Bool = false) {
        guard slideRun == nil, let panel else { return }
        guard opening != nil, panel.isVisible || ordering, let real = AXWindow.shownFrame(of: window.handle) else {
            if panel.reveal != nil { panel.reveal = nil }
            return
        }
        let left = panel.attachedSide == .left
        let edge = left ? real.minX : real.maxX
        let inner = left ? panel.frame.maxX - panel.reach : panel.frame.minX + panel.reach
        let short = left ? edge < inner - 0.5 : edge > inner + 0.5
        if short { if panel.reveal != edge { panel.reveal = edge } } else if panel.reveal != nil { panel.reveal = nil }
    }

    private func stepWindow() {
        guard var s = steps else { return }
        if let call = s.step(seen: onScreenFrame, now: clock()) {
            holdFlag()
            send(call, keep: s.keep)
        }
        guard s.done else { steps = s; return }
        DragTrace.log("steps: window \(window.number) to \(s.target) done at \(onScreenFrame)\(s.capped ? ", capped" : "")\(s.interrupted ? ", interrupted" : "")\(s.stoppedShort ? ", stopped short" : "")\(s.clean ? ", one set" : "")")
        steps = nil
        // One set seen partway: this window's sets animate, and the next show or hide moves it a call at a time.
        // Calls that landed at once since: one set again.
        if s.oneSet { setsSlow = s.partway } else if s.landedAtOnce { setsSlow = false }
        if s.resends, holdsFlag, !s.interrupted, !SidebarGeometry.same(onScreenFrame, s.target) {
            flagWatch = (s.target, clock() + WindowSteps.cap)
            DragTrace.log("enhanced UI: window \(window.number) not at \(s.target) yet: its flag stays held until it is, or \(WindowSteps.cap) s")
        }
        lastSlowest = s.slowest
        lastCapped = s.capped
        lastStoppedShort = s.stoppedShort
        lastClean = s.clean
        let then = afterSteps
        afterSteps = nil
        if s.interrupted { takenByOther() } else { then?() }
        if steps == nil { restFrame = hidden ? nil : onScreenFrame; systemSlack = 0 }
        releaseFlagIfIdle()
    }

    /// Someone else moved or resized the window while betterlink was moving
    /// it (the person, or another app: `WindowSteps.interrupted`, or a move
    /// while the panel slides in before the browser was sent anything):
    /// nothing more is sent, and their frame stands. An open not yet answered
    /// is given up, the sidebar closed; a hide, or a refused open going back,
    /// ends where the window is; an open sidebar stays open beside it (rule 3).
    /// A press held meanwhile goes with it: theirs is the latest word.
    private func takenByOther() {
        DragTrace.log("moved by someone else: window \(window.number) at \(onScreenFrame), left there")
        // Theirs, at rest from here: not weighed later as a resize of the person's (`settle`).
        defer { restFrame = hidden ? nil : onScreenFrame }
        // The refit's slack ends with it (`systemSlack`): someone else's change ends its steps before their end clears it.
        systemSlack = 0
        let giveUp = opening.map { !$0.answered } ?? false
        opening = nil
        refitting = nil
        closing = nil
        steps = nil
        afterSteps = nil
        flagWatch = nil
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

    /// The panel gone at once, mid-slide too. Ordered out first, and only
    /// then its mask lifted for the next show: the mask change is committed
    /// at once (`SidebarPanel.reshape`), so lifted first it drew the whole
    /// panel over the browser until the order-out (Nick on 0.3.27; live on
    /// 3d5c1e4, a 280 pt flash 220 ms after the slide had hidden the panel).
    private func closePanelNow() {
        slideRun = nil
        panel?.hideNow()
        panel?.reveal = nil
        isShown = false
    }

    /// How much of the sidebar's width a show's panel covers: what the
    /// browser will give up of `frame`, as far as is known. All of it, unless
    /// this window's browser was seen to stop at a width (`stops`) that
    /// leaves less: then what that leaves, none at all for a window already
    /// that narrow (the mini at ce5bf39: Brave at its minimum had the
    /// sidebar's list over its left 280 pt). The browser is asked all the
    /// same (`answer()` decides).
    private func cover(of frame: CGRect) -> CGFloat {
        guard let s = stops else { return CGFloat(width) }
        return max(0, min(CGFloat(width), frame.width - s))
    }

    /// Hides (rule 4): the browser takes the pair's frame, read off the screen
    /// now, wherever the two have been moved or resized since, in one set
    /// under the panel, which still covers its near edge; then the panel
    /// slides out and reveals it. Capped (`WindowSteps.cap`); a set that
    /// didn't land at once and whole is ended by sending that frame once more.
    private func slideOut() {
        endResize() // hiding mid-drag: the drag ends here
        hidden = true
        // A refused open still going back: it stays closed once there.
        if restoring != nil { return }
        // In native full screen: nothing is sent now; the space goes back when the window leaves it (`settle`).
        if window.target.fullScreen, paired, !sliding, closedUnderWay == nil { return layout() }
        // An open or a new width still under way: closed in the frame it began in.
        let underWay = closedUnderWay
        opening = nil
        refitting = nil
        let ends = cap
        if var run = slideRun { // turning back mid-show
            run.slide.settle(at: clock())
            let back = run.hiddenWindow
            run.out = true
            if run.pending != nil {
                // Nothing sent yet: the browser is where it was. The panel slides back out from where it is.
                run.pending = nil
                run.slide.hide(at: clock(), reduceMotion: reducesMotion())
                slideRun = run
                return stepPanel()
            }
            // The show's set is out: the browser goes back under the panel first.
            slideRun = run
            closing = back
            return hideSet(to: back, keep: run.side, deadline: ends) { [weak self] in self?.closed(at: back) { self?.slideOutNow() } }
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
        slideRun = SlideRun(slide: SidebarSlide(shown: true), side: side, outer: outer, hiddenWindow: back, shownWindow: b, cover: CGFloat(width), out: true)
        hideSet(to: back, keep: side, deadline: ends) { [weak self] in self?.closed(at: back) { self?.slideOutNow() } }
        stepPanel()
    }

    /// A hide's one set, under the panel (or a show's, turned back once its
    /// set was out): the browser to the pair's frame `back`, its far edge
    /// kept (`WindowSet`). A left sidebar's window too near its screen's
    /// right edge to grow in place is nudged 1 pt past that edge first, so
    /// its size grows it past the edge and its far edge never comes in
    /// (`WindowSet.nudge`); `trace.log` says each time.
    private func hideSet(to back: CGRect, keep: SidebarSide, deadline: Double, then: @escaping () -> Void) {
        let seen = onScreenFrame
        if let d = WindowSet.nudge(from: seen, to: back, keep: keep, right: rightEdge(of: seen)) {
            DragTrace.log(String(format: "hide: window %d against the far screen edge: nudged %.0f pt past it, then sized and placed, its far edge never in", window.number, Double(d)))
        }
        move(to: back, keep: keep, retreats: false, deadline: deadline, oneSet: true, then: then)
    }

    /// The browser is under the panel at its full frame (a hide's or a
    /// refusal's set has landed): the panel slides out. The flag is set back
    /// first, so its calls are made while the panel is still.
    private func slideOutNow() {
        guard var run = slideRun, run.out else { return }
        run.slide.settle(at: clock())
        guard run.slide.phase == .shown else { return }
        releaseFlagIfIdle()
        if run.ready == nil { run.ready = clock() }
        slideRun = run
        stepPanel()
    }

    /// A hide whose calls are over begins to uncover once the window server
    /// has shown the browser at its frame for a display frame: the page
    /// reflowing under the panel is the first thing that changes, and the
    /// panel never uncovers the browser before it is there (MINI-16 at
    /// f11622b: the panel dropped below the sidebar's width from 26 ms before
    /// to 17 ms after the browser's last frame). Not there within
    /// `SidebarSlide.landedWait`: it slides out all the same, and `trace.log` says so.
    private func beginSlideOut(_ run: inout SlideRun, now: Double) {
        guard run.out, run.slide.phase == .shown, let ready = run.ready else { return }
        if SidebarGeometry.same(onScreenFrame, run.hiddenWindow) {
            if run.landed == nil { run.landed = now }
        } else {
            run.landed = nil
        }
        let landed = run.landed.map { now - $0 >= SidebarSlide.landedMargin - 1e-9 } ?? false
        guard landed || now - ready >= SidebarSlide.landedWait - 1e-9 else { return }
        if !landed {
            DragTrace.log(String(format: "hide: window %d not shown at %@ within %.0f ms (at %@): the panel slides out all the same", window.number,
                                 "\(run.hiddenWindow)", SidebarSlide.landedWait * 1000, "\(onScreenFrame)"))
        }
        run.slide.hide(at: now, reduceMotion: reducesMotion())
    }

    /// A hide's calls are over (landed, or capped): its frame sent once more
    /// unless it was one set that landed at once and whole, and the hide is done.
    private func closed(at back: CGRect, then: (() -> Void)? = nil) {
        if lastClean {
            closing = nil
            then?()
            return
        }
        if lastCapped { DragTrace.log("hide: window \(window.number) not at \(back) within \(WindowSteps.cap) s (at \(onScreenFrame)): sent once more") }
        resend(back, watching: !lastCapped) { [weak self] in
            self?.closing = nil
            then?()
        }
    }

    /// Shows (rule 2): the sidebar opens in the browser's frame, the browser
    /// narrowing from that side under the panel, the reverse of a hide.
    private func slideIn() {
        hidden = false
        // A refused open still going back: it opens once there (restored()).
        if restoring != nil { return }
        if var run = slideRun { // turning back mid-hide: open in the frame it was closing to (rule 2)
            run.slide.settle(at: clock())
            closing = nil
            let browser = SidebarGeometry.opened(run.hiddenWindow, width: CGFloat(width), side: run.side)
            let panel = placePanel(placement(beside: browser))
            run.outer = run.side == .left ? panel.frame.minX : panel.frame.maxX
            run.shownWindow = browser
            run.out = false
            let o = Opening(frame: run.hiddenWindow, asked: browser, ends: cap)
            opening = o
            let widest = run.hiddenWindow.width - SidebarGeometry.widths.lowerBound
            let set: () -> Void = { [weak self] in
                self?.move(to: browser, keep: run.side, widest: widest, deadline: o.ends, oneSet: true) { self?.answer() }
            }
            if run.slide.phase == .shown {
                // The panel covers still (the hide's set on its way): the show's set goes now, after it.
                slideRun = run
                return set()
            }
            holdFlag() // at the press, not mid-slide once the panel covers (`releaseFlagIfIdle`)
            run.slide.show(at: clock(), reduceMotion: reducesMotion())
            run.pending = set
            slideRun = run
            return stepPanel()
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
    /// `slide`: the panel slides in over the browser first, and the browser's
    /// set goes once it covers (`stepPanel`).
    private func open(from frame: CGRect, slide: Bool) {
        width = chosenWidth
        let side = sidebar.side
        let browser = SidebarGeometry.opened(frame, width: CGFloat(width), side: side)
        let o = Opening(frame: frame, asked: browser, ends: cap)
        opening = o
        paired = true
        // A panel on screen already (a new width's open, a re-fit): masked to where the browser really is
        // before it is put beside the frame asked, so it never shows over the browser for a moment.
        if let shown = self.panel, shown.isVisible {
            let real = onScreenFrame
            shown.reveal = side == .left ? real.minX : real.maxX
        }
        let panel = placePanel(placement(beside: browser))
        let widest = frame.width - SidebarGeometry.widths.lowerBound
        // A window its browser was seen to stop at already gives up nothing as far as is known: its size alone is
        // asked first (`WindowSteps`), and not moving, it is refused at once; one set's position would move it for nothing.
        let oneSet = slide && cover(of: frame) >= 0.5
        let set: () -> Void = { [weak self] in
            self?.move(to: browser, keep: side, widest: widest, deadline: o.ends, oneSet: oneSet) { self?.answer() }
        }
        guard slide else {
            set()
            return stepPanel()
        }
        // The flag is held off now, before the panel moves: its calls wait for the browser on the main thread, and
        // the show's set goes mid-slide, once the panel covers the strip (`stepPanel`).
        if oneSet { holdFlag() }
        let outer = side == .left ? panel.frame.minX : panel.frame.maxX
        if panel.reveal != outer { panel.reveal = outer }
        panel.showNow(at: place(panel))
        isShown = true
        var run = SlideRun(slide: SidebarSlide(shown: false), side: side, outer: outer, hiddenWindow: frame, shownWindow: browser,
                           cover: cover(of: frame), out: false)
        // Nothing to cover (a window its browser was seen to stop at already): no slide, the browser is asked at once.
        run.slide.show(at: clock(), reduceMotion: reducesMotion() || run.cover < 0.5)
        run.pending = set
        slideRun = run
        quiet(true)
        stepPanel()
        runTicker()
    }

    /// One frame of the panel's slide: its inner edge where the slide has
    /// it, at full frame rate, whatever the browser is doing. A show sends
    /// the browser's set once the panel covers; the run is over once the
    /// panel has slid and the browser is where it was going.
    private func stepPanel() {
        guard var run = slideRun, let panel else { return }
        let now = clock()
        run.slide.settle(at: now) // a slide that is over is shown, or hidden
        // Moved or resized by someone else while the panel slides in, before the browser was sent anything: theirs stands.
        if run.pending != nil, !SidebarGeometry.same(onScreenFrame, run.hiddenWindow) { return takenByOther() }
        // A hide's slide begins only once the browser is under the panel at its full frame, and shown there.
        beginSlideOut(&run, now: now)
        let begun = !run.out || run.slide.phase != .shown
        let done = run.slide.done(at: now)
        // Covering the sidebar's whole width, the panel slides on over the seam (its reach over the window's
        // corners) in the same motion, and shows its whole shape at the end, whatever the browser is doing: the seam
        // drawn over the browser's frame as it is, its set landing beneath it (MINI-16 at f11622b: the reveal held
        // at the strip about 224 ms, until the browser's set had landed, before the seam's 32 columns showed).
        let whole = run.cover >= CGFloat(width) - 0.5
        let extent = run.cover + (whole ? panel.reach : 0)
        var covers = done
        if begun {
            let inner = SidebarSlide.innerEdge(outerEdge: run.outer, width: extent, side: run.side, progress: run.slide.progress(at: now))
            let reveal: CGFloat? = done && whole && run.slide.phase == .shown ? nil : inner
            if panel.reveal != reveal { panel.reveal = reveal }
            if !done { run.frames += 1 }
            covers = covers || abs(inner - run.outer) >= run.cover - 0.5
        }
        quiet(begun && !done)
        // A show's set goes as soon as the panel covers what the browser gives up; the slide goes on meanwhile.
        if covers, !run.out, let set = run.pending {
            run.pending = nil
            slideRun = run
            set()
            guard let r = slideRun else { return }
            run = r
        }
        guard done, begun, run.pending == nil, steps == nil, !window.handle.sending else { slideRun = run; return runTicker() }
        run.slide.settle(at: now)
        slideRun = nil
        finishSlide(run)
    }

    private func finishSlide(_ run: SlideRun) {
        let ms = (CACurrentMediaTime() - run.started) * 1000
        let asked = run.out ? run.hiddenWindow : run.shownWindow
        // What the window did, as the window server shows it, not what was asked.
        let got = onScreenFrame
        DragTrace.log(String(format: "slide %@: %d frames in %.0f ms, window asked %@ got %@ (%@)",
                             run.out ? "out" : "in", run.frames, ms, "\(asked)", "\(got)", SidebarGeometry.same(asked, got) ? "as asked" : "not as asked"))
        if run.out {
            // Ordered out first, then the mask lifted: the whole panel never flashes (`closePanelNow`).
            panel?.hideNow()
            isShown = false
            closing = nil
            unpair()
        }
        panel?.reveal = nil
        if !run.out { follow() }
        layout()
    }

    /// The browser's answer to opening, once its calls have landed: the pair
    /// stays in the frame it opened in (rule 2). The browser keeps its far
    /// edge at the width it really took, and the sidebar has the rest of the
    /// frame. One that took part and stopped is at its minimum, and is never
    /// asked again: if that leaves the sidebar less than its least width, or
    /// the browser took no size at all, or it didn't answer within the cap
    /// (`WindowSteps.cap`), the sidebar closes (`refuse`). Else, unless its
    /// one set landed at once and whole, its frame is sent once more
    /// (`resend`), and the open is over: nothing after it is answered.
    private func answer() {
        guard var o = opening, steps == nil else { return }
        let side = sidebar.side
        let real = onScreenFrame
        // Past the cap: a browser slower than that, or one that never took the size.
        if lastCapped { return refuse(o, real: real, .noSize) }
        // Took part and stopped: as far as it goes. (Not moved at all and taken as stopped, `stops` already says so.)
        if real.width > o.asked.width + 2, abs(real.width - o.frame.width) >= 2 { stops = real.width }
        // Stopped short where it was seen to stop before: no room, though it didn't move.
        if let notice = SidebarNotice.refusal(frame: o.frame, took: real.width) { return refuse(o, real: real, lastStoppedShort ? .noRoom : notice) }
        let room = o.frame.width - real.width
        // Its far edge where it was, at the width it really has.
        var at = real
        at.origin.x = side == .left ? o.frame.maxX - real.width : o.frame.minX
        let w = min(Double(room), Double(SidebarGeometry.widths.upperBound))
        if w != width { width = w }
        if var run = slideRun, run.cover != CGFloat(w) {
            // The panel covers what the browser gave up: no more, no less.
            run.cover = CGFloat(w)
            slideRun = run
            if let panel, panel.isVisible { placePanel(placement(beside: at)) }
        }
        o.answered = true
        if abs(at.minX - real.minX) >= 0.5, !o.corrected {
            o.corrected = true
            opening = o
            move(to: at, keep: side, deadline: o.ends) { [weak self] in self?.answer() }
        } else if lastClean {
            opening = nil
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

    /// The sidebar can't open: it closes as a hide does, the note saying
    /// why shown at once: the window goes back to the frame it had, under the
    /// panel (waited for, then, unless it was one set that landed at once
    /// and whole, sent once more), and the panel slides out; unless someone
    /// else moves it meanwhile (`takenByOther()`). Past the cap, calls of
    /// the open may still be on their way: the frame is sent whole at once
    /// (`resend`), after them.
    private func refuse(_ o: Opening, real: CGRect, _ notice: SidebarNotice) {
        DragTrace.log("open: window \(window.number) took \(Int(real.width)) of \(Int(o.frame.width)) pt\(lastCapped ? " within \(WindowSteps.cap) s" : ""), leaving the sidebar "
                      + "\(Int(o.frame.width - real.width)), less than its least \(Int(SidebarGeometry.widths.lowerBound)): back to \(o.frame), the sidebar closed")
        opening = nil
        hidden = true
        sidebar.refused(self)
        Self.tell(notice, o.frame)
        restoring = o.frame
        if var run = slideRun {
            run.out = true
            run.pending = nil
            slideRun = run
        } else {
            closePanelNow()
            unpair()
        }
        // Watching for someone else's change unless the open's calls, or the way back's, were capped.
        let back: () -> Void = { [weak self] in
            guard let self else { return }
            if self.lastClean, !self.lastCapped { return self.restored(o.frame) }
            self.resend(o.frame, watching: !self.lastCapped) { [weak self] in self?.restored(o.frame) }
        }
        if lastCapped || SidebarGeometry.same(real, o.frame) {
            lastClean = false
            back()
        } else {
            move(to: o.frame, keep: nil, retreats: false, deadline: cap, oneSet: slideRun != nil, then: back)
        }
        layout()
    }

    /// A refused open's window is back: the panel slides out. Pressed again
    /// meanwhile (the last press asked for it open): tried again from there.
    private func restored(_ frame: CGRect) {
        restoring = nil
        guard !hidden else {
            if slideRun != nil { slideOutNow() } else { unpair() }
            return layout()
        }
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
        !sidebar.giveSpaceBack(of: [self], clock: clock, pause: pause).contains(ObjectIdentifier(window.handle))
    }

    /// What giving the space back takes: the move that gives the browser
    /// the pair's frame (rule 4), nil when it has it already with nothing of
    /// betterlink's on its way, or nothing was taken from it. Ends whatever
    /// was under way: the caller makes the move, at once
    /// (`AXWindow.placeNow`), for every window together when betterlink
    /// quits, and then lets the window go (`unpair`) unless its browser
    /// didn't answer. Reads nothing from the browser: a hung one would hold
    /// quitting up. The flag this window's motion held stays held until the
    /// caller is done (`releaseFlag`).
    func spaceBack() -> AXWindow.Move? {
        let underWay = closedUnderWay
        opening = nil
        refitting = nil
        closing = nil
        systemSlack = 0
        let goingBack = restoring // a refused open's window on its way back
        restoring = nil
        let mid = slideRun
        let inFlight = steps
        flagWatch = nil
        window.readOwed = false // quitting reads nothing from the browser: a hung one would hold it up
        slideRun = nil
        steps = nil
        afterSteps = nil
        stopTicker()
        // The sidebar goes: ordered out before its mask is lifted, so it is never drawn whole over the
        // browser, mid-slide too, while the browser is given its space back (`closePanelNow`).
        panel?.hideNow()
        panel?.reveal = nil
        isShown = false
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
        // Hidden while the window was in native full screen: given its space back now it has left it.
        if hidden, paired, !t.fullScreen, !t.minimized, !t.appHidden { return giveBackAfterFullScreen(t) }
        guard !hidden, !t.fullScreen, !t.minimized, !t.appHidden else { return }
        guard paired else {
            // Open since before betterlink last started, and still where it was: narrowed already.
            if let e = sidebar.narrowedBefore(window, at: t.frame) {
                paired = true
                width = min(max(Double(e.outer.width - e.inner.width), Double(SidebarGeometry.widths.lowerBound)),
                            Double(SidebarGeometry.widths.upperBound))
                return layout()
            }
            systemSlack = 0
            open(from: closedUnderWay ?? onScreenFrame, slide: false)
            return layout()
        }
        // Placed anew (both horizontal edges moved, or across a display's whole visible width with its top or bottom
        // on that visible frame's: Window › Fill, a tiling app, a zoom, a full-width pair tiled to the top or bottom
        // half) so that the sidebar would be further off the screen than it was: the browser's new frame is the pair's,
        // and the sidebar slides back on in it (`SidebarGeometry.refitsAfterResize`). A drag of one edge or a corner
        // short of that, and any other resize of theirs, stands.
        // Not at once: macOS's tiling can settle the window a point after it reports it at rest (MINI-16 on macOS 27
        // at 6ebd0da: 1027, then 1028, after the refit had begun, which took it for the person's move). The refit
        // starts once the window server's frame has held still for `refitQuiet`, or at `refitWaitCap` whatever it
        // does (`stepRefitWait`).
        if let was = restFrame, SidebarGeometry.refitsAfterResize(from: was, to: t.frame, width: CGFloat(width), side: placedSide,
                                                                  visible: Displays.all.map(\.visibleFrame)) {
            let now = clock()
            refitWait = RefitWait(was: was, frame: onScreenFrame, since: now, began: now)
            runTicker()
            return layout()
        }
        restFrame = t.frame
        remember()
        layout()
    }

    /// A refit decided at rest, waiting for the window server's frame to hold
    /// still: `was` the frame before the person's change, `frame` where the
    /// window is, unchanged `since`, the wait `began`.
    private struct RefitWait { var was: CGRect; var frame: CGRect; var since: Double; var began: Double }
    private var refitWait: RefitWait?
    /// How long the frame must hold still before a refit starts, and the
    /// longest a refit waits for that (the bound it adds after the window
    /// tracker's rest, itself 150 ms after the last move).
    static let refitQuiet = 0.05
    static let refitWaitCap = 0.15
    /// Set for a refit's motion, cleared once nothing moves the window, when
    /// someone else's change lets it go (`takenByOther`), and as every other
    /// motion begins (a show or hide, a new width, a drag of the edge, a
    /// window followed, given back after full screen or moved with its
    /// panel, letting the window go): how far the system may move the window
    /// on its own meanwhile without it counting as someone else's change
    /// (`WindowSteps.slack`): 2 pt, as frames within 2 pt are the same
    /// (`SidebarGeometry.same`). A bigger change, or any change outside a
    /// refit, is the person's and stands (the review of 33444c7, F1).
    private var systemSlack: CGFloat = 0

    /// A tick of a refit's wait: the frame on screen held still for
    /// `refitQuiet`, or `refitWaitCap` passed: the refit starts from where the
    /// window is, if it still pushes the sidebar off the screen. Not while the
    /// person drags the window, nor minimized, in full screen or with its
    /// app hidden, as `settle` weighs it: the wait ends, and the refit is
    /// weighed again, against the same frame before, once the window comes
    /// to rest (`settle`).
    private func stepRefitWait() {
        guard var w = refitWait else { return }
        let t = window.target
        guard !(isDragged?() ?? tracker.isDragging(window)), !t.fullScreen, !t.minimized, !t.appHidden else {
            refitWait = nil
            return
        }
        let now = clock()
        let seen = onScreenFrame
        if seen != w.frame { w.frame = seen; w.since = now }
        guard now - w.since >= Self.refitQuiet || now - w.began >= Self.refitWaitCap else { refitWait = w; return }
        refitWait = nil
        guard !hidden, paired, SidebarGeometry.refitsAfterResize(from: w.was, to: w.frame, width: CGFloat(width), side: placedSide,
                                                                 visible: Displays.all.map(\.visibleFrame)) else {
            restFrame = w.frame
            return
        }
        DragTrace.log(String(format: "refit: window %d resized from %@ to %@, its sidebar pushed off the screen: opens again in it (held still %.0f ms after %.0f ms)",
                             window.number, "\(w.was)", "\(w.frame)", (now - w.since) * 1000, (now - w.began) * 1000))
        restFrame = nil
        unpair()
        systemSlack = 2
        open(from: w.frame, slide: isShown && panel?.isVisible == true)
        layout()
    }

    /// The browser's frame when it last came to rest with its sidebar open,
    /// or when betterlink last moved it: what a person's resize is weighed
    /// against (`SidebarGeometry.refitsAfterResize`).
    private var restFrame: CGRect?

    /// A hide pressed while the window was in native full screen: nothing
    /// was sent to it then (a window in full screen can't be resized, and
    /// leaving full screen puts back the frame it had). Now it has left, the
    /// browser takes the pair's frame (rule 4).
    private func giveBackAfterFullScreen(_ t: WindowTracker.Target) {
        let back = closedFrame(from: t.frame, side: placedSide)
        systemSlack = 0
        DragTrace.log("hide: window \(window.number) out of full screen, given its space back: \(back)")
        closing = back
        move(to: back, keep: nil, retreats: false, deadline: cap) { [weak self] in self?.closed(at: back) { self?.unpair() } }
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
        systemSlack = 0
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
        systemSlack = 0
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
        restFrame = now
        remember()
        layout()
        releaseFlagIfIdle()
    }

    // MARK: - Layout

    /// Every sidebar to its place: beside its window and among the other
    /// windows, or out of sight. One reading of the window list for them all.
    private func layout() { sidebar.arrange() }

    /// The window moved or resized: the panel stays beside it, on a Space
    /// that isn't showing too.
    func follow() {
        stepFlagWatch() // the window moved: maybe the late calls landed
        trackResize()
        // Narrower than its browser was seen to stop at: that was no minimum.
        if let s = stops, onScreenFrame.width < s - 1 { stops = nil }
        // A single step still open: its answer ends the step.
        if let r = resizing, r.waits, steps == nil, r.drag.answered(r.asked, by: onScreenFrame) { dragEnded() }
        // A slide places the panel itself, frame by frame. Mid-drag, beside
        // the window as it is on screen.
        guard slideRun == nil, panel?.isVisible == true else { return }
        // Masked to where the browser really is before it is moved (`revealOpening`), then after.
        revealOpening()
        placePanel(placement(beside: resizing != nil ? onScreenFrame : window.target.frame))
        revealOpening()
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
            // Masked to where the browser really is before it is moved beside the frame asked (`revealOpening`).
            if self.panel != nil { revealOpening(ordering: true) }
            let panel = placePanel(p)
            if !panel.isVisible { revealOpening(ordering: true) }
            if rehome { panel.reenter(at: place(panel)) } else if reorder, panel.isVisible { panel.order(at: place(panel)) }
            panel.fadeIn(at: place(panel))
        }
        revealOpening()
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
        systemSlack = 0
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

/// One tab's title as its row shows it (`SidebarInstance.title(of:)`).
@MainActor
final class TabTitle: ObservableObject {
    @Published private(set) var text: String
    init(_ text: String) { self.text = text }
    func set(_ new: String) { if new != text { text = new } }
}
