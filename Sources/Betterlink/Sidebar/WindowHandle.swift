import AppKit
import ApplicationServices

/// One display: its whole frame and the part windows are given (no menu bar,
/// no Dock). Cocoa global coordinates.
struct Display: Equatable {
    var frame: CGRect
    var visibleFrame: CGRect
}

/// The displays the sidebar places windows on, the primary one (with the menu
/// bar) first: Cocoa's y runs up from its bottom edge and Accessibility's
/// down from its top, so it is what converts between the two.
@MainActor
enum Displays {
    /// Where they are read from: AppKit, or a test's own displays
    /// (SidebarGuardTests), so the sidebar's moves can be checked on any
    /// arrangement without a Mac that has it.
    static var source: () -> [Display] = {
        NSScreen.screens.map { Display(frame: $0.frame, visibleFrame: $0.visibleFrame) }
    }

    static var all: [Display] { source() }

    /// The height Accessibility's coordinates are flipped by.
    static var primaryHeight: CGFloat? { all.first?.frame.height }

    /// The usable part of the display showing the most of `frame`.
    static func visibleFrame(for frame: CGRect) -> CGRect? {
        all.max { $0.frame.intersection(frame).area < $1.frame.intersection(frame).area }?.visibleFrame
    }
}

/// One browser window as the sidebar reads and moves it, in Accessibility's
/// coordinates (top left of the primary display, y down), as macOS takes them:
/// position and size are separate calls, and macOS limits each to what fits on
/// the screen at that moment. In the app it is Accessibility (AXHandle); in
/// tests a fake browser (SidebarGuardTests).
@MainActor
protocol WindowHandle: AnyObject {
    /// Nil when the browser doesn't answer in time.
    func position() -> CGPoint?
    func size() -> CGSize?
    func setPosition(_ p: CGPoint)
    func setSize(_ s: CGSize)
    /// The window as the window server shows it now: no waiting for the browser.
    func shownBounds() -> CGRect?
    /// On a Space that is showing, not minimized, its app not hidden.
    var isOnScreen: Bool { get }
}

/// A browser window through Accessibility, and the window server by its number.
@MainActor
final class AXHandle: WindowHandle {
    let element: AXUIElement
    let number: CGWindowID

    init(element: AXUIElement, number: CGWindowID) {
        self.element = element
        self.number = number
    }

    func position() -> CGPoint? {
        guard let v: AXValue = AXWindow.copy(element, kAXPositionAttribute) else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v, .cgPoint, &p) ? p : nil
    }

    func size() -> CGSize? {
        guard let v: AXValue = AXWindow.copy(element, kAXSizeAttribute) else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v, .cgSize, &s) ? s : nil
    }

    func setPosition(_ p: CGPoint) {
        var p = p
        if let v = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, v) }
    }

    func setSize(_ s: CGSize) {
        var s = s
        if let v = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, v) }
    }

    func shownBounds() -> CGRect? { WindowServer.bounds(number) }

    var isOnScreen: Bool { WindowServer.onScreen().contains(number) }
}

extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
