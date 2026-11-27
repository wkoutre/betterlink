import AppKit
import BetterlinkCore
import Combine
import SwiftUI

private let kInternetEventClass = AEEventClass(0x4755524C)  // 'GURL'
private let kAEGetURL = AEEventID(0x4755524C)               // 'GURL'
private let keyDirectObject = AEKeyword(0x2D2D2D2D)         // '----'
private let keySenderPID = AEKeyword(0x73706964)            // 'spid'
private let kAEOpenApp = AEEventID(0x6F617070)              // 'oapp'
private let keyLaunchProperty = AEKeyword(0x70726474)       // 'prdt'
private let kLaunchedAsLoginItem = OSType(0x6C676974)       // 'lgit'

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private var routedAtLaunch = false
    private var menuBarSetting: AnyCancellable?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: kInternetEventClass, andEventID: kAEGetURL)
    }

    /// Quitting gives the browser windows the sidebar narrowed their space back.
    func applicationWillTerminate(_ notification: Notification) {
        SidebarController.shared.giveSpaceBack()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Development aids for screenshots: BETTERLINK_APPEARANCE=light|dark.
        switch ProcessInfo.processInfo.environment["BETTERLINK_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        // Listen before loading settings: loading can report a problem.
        NotificationCenter.default.addObserver(forName: .betterlinkNeedsAttention, object: nil, queue: .main) { _ in
            // A problem to read: not the moment for the first-run tour.
            Task { @MainActor in self.showWindow(offerTour: false) }
        }
        model.startConfig(resourceDirectory: Bundle.main.resourceURL ?? Bundle.main.bundleURL)
        model.listenForCLIChanges()
        setupMainMenu()
        _ = Updater.shared  // starts Sparkle's hourly check when it is on
        SidebarController.shared.restore()  // the Tabs sidebar, if it was on
        // Adds the menu bar icon now (unless it is turned off) and whenever
        // the setting changes, from the window or the CLI.
        menuBarSetting = model.$showsMenuBarIcon.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] shown in
            MainActor.assumeIsolated { self?.setStatusItemShown(shown) }
        }
        // Started by macOS at login, not by the person: the window still opens
        // as it always has, but that is not the moment for the first-run tour.
        let launch = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = launch?.eventID == kAEOpenApp
            && launch?.paramDescriptor(forKeyword: keyLaunchProperty)?.enumCodeValue == kLaunchedAsLoginItem
        // Opened by hand (not by a link): show the window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if !self.routedAtLaunch { self.showWindow(offerTour: !atLogin) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    // MARK: Links

    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        // Read the keys first: they are only held for a moment after the click.
        let keys = Self.heldModifierKeys()
        guard let raw = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else { return }
        routedAtLaunch = true
        model.open(raw, opener: opener(of: event), modifiers: keys)
    }

    /// Local .html files: macOS hands those to the default browser too.
    func application(_ application: NSApplication, open urls: [URL]) {
        let keys = Self.heldModifierKeys()
        routedAtLaunch = true
        let event = NSAppleEventManager.shared().currentAppleEvent
        for url in urls { model.open(url.absoluteString, opener: event.flatMap(opener(of:)), modifiers: keys) }
    }

    /// The modifier keys held down right now, anywhere on the Mac (the click
    /// happened in another app). Caps Lock and fn are left out.
    static func heldModifierKeys() -> ModifierKeys {
        modifierKeys(NSEvent.modifierFlags)
    }

    static func modifierKeys(_ flags: NSEvent.ModifierFlags) -> ModifierKeys {
        var keys: ModifierKeys = []
        if flags.contains(.control) { keys.insert(.control) }
        if flags.contains(.option) { keys.insert(.option) }
        if flags.contains(.shift) { keys.insert(.shift) }
        if flags.contains(.command) { keys.insert(.command) }
        return keys
    }

    /// Bundle id of the app that sent the link, when it is an app.
    private func opener(of event: NSAppleEventDescriptor) -> String? {
        let mine = Bundle.main.bundleIdentifier
        if let pid = event.attributeDescriptor(forKeyword: keySenderPID)?.int32Value, pid > 0,
           let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, id != mine {
            return id
        }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return front == mine ? nil : front
    }

    // MARK: Window

    /// - Parameter offerTour: whether the first-run tour may open with the
    ///   window (once, until it is finished or skipped). Off when the window
    ///   opens to show something particular: a problem, or a page asked for.
    func showWindow(offerTour: Bool = true) {
        model.refreshCatalog()
        model.refreshDefaultBrowser()
        if window == nil {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: BetterlinkWindow.defaultSize),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "betterlink"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            let host = NSHostingController(rootView: RootView().environmentObject(model))
            host.sizingOptions = []  // the window, not the content, sets the size
            w.contentViewController = host
            w.setContentSize(BetterlinkWindow.defaultSize)
            // The smallest size is held in windowWillResize, below.
            w.delegate = self
            // Closing the window on the tour ends the tour, like Skip.
            // The window lives as long as the app, so the observer is never removed.
            _ = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated { TourModel.shared.windowClosed() }
            }
            w.center()
            // AppKit keeps the frame in the app's own preferences: not from a
            // development or test run (MenuBarIcon.defaults).
            if (ProcessInfo.processInfo.environment["BETTERLINK_HOME"] ?? "").isEmpty { w.setFrameAutosaveName("betterlink.main.v4") }
            window = w
        }
        model.refreshPermissions()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        TourModel.shared.windowOpened(offer: offerTour)
    }

    /// Holds the window's smallest size: dragged smaller, it clips the page's
    /// edges (and the tour's buttons). `contentMinSize` can't hold it: the
    /// hosting view writes the window's size limits from its own on its first
    /// layout, and with `sizingOptions = []` those are zero.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let least = sender.frameRect(forContentRect: NSRect(origin: .zero, size: BetterlinkWindow.minSize)).size
        return NSSize(width: max(frameSize.width, least.width), height: max(frameSize.height, least.height))
    }

    // MARK: Keyboard menu

    /// betterlink runs without a Dock icon, so this menu bar is never on
    /// screen, but macOS still looks here for key equivalents while the window
    /// is in front. Without it, ⌘W, ⌘C, ⌘V and the rest do nothing.
    private func setupMainMenu() {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            main.addItem(holder)
            return menu
        }
        func item(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
            mi.keyEquivalentModifierMask = mods
            return mi
        }
        _ = submenu("betterlink", [
            item("Hide betterlink", #selector(NSApplication.hide(_:)), "h"),
            item("Quit betterlink", #selector(NSApplication.terminate(_:)), "q"),
        ])
        _ = submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        let window = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            // Same as the red button: the window hides and betterlink keeps running.
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        NSApp.mainMenu = main
        NSApp.windowsMenu = window
    }

    // MARK: Menu bar

    private func setStatusItemShown(_ shown: Bool) {
        if shown {
            if statusItem == nil { setupStatusItem() }
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.menuBarGlyph()
        item.button?.setAccessibilityLabel("betterlink")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// The app icon's fork as an 18pt template image: macOS tints it for
    /// light and dark menu bars.
    static func menuBarGlyph() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let stem = NSBezierPath()
            stem.lineWidth = 1.8; stem.lineCapStyle = .round
            stem.move(to: NSPoint(x: 3.5, y: 9)); stem.line(to: NSPoint(x: 8, y: 9))
            stem.stroke()
            for endY in [4.0, 14.0] {
                let p = NSBezierPath()
                p.lineWidth = 1.8; p.lineCapStyle = .round
                p.move(to: NSPoint(x: 8, y: 9))
                p.curve(to: NSPoint(x: 14, y: endY), controlPoint1: NSPoint(x: 10.5, y: 9), controlPoint2: NSPoint(x: 11.5, y: endY))
                p.stroke()
                NSBezierPath(ovalIn: NSRect(x: 13.2, y: endY - 1.8, width: 3.6, height: 3.6)).fill()
            }
            NSBezierPath(ovalIn: NSRect(x: 1.2, y: 6.7, width: 4.6, height: 4.6)).fill()
            return true
        }
        img.isTemplate = true
        return img
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "Open betterlink…", action: #selector(openWindow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Edit config.ts", action: #selector(editConfig), keyEquivalent: "").target = self
        // The way back into the tour for people who live in the menu bar.
        menu.addItem(withTitle: TourModel.shared.news.isEmpty ? "Show the Tour…" : "What's New…",
                     action: #selector(showTour), keyEquivalent: "").target = self
        let updater = Updater.shared
        if let ready = updater.readyVersion {
            let item = menu.addItem(withTitle: "Restart to Update to \(ready)", action: #selector(restartToUpdate), keyEquivalent: "")
            item.target = self
            item.toolTip = "Downloaded and checked. It also installs by itself the next time the Mac is left alone for two minutes, or when betterlink quits."
        } else if let found = updater.foundVersion {
            menu.addItem(withTitle: "Update to betterlink \(found)…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        } else if updater.isAvailable {
            menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        }
        let sidebar = SidebarController.shared
        if sidebar.enabled {
            // The window in front's; with no browser in front, every window's.
            let item = menu.addItem(withTitle: sidebar.toggleTitle, action: #selector(toggleSidebar), keyEquivalent: "")
            item.target = self
            item.toolTip = "For the browser window in front: \(sidebar.shortcut.display) does the same. With no browser in front, for every window."
        }
        menu.addItem(.separator())
        let recent = model.log.recentLinks(10)
        let header = NSMenuItem(title: recent.isEmpty ? "No links yet" : "Recent links", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for e in recent {
            let title = "\(e.profileName ?? "not opened")  ·  \(e.link ?? "")"
            let mi = NSMenuItem(title: String(title.prefix(80)), action: #selector(copyLink(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = e.link
            mi.toolTip = e.message + "\nClick to copy the link."
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit betterlink", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func openWindow() { showWindow() }
    @objc private func editConfig() { model.editConfig() }
    @objc private func showTour() {
        showWindow(offerTour: false)
        TourModel.shared.start(TourModel.shared.news.isEmpty ? .replay : .whatsNew)
    }
    @objc private func toggleSidebar() { SidebarController.shared.toggle() }
    @objc private func checkForUpdates() { Updater.shared.checkNow() }
    @objc private func restartToUpdate() { Updater.shared.restartToUpdate() }
    @objc private func copyLink(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
