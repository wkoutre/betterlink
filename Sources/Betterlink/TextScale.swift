import BetterlinkCore
import Observation
import SwiftUI

/// The text size betterlink is drawn at, in the window and in every sidebar
/// (General › Text size, `betterlink text-size`).
///
/// The design's text styles and the sizes that hold text (DesignTokens.swift)
/// are read through it, so a view that uses a token is drawn at the chosen
/// size. It is observable: SwiftUI notes each view whose body read a token and
/// draws those again when the size changes, with nothing rebuilt and no state
/// lost (a scroll position, a name being typed). So a new size shows at once,
/// in every window, without a restart.
///
/// Set by AppModel, on the main thread, from this Mac's settings. Until then
/// it is the standard size, which is what tests draw at.
@Observable
final class TextScale: @unchecked Sendable {
    static let shared = TextScale()

    private(set) var size: TextSize = .standard

    func set(_ new: TextSize) {
        if new != size { size = new }
    }
}

extension DS {
    /// A font size drawn for standard text, at the chosen text size.
    static func text(_ points: CGFloat) -> CGFloat {
        points * CGFloat(TextScale.shared.size.scale)
    }

    /// A length that holds text (a row's or a button's height, an icon beside
    /// a name, a column of words), at the chosen text size, in whole points.
    /// Spacing, corner radii and hairlines stay as they are.
    static func scaled(_ length: CGFloat) -> CGFloat {
        CGFloat(TextScale.shared.size.length(Double(length)))
    }
}
