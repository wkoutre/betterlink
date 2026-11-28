import Foundation

/// How large betterlink draws its own text: the window's pages and the sidebar
/// beside a browser (General › Text size). Rows, buttons and icons are drawn
/// to the same scale, so a larger size is a larger interface, not only larger
/// letters in the same boxes.
///
/// Kept per Mac in UserDefaults, like the link toast: what reads well depends
/// on the display, not on the person, so a settings folder shared between
/// Macs doesn't carry it.
public enum TextSize: String, CaseIterable, Sendable {
    case small
    case standard = "default"
    case large, larger, largest

    public static let defaultsKey = "textSize"
    /// Body text at the standard size (the macOS standard). Every length in
    /// the design is drawn for it.
    public static let standardPoints: Double = 13

    /// Body text at this size, in points.
    public var points: Double {
        switch self {
        case .small: 12
        case .standard: Self.standardPoints
        case .large: 14
        case .larger: 16
        case .largest: 18
        }
    }

    /// How many times the standard size this one is.
    public var scale: Double { points / Self.standardPoints }

    public var label: String {
        switch self {
        case .small: "Small"
        case .standard: "Default"
        case .large: "Large"
        case .larger: "Larger"
        case .largest: "Largest"
        }
    }

    /// As a list of sizes shows it: "Large (14 pt)".
    public var title: String { "\(label) (\(Int(points)) pt)" }

    /// A length drawn for standard text (a row's height, an icon's side) at
    /// this size, in whole points so its edges stay sharp.
    public func length(_ standard: Double) -> Double { (standard * scale).rounded() }

    /// Default unless another was chosen (an unknown stored value counts as
    /// Default, so a size a newer betterlink saved never breaks an older one).
    public static func current(in defaults: UserDefaults) -> TextSize {
        defaults.string(forKey: defaultsKey).flatMap(TextSize.init(rawValue:)) ?? .standard
    }

    public static func set(_ size: TextSize, in defaults: UserDefaults) {
        defaults.set(size.rawValue, forKey: defaultsKey)
    }
}
