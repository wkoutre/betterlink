import AppKit
import BetterlinkCore
import TabSyncCore
import Testing
@testable import Betterlink

/// A browser window as macOS and a browser treat the sidebar's requests: the
/// position and the size are separate calls in Accessibility's coordinates,
/// and macOS limits each size to what fits on the display the window is on at
/// that moment. A move is not limited, so a window can be pushed past a
/// display's edge, as a person can drag one there.
@MainActor
final class FakeBrowser: WindowHandle {
    enum Resize: CustomStringConvertible {
        /// Takes every size at once.
        case applies
        /// Moves, but keeps its size.
        case refuses
        /// Moves at once; each size only when it answers (`answer()`).
        case late
        /// Busy: takes nothing until it answers, then everything in order,
        /// and its frame can't be read meanwhile (Accessibility times out).
        case busy

        var description: String {
            switch self {
            case .applies: "applies"
            case .refuses: "refuses resize"
            case .late: "resizes late"
            case .busy: "busy"
            }
        }
    }

    private(set) var frame: CGRect
    var resize: Resize
    var minWidth: CGFloat
    /// Takes any size it is given, then widens itself back to `minWidth`
    /// (keeping its top left) when it answers, instead of stopping there.
    var widensLater = false
    /// A tiling app that puts the window back on this frame once, after the
    /// sidebar has changed it.
    var tiler: CGRect?
    var onScreen = true
    /// Every frame it has had, in order.
    private(set) var history: [CGRect]
    private var queued: [(size: CGSize?, position: CGPoint?)] = []

    init(frame: CGRect, resize: Resize, minWidth: CGFloat) {
        self.frame = frame
        self.resize = resize
        self.minWidth = minWidth
        history = [frame]
    }

    private var height: CGFloat { Displays.primaryHeight! }

    func position() -> CGPoint? {
        resize == .busy && !queued.isEmpty ? nil : CGPoint(x: frame.minX, y: height - frame.maxY)
    }

    func size() -> CGSize? { resize == .busy && !queued.isEmpty ? nil : frame.size }

    func setPosition(_ p: CGPoint) {
        if resize == .busy { return queued.append((nil, p)) }
        move(to: p)
    }

    func setSize(_ s: CGSize) {
        switch resize {
        case .applies: apply(s)
        case .refuses: break
        case .late, .busy: queued.append((s, nil))
        }
    }

    func shownBounds() -> CGRect? { CGRect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height) }

    var isOnScreen: Bool { onScreen }

    /// What it does once it gets to them: the sizes still to take, then a
    /// tiling app's one put-back. True when the frame changed.
    @discardableResult
    func answer() -> Bool {
        let was = frame
        let todo = queued
        queued = []
        for q in todo {
            if let s = q.size { apply(s) }
            if let p = q.position { move(to: p) }
        }
        if widensLater, frame.width < minWidth - 0.5 {
            set(CGRect(x: frame.minX, y: frame.minY, width: minWidth, height: frame.height))
        }
        if let t = tiler, frame != t, history.count > 1 {
            tiler = nil
            set(t)
        }
        return frame != was
    }

    private func move(to p: CGPoint) {
        set(CGRect(x: p.x, y: height - p.y - frame.height, width: frame.width, height: frame.height))
    }

    /// The top left stays; the size is limited to what fits on the display
    /// the window is on now, and to the browser's minimum width.
    private func apply(_ s: CGSize) {
        let d = (Displays.all.max { $0.frame.intersection(frame).area < $1.frame.intersection(frame).area } ?? Displays.all[0]).frame
        let least = widensLater ? 0 : minWidth
        let w = max(least, min(s.width, max(d.maxX - frame.minX, least)))
        let h = min(s.height, frame.maxY - d.minY)
        set(CGRect(x: frame.minX, y: frame.maxY - h, width: w, height: h))
    }

    private func set(_ f: CGRect) {
        guard f != frame else { return }
        frame = f
        history.append(f)
    }
}

