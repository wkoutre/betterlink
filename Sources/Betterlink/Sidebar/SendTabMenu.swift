import AppKit
import TabSyncCore

/// "Send to Another Profile…" on a tab's right-click: a menu, made the moment
/// it opens, of every other browser profile or browser connected right now.
/// The sidebar's rows don't redraw when another profile connects, so the list
/// is read here, at the click, never from the row.
@MainActor
enum SendTabMenu {
    static func popUp(_ tab: BrowserTab, from s: BrowserSession, incognito: Bool) {
        let model = TabsModel.shared
        let menu = NSMenu()
        let targets = model.sendTargets(for: tab, from: s, incognito: incognito)
        if targets.isEmpty {
            let none = NSMenuItem(title: "No other browser profile is open with the Tabs extension", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for target in targets {
            let item = ClosureItem(title: model.label(of: target)) { model.send(tab, from: s, to: target) }
            // Two profiles whose names can't be read are numbered; the page in
            // front says which is which.
            if let title = model.frontTitle(of: target) { item.subtitle = "Showing \u{201C}\(title.prefix(60))\u{201D}" }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// A menu item that runs a closure.
private final class ClosureItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { run() }
}
