import AppKit
import BetterlinkCore
import Combine
import SwiftUI
import TabSyncCore
import Testing
@testable import Betterlink

/// A settings folder of the test run's own, never the real one
/// (CONTRIBUTING.md). Made before any of the app's singletons is first used:
/// each reads BETTERLINK_HOME once, when it is made.
@MainActor
enum TestHome {
    static let folder: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("betterlink-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("BETTERLINK_HOME", dir.path, 1)
        // Gone again when the tests are over.
        made = dir.path
        atexit { if let made { try? FileManager.default.removeItem(atPath: made) } }
        return dir
    }()
}

private nonisolated(unsafe) var made: String?

/// The whole sidebar, drawn offscreen with fixed content and no app running.
/// Starting a drag must change only the two lines that turn into drop zones:
/// when the zones were rows of their own, every row below moved 76 pt under
/// the pointer (#71).
@MainActor @Suite(.serialized) struct SidebarLayoutTests {
    private let size = CGSize(width: 280, height: 560)
    private let watcher: BrowserWatcher
    private let window: TrackedWindow
    private let instance: SidebarInstance

    init() throws {
        let home = TestHome.folder
        try #require(SettingsFolder.resolve().directory.path == home.path)
        try #require(MenuBarIcon.defaults() !== UserDefaults.standard)
        // Also if something made the library before the folder was set.
        SidebarLibraryModel.shared.reload(folder: SettingsFolder(directory: home))
        let controller = SidebarController.shared
        // A window of this process, followed by nothing: only its id is used.
        watcher = BrowserWatcher(.current, tracker: controller.tracker)
        window = TrackedWindow(element: AXUIElementCreateApplication(getpid()), number: 0, watcher: watcher)
        instance = SidebarInstance(window: window, sidebar: controller, hidden: false, width: size.width)
    }

    private let tabs = (0..<4).map {
        BrowserTab(id: 100 + $0, windowId: 1, index: $0, title: "Tab \($0)", url: "https://tab\($0).example/", active: $0 == 0)
    }
    private let inFolder = SavedLink(title: "Saved in a folder", url: "https://folder.example/")

    /// A folder with two links, and a link beside it.
    private func profile(favorites: Int) -> SidebarProfile {
        var p = SidebarProfile(name: "Layout")
        for i in 0..<favorites { p.addFavorite(SavedLink(title: "Favorite \(i)", url: "https://favorite\(i).example/")) }
        let folder = p.addFolder("Folder")
        p.addLink(inFolder, in: folder)
        p.addLink(SavedLink(title: "Another in the folder", url: "https://another.example/"), in: folder)
        p.addLink(SavedLink(title: "Beside the folder", url: "https://beside.example/"))
        return p
    }

    private func show(_ profile: SidebarProfile) throws {
        let lib = SidebarLibraryModel.shared
        lib.change { $0 = SidebarLibrary(profiles: [profile]) }
        try #require(lib.problem == nil && lib.library.profiles == [profile])
        var session = BrowserSession(socketPath: "/layout-test")
        var snapshot = Inbound(type: "snapshot")
        snapshot.seq = 1
        snapshot.windows = [SnapshotWindow(id: 1, focused: true, tabs: tabs, left: 0, top: 0, width: 1000, height: 800)]
        session.store.apply(snapshot)
        instance.show(.window(.init(session: session, window: session.store.entry(1))))
        try #require(instance.look.match?.window?.tabs.count == tabs.count)
    }

    /// The sidebar as drawn while `key` is dragged (nil: nothing is).
    private func drawn(dragging key: String?) throws -> NSBitmapImageRep {
        try drawing(hosted(dragging: key))
    }

    private func hosted(dragging key: String? = nil) -> NSView {
        let host = NSHostingView(rootView: SidebarView(dragging: key).environmentObject(instance))
        host.sizingOptions = []
        host.appearance = NSAppearance(named: .aqua)
        host.frame = CGRect(origin: .zero, size: size)
        return host
    }

    private func drawing(_ host: NSView) throws -> NSBitmapImageRep {
        // Lazy rows and measured sizes arrive over a few turns of the run loop.
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        return image
    }