/// One sidebar on one fake browser window, driven through the app's own
/// show and hide: SidebarController.toggle, SidebarInstance's slide frame by
/// frame, the window tracker's settle once the window rests.
@MainActor
final class SidebarRig {
    let fake: FakeBrowser
    let window: TrackedWindow
    let instance: SidebarInstance
    private let watcher: BrowserWatcher
    private var time: CFTimeInterval = 1000
    private(set) var slideFrames = 0

    private static var nextNumber: CGWindowID = 4_000_000

    init(displays: [Display], frame: CGRect, side: SidebarSide, width: Double = 280,
         resize: FakeBrowser.Resize = .applies, minWidth: CGFloat = 0, widensLater: Bool = false, tiler: Bool = false,
         reduceMotion: Bool = false) {
        Displays.source = { displays }
        SidebarPanel.headless = true
        _ = NSApplication.shared
        let controller = SidebarController.shared
        if controller.side != side { controller.side = side }
        fake = FakeBrowser(frame: frame, resize: resize, minWidth: minWidth)
        fake.widensLater = widensLater
        if tiler { fake.tiler = frame }
        watcher = BrowserWatcher(.current, tracker: controller.tracker)
        Self.nextNumber += 1
        window = TrackedWindow(element: AXUIElementCreateApplication(getpid()), number: Self.nextNumber, watcher: watcher, handle: fake)
        window.read()
        instance = SidebarInstance(window: window, sidebar: controller, hidden: true, width: width)
        instance.clock = { [unowned self] in self.time }
        instance.reducesMotion = { reduceMotion }
    }

    /// The shortcut: the slide to its end, then the window comes to rest.
    func toggle() {
        SidebarController.shared.toggle(instance)
        var frames = 0
        while instance.sliding, frames < 1000 {
            time += 1.0 / 120
            instance.stepSlide()
            // Each move the browser makes is an Accessibility event: the window is read again (BrowserWatcher.refresh).
            watcher.refresh(window)
            instance.follow()
            frames += 1
        }
        slideFrames = frames
        rest()
    }

    /// The browser answers what it was asked, a tiling app does its part, and
    /// the window tracker reports the window at rest, until nothing changes.
    func rest() {
        for _ in 0..<6 {
            let changed = fake.answer()
            watcher.refresh(window)
            instance.follow() // as SidebarController.changed does: the panel goes with its window
            instance.settle(window.target)
            if !changed { break }
        }
    }
}

/// The sidebar's show and hide, end to end, against fake browser windows on
/// fake displays: showing narrows the window by the sidebar's width and keeps
/// its far edge where it was; hiding gives back exactly the frame it had. A
/// window that won't narrow is never pushed off its display, and is back where
/// it was after hiding. PR 72's tests checked the geometry and the loan as pure
/// functions; these drive the code that moves the window.
@MainActor @Suite(.serialized) struct SidebarGuardTests {
    init() throws {
        let home = TestHome.folder
        try #require(SettingsFolder.resolve().directory.path == home.path)
        try #require(MenuBarIcon.defaults() !== UserDefaults.standard)
    }

    // MARK: Displays

