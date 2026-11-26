import Foundation

/// The browser's own word for a followed window: what the extension calls the
/// browser window it is paired with.
public enum WindowWord: Equatable, Sendable {
    case normal
    /// A popup (an extension's palette), an app window, DevTools.
    case other

    /// The word for a window the pairing found to be `found`: nil while it is
    /// paired with nothing, or with a browser window that is gone.
    public static func word(for found: WindowPairing.Found, in sessions: [BrowserSession]) -> WindowWord? {
        guard case .window(let hit) = found,
              let window = sessions.first(where: { $0.id == hit.session })?.store.windows[hit.windowId] else { return nil }
        return window.isNormal ? .normal : .other
    }
}