    private func row(_ y: Int, of image: NSBitmapImageRep) -> UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(start: image.bitmapData! + y * image.bytesPerRow, count: image.pixelsWide * image.bitsPerPixel / 8)
    }

    /// Where two drawings differ, as bands of points from the top. Pixel rows
    /// less than 8 pt apart are one band: a drop zone's dashes leave gaps.
    private func bands(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) throws -> [ClosedRange<CGFloat>] {
        try #require(a.pixelsHigh == b.pixelsHigh && a.pixelsWide == b.pixelsWide && a.bitsPerPixel == b.bitsPerPixel)
        let scale = CGFloat(a.pixelsHigh) / size.height
        var bands: [ClosedRange<CGFloat>] = []
        for y in 0..<a.pixelsHigh where !row(y, of: a).elementsEqual(row(y, of: b)) {
            let top = CGFloat(y) / scale, bottom = CGFloat(y + 1) / scale
            if let last = bands.last, top - last.upperBound < 8 {
                bands[bands.count - 1] = last.lowerBound...bottom
            } else {
                bands.append(top...bottom)
            }
        }
        return bands
    }

    /// How many pixel rows between `top` and `bottom` (points) have something
    /// drawn in them: a blank drawing would compare equal to anything.
    private func inked(_ image: NSBitmapImageRep, from top: CGFloat, to bottom: CGFloat) -> Int {
        let scale = CGFloat(image.pixelsHigh) / size.height, bytes = image.bitsPerPixel / 8
        return (Int(top * scale)..<Int(bottom * scale)).count { y in
            let r = row(y, of: image)
            return !r.dropFirst(bytes).elementsEqual(r.dropLast(bytes))
        }
    }

    private func height(_ band: ClosedRange<CGFloat>) -> CGFloat { band.upperBound - band.lowerBound }

    /// With no Favorite yet, a dragged tab turns the header line into the
    /// place for the first one and the New Tab line into the place to save it.
    @Test func draggingATabChangesOnlyTheHeaderAndNewTabLines() throws {
        try show(profile(favorites: 0))
        let idle = try drawn(dragging: nil)
        let dragging = try drawn(dragging: "betterlink-tab:\(window.id):\(tabs[1].id)")
        let changed = try bands(idle, dragging)
        try #require(changed.count == 2, "\(changed)")
        #expect(height(changed[0]) <= 24)
        #expect(height(changed[1]) <= DS.Size.sizeRow)
        // The saved rows between the two lines, and the tabs below New Tab,
        // are drawn, and drawn the same.
        #expect(inked(idle, from: changed[0].upperBound, to: changed[1].lowerBound) > 20)
        #expect(inked(idle, from: changed[1].upperBound, to: size.height) > 20)
    }

    /// With Favorites, a dragged saved link changes the New Tab line alone.
    @Test func draggingASavedLinkChangesOnlyTheNewTabLine() throws {
        try show(profile(favorites: 3))
        let idle = try drawn(dragging: nil)
        let dragging = try drawn(dragging: SidebarView.savedKey(inFolder.id))
        let changed = try bands(idle, dragging)
        try #require(changed.count == 1, "\(changed)")
        #expect(height(changed[0]) <= DS.Size.sizeRow)
        #expect(inked(idle, from: 0, to: changed[0].lowerBound) > 20)
        #expect(inked(idle, from: changed[0].upperBound, to: size.height) > 20)
    }

    /// A window of 56 tabs, each changing its title twice a second, another
    /// app in front: every 2 s every title is new (PublishPacer). The sidebar
    /// isn't told its whole look changed for that, so nothing but the titles is
    /// worked out again, and it draws just what a sidebar drawn afresh with
    /// the new titles draws. A tab switching is still a new look.
    @Test func newTitlesRedrawOnlyTheTitlesAndDrawAsAFreshSidebarDoes() throws {
        try show(profile(favorites: 1))
        let churning = (0..<56).map {
            BrowserTab(id: 200 + $0, windowId: 1, index: $0, title: "Page \($0)", url: "https://page\($0).example/", active: $0 == 0)
        }
        instance.show(look(churning))
        let live = hosted()
        let before = try drawing(live)
        var told = 0
        let watching = instance.objectWillChange.sink { told += 1 }
        defer { watching.cancel() }

        let renamed = churning.map { t -> BrowserTab in var t = t; t.title = "Renamed \(t.id)"; return t }
        instance.show(look(renamed))
        #expect(told == 0, "the sidebar was told its look changed \(told) times for new titles")
        #expect(instance.look == look(renamed))
        let drawn = try drawing(live)
        let fresh = try drawing(hosted())
        #expect(try bands(drawn, fresh).isEmpty)
        // And the new titles are what is drawn.
        #expect(try !bands(before, drawn).isEmpty)

        var switched = renamed
        switched[0].active = false
        switched[1].active = true
        instance.show(look(switched))
        #expect(told == 1)
    }

    /// After new titles alone the view keeps the tab list it last drew, and a
    /// lazy row built later (scrolled to) is made from that list: its title
    /// is the newest the sidebar was shown, not the one in that old list.
    @Test func aRowBuiltAfterNewTitlesShowsTheNewTitle() throws {
        try show(profile(favorites: 0))
        let drawn = (0..<8).map {
            BrowserTab(id: 300 + $0, windowId: 1, index: $0, title: "Page \($0)", url: "https://page\($0).example/", active: $0 == 0)
        }
        instance.show(look(drawn))
        // Only the first row was built before the titles changed.
        #expect(instance.title(of: drawn[0]).text == "Page 0")
        let renamed = drawn.map { t -> BrowserTab in var t = t; t.title = "Renamed \(t.id)"; return t }
        instance.show(look(renamed))
        #expect(instance.title(of: drawn[0]).text == "Renamed 300")
        // Built now, from the list the view last drew.
        #expect(instance.title(of: drawn[5]).text == "Renamed 305")
    }

    private func look(_ tabs: [BrowserTab]) -> SidebarLook {
        var session = BrowserSession(socketPath: "/layout-test")
        var snapshot = Inbound(type: "snapshot")
        snapshot.seq = 1
        snapshot.windows = [SnapshotWindow(id: 1, focused: true, tabs: tabs, left: 0, top: 0, width: 1000, height: 800)]
        session.store.apply(snapshot)
        return .window(.init(session: session, window: session.store.entry(1)))
    }
}