    /// A laptop's display: menu bar on top, the Dock at the bottom.
    static let laptop = Display(frame: CGRect(x: 0, y: 0, width: 2056, height: 1259),
                                visibleFrame: CGRect(x: 0, y: 64, width: 2056, height: 1259 - 64 - 37))
    static func external(_ frame: CGRect) -> Display {
        Display(frame: frame, visibleFrame: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height - 25))
    }

    struct Arrangement: CustomStringConvertible {
        var name: String
        var displays: [Display]
        var description: String { name }
    }

    /// A MacBook's built-in display alone, in one of its scaled modes: a
    /// notched menu bar (38 pt), the Dock at the bottom (`dock` pt; an
    /// autohidden Dock still keeps 4).
    static func builtIn(_ w: CGFloat, _ h: CGFloat, dock: CGFloat) -> Arrangement {
        .init(name: "built-in \(Int(w))x\(Int(h)), Dock \(Int(dock))",
              displays: [Display(frame: CGRect(x: 0, y: 0, width: w, height: h),
                                 visibleFrame: CGRect(x: 0, y: dock, width: w, height: h - dock - 38))])
    }

    static let arrangements: [Arrangement] = [
        // The owner's 16-inch MacBook Pro: no external display.
        builtIn(1728, 1117, dock: 70), builtIn(1728, 1117, dock: 4),
        builtIn(1496, 967, dock: 70), builtIn(2056, 1329, dock: 70), builtIn(2056, 1329, dock: 4),
        .init(name: "one display", displays: [laptop]),
        .init(name: "second to the right", displays: [laptop, external(CGRect(x: 2056, y: 0, width: 2560, height: 1440))]),
        .init(name: "second to the left", displays: [laptop, external(CGRect(x: -2560, y: -181, width: 2560, height: 1440))]),
        .init(name: "second above", displays: [laptop, external(CGRect(x: -252, y: 1259, width: 2560, height: 1440))]),
        // Another size and scale: a 1x display of fewer points, its top aligned.
        .init(name: "smaller second to the right", displays: [laptop, external(CGRect(x: 2056, y: 179, width: 1920, height: 1080))]),
        // The external display is the primary one (it has the menu bar), the laptop beside it.
        .init(name: "laptop second, external primary", displays: [
            external(CGRect(x: 0, y: 0, width: 2560, height: 1440)),
            Display(frame: CGRect(x: 2560, y: 0, width: 2056, height: 1259),
                    visibleFrame: CGRect(x: 2560, y: 64, width: 2056, height: 1259 - 64 - 25)),
        ]),
    ]

    enum Tile: CaseIterable, CustomStringConvertible {
        case fill, byHand, leftHalf, rightHalf
        var description: String {
            switch self {
            case .fill: "filling the display"
            case .byHand: "dragged to fill it, over the Dock"
            case .leftHalf: "left half"
            case .rightHalf: "right half"
            }
        }
        func frame(on d: Display) -> CGRect {
            let v = d.visibleFrame
            switch self {
            case .fill: return v
            // From under the menu bar to the display's bottom edge, a point short of each side.
            case .byHand: return CGRect(x: v.minX + 1, y: d.frame.minY, width: v.width - 2, height: v.maxY - d.frame.minY)
            case .leftHalf: return CGRect(x: v.minX, y: v.minY, width: (v.width / 2).rounded(), height: v.height)
            case .rightHalf: return CGRect(x: v.minX + (v.width / 2).rounded(), y: v.minY, width: v.width - (v.width / 2).rounded(), height: v.height)
            }
        }
    }

    struct Case: CustomStringConvertible {
        var arrangement: Arrangement
        var display: Int
        var tile: Tile
        var side: SidebarSide
        var description: String { "\(arrangement), window on display \(display + 1), \(tile), sidebar \(side)" }
    }

    static let cases: [Case] = arrangements.flatMap { a in
        a.displays.indices.flatMap { d in
            Tile.allCases.flatMap { tile in SidebarSide.allCases.map { Case(arrangement: a, display: d, tile: tile, side: $0) } }
        }
    }

    // MARK: Checks

    private static func same(_ a: CGRect, _ b: CGRect) -> Bool { WidthLoan.same(a, b) }

    /// Shown: the window narrowed by the sidebar's width on the sidebar's
    /// side, its far edge where it was. A window that can't give all of it
    /// (narrower than the browser's minimum, or the 500 pt the sidebar asks
    /// no browser to go below) stops at that width, on its display, with the
    /// sidebar's room beside it on the display: its far edge stays where it
    /// was, unless that would put the sidebar off the display, and then the
    /// pair is flush with the display's edge.
    private func expectNarrowed(_ rig: SidebarRig, from start: CGRect, side: SidebarSide, width: CGFloat, on d: Display,
                                minWidth: CGFloat = 0, _ c: Case, _ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let now = rig.fake.frame
        let floor = max(500, minWidth)
        var want = start
        want.size.width = max(start.width - width, min(floor, start.width))
        if side == .left { want.origin.x = start.maxX - want.width } // the far edge kept
        let v = d.visibleFrame
        // Room for the sidebar on the display: else the pair shifts to the
        // display's edge, or (a browser that couldn't be read when it
        // stopped) the window keeps its far edge and the sidebar covers it.
        let kept = want
        if side == .left, want.minX - width < v.minX { want.origin.x = v.minX + width }
        if side == .right, want.maxX + width > v.maxX { want.origin.x = v.maxX - width - want.width }
        let short = want.width > start.width - width + 0.5 // it can't give the sidebar's whole width
        #expect(Self.same(now, want) || (short && Self.same(now, kept)), "\(what): \(c): window at \(now), wanted \(want); its last frames: \(rig.fake.history.suffix(8).map { "\($0)" }.joined(separator: " -> "))",
                sourceLocation: sourceLocation)
    }

    /// Never off its display, at any moment.
    private func expectOnDisplay(_ rig: SidebarRig, _ d: Display, _ c: Case, _ what: String,
                                 sourceLocation: SourceLocation = #_sourceLocation) {
        let off = rig.fake.history.filter { $0.minX < d.frame.minX - 2 || $0.maxX > d.frame.maxX + 2 }
        #expect(off.isEmpty, "\(what): \(c): pushed off its display \(d.frame) to \(off.first.map { "\($0)" } ?? "")",
                sourceLocation: sourceLocation)
    }

    private func expectAtRestOnDisplay(_ rig: SidebarRig, _ d: Display, _ c: Case, _ what: String,
                                       sourceLocation: SourceLocation = #_sourceLocation) {
        let f = rig.fake.frame
        #expect(f.minX >= d.frame.minX - 2 && f.maxX <= d.frame.maxX + 2, "\(what): \(c): at rest off its display \(d.frame) at \(f)",
                sourceLocation: sourceLocation)
    }

    private func expectBack(_ rig: SidebarRig, at start: CGRect, _ c: Case, _ what: String,
                            sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(Self.same(rig.fake.frame, start), "\(what): \(c): hidden, the window is at \(rig.fake.frame), was \(start)",
                sourceLocation: sourceLocation)
    }

    // MARK: A browser that does as asked

    /// Showing narrows, hiding gives back, twice over, for every display
    /// arrangement, display, tile and side.
    @Test(arguments: [FakeBrowser.Resize.applies, .late, .busy])
    func showNarrowsAndHideGivesBack(_ resize: FakeBrowser.Resize) {
        for c in Self.cases {
            let d = c.arrangement.displays[c.display]
            let start = c.tile.frame(on: d)
            let rig = SidebarRig(displays: c.arrangement.displays, frame: start, side: c.side, resize: resize)
            let what = "\(resize)"
            for round in 1...2 {
                rig.toggle()
                expectNarrowed(rig, from: start, side: c.side, width: 280, on: d, c, "\(what), show \(round)")
                rig.toggle()
                expectBack(rig, at: start, c, "\(what), hide \(round)")
            }
            expectOnDisplay(rig, d, c, what)
        }
    }

    /// With Reduce Motion the window goes in one step, with the same outcome.
    @Test func reduceMotion() {
        for c in Self.cases {
            let d = c.arrangement.displays[c.display]
            let start = c.tile.frame(on: d)
            let rig = SidebarRig(displays: c.arrangement.displays, frame: start, side: c.side, reduceMotion: true)
            rig.toggle()
            expectNarrowed(rig, from: start, side: c.side, width: 280, on: d, c, "reduce motion, show")
            rig.toggle()
            expectBack(rig, at: start, c, "reduce motion, hide")
            expectOnDisplay(rig, d, c, "reduce motion")
        }
    }

    /// A browser with a minimum width the narrowed window is still above.
    @Test func minimumWidthAboveWhatIsAsked() {
        for c in Self.cases {
            let d = c.arrangement.displays[c.display]
            let start = c.tile.frame(on: d)
            let rig = SidebarRig(displays: c.arrangement.displays, frame: start, side: c.side, minWidth: 600)
            rig.toggle()
            expectNarrowed(rig, from: start, side: c.side, width: 280, on: d, minWidth: 600, c, "minimum 600, show")
            rig.toggle()
            expectBack(rig, at: start, c, "minimum 600, hide")
            expectOnDisplay(rig, d, c, "minimum 600")
        }
    }

    /// Brave's own minimum width (615 pt, measured), above the 500 the
    /// sidebar assumes until it sees one: a window that can give the whole
    /// width narrows as usual; one that can't keeps its far edge and its
    /// display. Either way hiding gives back its frame.
    @Test(arguments: [(FakeBrowser.Resize.applies, false), (.late, false), (.busy, false), (.applies, true)])
    func braveMinimumWidth(_ resize: FakeBrowser.Resize, _ widensLater: Bool) {
        for c in Self.cases {
            let d = c.arrangement.displays[c.display]
            let start = c.tile.frame(on: d)
            let rig = SidebarRig(displays: c.arrangement.displays, frame: start, side: c.side, resize: resize,
                                 minWidth: min(615, start.width), widensLater: widensLater)
            let what = "\(resize), minimum 615\(widensLater ? " it widens back to later" : "")"
            for round in 1...2 {
                rig.toggle()
                // A busy one that can't give the whole width ends wherever its
                // late answers leave the pair: on its display (below), not placed.
                if resize != .busy || start.width - 280 >= 615 {
                    expectNarrowed(rig, from: start, side: c.side, width: 280, on: d, minWidth: min(615, start.width), c, "\(what), show \(round)")
                }
                // One that widens back past the display's edge on its own does
                // so before the sidebar knows its minimum: checked at rest.
                // A busy one replays what it was asked in a burst when it answers.
                if widensLater || resize == .busy { expectAtRestOnDisplay(rig, d, c, "\(what), show \(round)") }
                rig.toggle()
                expectBack(rig, at: start, c, "\(what), hide \(round)")
            }
            if !widensLater, resize != .busy { expectOnDisplay(rig, d, c, what) }
        }
    }

    /// A tiling app that puts the window back on its tile once after the
    /// sidebar narrowed it: narrowed again, and given all of it back.
    @Test func tilingAppPutsItBackOnce() {
        for c in Self.cases {
            let d = c.arrangement.displays[c.display]
            let start = c.tile.frame(on: d)
            let rig = SidebarRig(displays: c.arrangement.displays, frame: start, side: c.side, tiler: true)
            rig.toggle()
            expectNarrowed(rig, from: start, side: c.side, width: 280, on: d, c, "tiling app, show")
            rig.toggle()
            expectBack(rig, at: start, c, "tiling app, hide")
            expectOnDisplay(rig, d, c, "tiling app")
        }
    }

    // MARK: A browser that won't narrow

    /// It moves but keeps its size, or stops at a minimum width too large to
    /// make room: never pushed off its display, and back where it was.
    @Test(arguments: [(FakeBrowser.Resize.refuses, CGFloat(0)), (.applies, 1800), (.late, 1800)])
    func wontNarrow(_ resize: FakeBrowser.Resize, _ minWidth: CGFloat) {
        for c in Self.cases {
            let d = c.arrangement.displays[c.display]
            let start = c.tile.frame(on: d)
            // A minimum the window is already below can't be: it is as wide as its minimum then.
            let rig = SidebarRig(displays: c.arrangement.displays, frame: start, side: c.side, resize: resize,
                                 minWidth: min(minWidth, start.width))
            let what = "\(resize), minimum \(Int(min(minWidth, start.width)))"
            for round in 1...2 {
                rig.toggle()
                expectOnDisplay(rig, d, c, "\(what), show \(round)")
                rig.toggle()
                expectBack(rig, at: start, c, "\(what), hide \(round)")
            }
        }
    }

    /// A window not listed on screen when the sidebar shows (another Space a
    /// moment ago, or the window server late to list it) makes room without
    /// a slide: the same outcome.
    @Test(arguments: [FakeBrowser.Resize.applies, .late, .busy, .refuses])
    func showWithoutASlide(_ resize: FakeBrowser.Resize) {
        for c in Self.cases {
            let d = c.arrangement.displays[c.display]
            let start = c.tile.frame(on: d)
            let rig = SidebarRig(displays: c.arrangement.displays, frame: start, side: c.side, resize: resize)
            rig.fake.onScreen = false
            rig.toggle()
            rig.fake.onScreen = true
            if resize != .refuses { expectNarrowed(rig, from: start, side: c.side, width: 280, on: d, c, "\(resize), off screen, show") }
            rig.toggle()
            expectBack(rig, at: start, c, "\(resize), off screen, hide")
            expectOnDisplay(rig, d, c, "\(resize), off screen")
        }
    }
}
