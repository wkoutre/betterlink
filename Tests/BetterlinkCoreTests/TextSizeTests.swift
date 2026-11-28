import Foundation
import Testing
@testable import BetterlinkCore

@Suite struct TextSizeTests {
    private func defaults() -> (UserDefaults, String) {
        let name = "betterlink.tests.textsize.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    /// Default until one is chosen, and what was chosen is what comes back.
    @Test func defaultUntilChosen() {
        let (d, name) = defaults()
        defer { d.removePersistentDomain(forName: name) }
        #expect(TextSize.current(in: d) == .standard)
        for size in TextSize.allCases {
            TextSize.set(size, in: d)
            #expect(TextSize.current(in: d) == size)
        }
    }

    /// A value this betterlink doesn't know (saved by a newer one, or by hand)
    /// is the default, not a crash or a size of nothing.
    @Test func anUnknownStoredValueIsTheDefault() {
        let (d, name) = defaults()
        defer { d.removePersistentDomain(forName: name) }
        d.set("enormous", forKey: TextSize.defaultsKey)
        #expect(TextSize.current(in: d) == .standard)
        d.set(42, forKey: TextSize.defaultsKey)
        #expect(TextSize.current(in: d) == .standard)
    }

    /// The names the command line takes and the settings store.
    @Test func namesAreStable() {
        #expect(TextSize.allCases.map(\.rawValue) == ["small", "default", "large", "larger", "largest"])
    }

    /// Default is the size the design is drawn for: nothing changes at it.
    @Test func defaultChangesNothing() {
        #expect(TextSize.standard.scale == 1)
        for length in [1.0, 9, 16, 20, 24, 28, 30, 44, 224, 780] {
            #expect(TextSize.standard.length(length) == length)
        }
    }

    /// Each size is larger than the one before, body text is a whole number of
    /// points at every size, and the range stays one a window can hold.
    @Test func sizesGrowInOrder() {
        let points = TextSize.allCases.map(\.points)
        #expect(points == points.sorted())
        #expect(Set(points).count == points.count)
        for size in TextSize.allCases {
            #expect(size.points == size.points.rounded())
            #expect(size.scale >= 0.9 && size.scale <= 1.4)
            #expect(abs(TextSize.standardPoints * size.scale - size.points) < 1e-9)
        }
    }

    /// Lengths that hold text grow with it, in whole points.
    @Test func lengthsFollowTheText() {
        for size in TextSize.allCases {
            let row = size.length(30)
            #expect(row == row.rounded())
            // A row always holds a line of its own body text with room around it.
            #expect(row >= size.points * 1.5)
        }
        #expect(TextSize.small.length(30) == 28)
        #expect(TextSize.large.length(30) == 32)
        #expect(TextSize.larger.length(30) == 37)
        #expect(TextSize.largest.length(30) == 42)
    }

    @Test func titlesSayThePoints() {
        #expect(TextSize.standard.title == "Default (13 pt)")
        #expect(TextSize.largest.title == "Largest (18 pt)")
    }
}
