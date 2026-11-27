import AppKit
import ApplicationServices

/// One display: its whole frame and the part windows are given (no menu bar,
/// no Dock). Cocoa global coordinates.
struct Display: Equatable {
    var frame: CGRect
    var visibleFrame: CGRect
    /// The display's number (its corner reads are per display), and its
    /// points-to-pixels scale (edges are rounded to device pixels).
    var number: CGDirectDisplayID? = nil
    var scale: CGFloat = 1
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
        NSScreen.screens.map {
            Display(frame: $0.frame, visibleFrame: $0.visibleFrame,
                    number: ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                    scale: $0.backingScaleFactor)
        }
    }

    static var all: [Display] { source() }

    /// The height Accessibility's coordinates are flipped by.
    static var primaryHeight: CGFloat? { all.first?.frame.height }

    /// The display showing the most of `frame`.
    static func display(for frame: CGRect) -> Display? {
        all.max { $0.frame.intersection(frame).area < $1.frame.intersection(frame).area }
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
    /// How long each call may wait for the browser to answer.
    func limitWaiting(_ seconds: Double)
    /// The last call got no answer in time: the browser is hung or busy.
    var missed: Bool { get }
    /// In native full screen (`AXFullScreen`); nil when it can't be read.
    func isFullScreen() -> Bool?
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

    private(set) var missed = false

    func limitWaiting(_ seconds: Double) { AXUIElementSetMessagingTimeout(element, Float(seconds)) }

    func position() -> CGPoint? {
        defer { missed = AXWindow.timedOut }
        guard let v: AXValue = AXWindow.copy(element, kAXPositionAttribute) else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v, .cgPoint, &p) ? p : nil
    }

    func size() -> CGSize? {
        defer { missed = AXWindow.timedOut }
        guard let v: AXValue = AXWindow.copy(element, kAXSizeAttribute) else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v, .cgSize, &s) ? s : nil
    }

    func setPosition(_ p: CGPoint) {
        var p = p
        guard let v = AXValueCreate(.cgPoint, &p) else { return }
        missed = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, v) == .cannotComplete
    }

    func setSize(_ s: CGSize) {
        var s = s
        guard let v = AXValueCreate(.cgSize, &s) else { return }
        missed = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, v) == .cannotComplete
    }

    func shownBounds() -> CGRect? { WindowServer.bounds(number) }

    func isFullScreen() -> Bool? { AXWindow.copy(element, "AXFullScreen") }

    var isOnScreen: Bool { WindowServer.onScreen().contains(number) }
}

extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
