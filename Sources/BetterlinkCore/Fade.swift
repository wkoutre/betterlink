import Foundation

/// The sidebar's show and hide fade, as plain numbers: where the alpha is at a
/// given time, and what happens when a show interrupts a hide or the reverse.
/// The panel drives it from its own timer, so every hide fades the same way
/// whatever else the window is doing.
public struct Fade: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case shown, hidden, showing, hiding }

    public private(set) var phase: Phase
    private var from: Double
    private var to: Double
    private var start: Double
    private var duration: Double

    public static let showDuration = 0.14
    public static let hideDuration = 0.12

    public init(shown: Bool) {
        phase = shown ? .shown : .hidden
        from = shown ? 1 : 0; to = from; start = 0; duration = 0
    }

    /// The alpha at time `t` (seconds), easing out.
    public func alpha(at t: Double) -> Double {
        guard duration > 0 else { return to }
        let f = min(max((t - start) / duration, 0), 1)
        let eased = 1 - (1 - f) * (1 - f)
        return from + (to - from) * eased
    }

    /// Whether the fade has reached its end at `t`.
    public func done(at t: Double) -> Bool { duration <= 0 || t - start >= duration - 1e-9 }

    /// Starts showing at `t` from wherever the alpha is now. A show while
    /// shown or showing changes nothing. With reduceMotion it is shown at once.
    public mutating func show(at t: Double, reduceMotion: Bool) {
        guard phase == .hidden || phase == .hiding else { return }
        retarget(1, at: t, duration: reduceMotion ? 0 : Fade.showDuration)
        phase = reduceMotion ? .shown : .showing
    }

    /// Starts hiding at `t` from wherever the alpha is now (a hide during a
    /// show fades back from there, never jumping). With reduceMotion it is
    /// hidden at once.
    public mutating func hide(at t: Double, reduceMotion: Bool) {
        guard phase == .shown || phase == .showing else { return }
        retarget(0, at: t, duration: reduceMotion ? 0 : Fade.hideDuration)
        phase = reduceMotion ? .hidden : .hiding
    }

    /// Settles a finished fade: showing becomes shown, hiding becomes hidden.
    public mutating func settle(at t: Double) {
        guard done(at: t) else { return }
        if phase == .showing { phase = .shown }
        if phase == .hiding { phase = .hidden }
        from = to; duration = 0
    }

    private mutating func retarget(_ target: Double, at t: Double, duration d: Double) {
        let now = alpha(at: t)
        // Shorter when part of the way there already, so speed stays even.
        let rest = abs(target - now)
        from = now; to = target; start = t; duration = d * rest
    }
}

/// What showing or hiding the sidebar does, in order. Hiding stops the
/// sidebar following the window first, fades it where it is, and only then
/// gives the window its width back, so the panel never jumps to the window's
/// new edge on its way out (Nick, 2026-11-24). Showing narrows the window
/// first, then places the panel and fades it in.
public enum SidebarToggleStep: Equatable, Sendable {
    case stopFollowing, fadeOut, giveSpaceBackAfterFade
    case narrowWindow, place, fadeIn

    public static func steps(showing: Bool) -> [SidebarToggleStep] {
        showing ? [.narrowWindow, .place, .fadeIn] : [.stopFollowing, .fadeOut, .giveSpaceBackAfterFade]
    }
}
