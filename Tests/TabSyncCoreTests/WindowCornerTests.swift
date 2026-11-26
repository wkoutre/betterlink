import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import TabSyncCore

struct WindowCornerTests {
    /// The top-left corner of a Chrome 158 window as the window server drew
    /// it (macOS 26.5.2, 2x display, radius 20 by the window server; alpha
    /// of a single-window capture, 2026-11-25; all four corners and Brave's
    /// are the same). Each row: clear pixels, then the alphas (of 255) of
    /// the partly covered ones; the rest of the row is opaque.
    static let chrome20at2x = """
    35:3 9 20 32 45 59 73 86 98 111 121 132 142 152 160 170 178 188 197 206 215 224 233 241 247
    29:5 25 58 99 146 200 253
    25:2 27 77 149 233
    23:23 85 178
    20:1 39 128
    19:34 132
    17:14 98 253
    16:44 174
    14:4 81
    13:12 115
    12:18 140
    11:21 155
    10:18 155
    9:12 140
    8:4 115
    8:81
    7:44
    6:14 174
    6:98
    5:34 253
    4:1 132
    4:39
    4:128
    3:23
    3:85
    2:2 178
    2:27
    2:77
    2:149
    1:5 233
    1:25
    1:58
    1:99
    1:146
    1:200
    0:3 253
    0:9
    0:20
    0:32
    0:45
    0:59
    0:73
    0:86
    0:98
    0:111
    0:121
    0:132
    0:142
    0:152
    0:160
    0:170
    0:178
    0:188
    0:197
    0:206
    0:215
    0:224
    0:233
    0:241
    0:247
    0:
    0:
    """

    /// The top-left corner of a Chrome for Testing window opened with
    /// `--app` as the window server drew it (macOS 26.5.2, 2x display,
    /// radius 16 by the window server; alpha of a single-window capture
    /// without its shadow, `screencapture -o -l`, 2026-11-26; all four
    /// corners the same, and the same again with the window moved).
    /// Rows as in `chrome20at2x`.
    static let app16at2x = """
    26:1 8 20 36 53 70 87 103 119 132 145 155 166 176 185 195 204 213 223 232 241 247
    21:1 16 50 98 154 222
    19:26 84 168
    16:3 49 143
    15:45 155
    13:18 112
    12:46 184
    10:1 73 249
    9:4 93
    8:4 99
    7:1 93
    7:73
    6:46 249
    5:18 184
    5:112
    4:45
    3:3 155
    3:49
    3:143
    2:26
    2:84
    1:1 168
    1:16
    1:50
    1:98
    1:154
    0:1 222
    0:8
    0:20
    0:36
    0:53
    0:70
    0:87
    0:103
    0:119
    0:132
    0:145
    0:155
    0:166
    0:176
    0:185
    0:195
    0:204
    0:213
    0:223
    0:232
    0:241
    0:247
    0:
    0:
    """

    /// The capture as how much of each pixel the window covers, `side` pixels square.
    static func measured(side: Int) -> [[Double]] { measured(chrome20at2x, side: side) }

    static func measured(_ capture: String, side: Int) -> [[Double]] {
        capture.split(separator: "\n").prefix(side).map { line in
            let parts = line.split(separator: ":", omittingEmptySubsequences: false)
            let clear = Int(parts[0].trimmingCharacters(in: .whitespaces)) ?? 0
            let partial = parts[1].split(separator: " ").compactMap { Double($0) }.map { $0 / 255 }
            return (Array(repeating: 0, count: clear) + partial + Array(repeating: 1, count: side)).prefix(side).map { $0 }
        }
    }

    private func rowSums(_ g: [[Double]]) -> [Double] { g.map { $0.reduce(0) { $0 + (1 - $1) } } }

    /// Measured on single-window captures, 2x display, alpha over 127: the
    /// rows from the corner until the window's edge is straight, for the
    /// radius the window server reports. Floating or filling its screen, the same.
    static let calibration: [(radius: CGFloat, rows: Int)] = [(16, 35), (20, 46), (26, 63)]

    @Test func theModelDrawsEachCalibratedRadiusToWithinARow() {
        for (radius, rows) in Self.calibration {
            let model = WindowCorner.pixels(radius: radius, scale: 2).straightAfter(over: 127.0 / 255)
            #expect(abs(model - rows) <= 1, "radius \(radius): \(model) rows, measured \(rows)")
        }
        // What it gives exactly. At 26 the pixel in question is 0.489 covered
        // against 127/255 = 0.498: a hundredth of a pixel from the measured 63.
        #expect(Self.calibration.map { WindowCorner.pixels(radius: $0.radius, scale: 2).straightAfter() } == [35, 46, 64])
    }

    @Test func theModelIsTheCornerMeasuredOnChrome() throws {
        let model = WindowCorner.pixels(radius: 20, scale: 2)
        let real = Self.measured(side: model.side)
        try #require(real.count == model.side)
        var worst = 0.0
        for j in 0..<model.side { for i in 0..<model.side { worst = max(worst, abs(model.window[j][i] - real[j][i])) } }
        #expect(worst < 0.08, "a pixel is \(worst) off the capture")
        for (m, r) in zip(rowSums(model.window), rowSums(real)) { #expect(abs(m - r) < 0.12, "a row is \(m - r) px off") }
    }

    /// The same at 16 pt, the other radius measured pixel by pixel, and to
    /// the same tolerance.
    @Test func theModelIsTheCornerMeasuredOnA16PointWindow() throws {
        let model = WindowCorner.pixels(radius: 16, scale: 2)
        let real = Self.measured(Self.app16at2x, side: model.side)
        try #require(real.count == model.side)
        var worst = 0.0
        for j in 0..<model.side { for i in 0..<model.side { worst = max(worst, abs(model.window[j][i] - real[j][i])) } }
        #expect(worst < 0.08, "a pixel is \(worst) off the capture")
        for (m, r) in zip(rowSums(model.window), rowSums(real)) { #expect(abs(m - r) < 0.12, "a row is \(m - r) px off") }
        expectNothingShowsThrough(model, over: real, "the 16 pt capture")
    }

    @Test func aCornerIsClearAtItsPointSolidPastItsRunAndTheSameBothWays() {
        for scale in [CGFloat(1), 2, 3] {
            for radius in [CGFloat(10), 16, 20, 26] {
                let c = WindowCorner.pixels(radius: radius, scale: scale)
                let w = c.window, n = c.side
                #expect(n >= Int((WindowCorner.run * radius * scale).rounded(.up)) + 1, "radius \(radius) at \(scale)x: \(n) px")
                #expect(w[0][0] == 0 && w[n - 1].allSatisfy { $0 == 1 } && w.allSatisfy { $0[n - 1] == 1 })
                for j in 0..<n {
                    for i in 0..<n {
                        #expect(abs(w[j][i] - w[i][j]) < 1e-9)
                        if i > 0 { #expect(w[j][i] >= w[j][i - 1] - 1e-9) }
                    }
                }
            }
        }
    }

    /// The seam notch's rule: the sidebar fully covers every pixel the window
    /// doesn't fully cover, and is only partly drawn where the window is
    /// opaque underneath. Two antialiased edges over each other (window
    /// coverage a under sidebar coverage 1 - a) would let a(1 - a) of the
    /// desktop through, up to a quarter.
    private func expectNothingShowsThrough(_ c: CornerPixels, over window: [[Double]], _ what: String) {
        var worst = 0.0, partlyOverEdge = 0
        for j in 0..<c.side {
            for i in 0..<c.side {
                let m = c.notch[j][i], a = window[j][i]
                worst = max(worst, (1 - m) * (1 - a))
                if m > 0, m < 1, a < CornerPixels.opaque { partlyOverEdge += 1 }
            }
        }
        #expect(worst < 1.0 / 510, "\(what): \(worst) of the desktop shows through a pixel")
        #expect(partlyOverEdge == 0, "\(what): \(partlyOverEdge) partly filled pixels over the window's edge")
    }

    @Test func theNotchFillsEveryPixelTheWindowLeavesOpen() {
        for scale in [CGFloat(1), 2, 3] {
            for radius in [CGFloat(10), 16, 20, 26] {
                let c = WindowCorner.pixels(radius: radius, scale: scale)
                expectNothingShowsThrough(c, over: c.window, "radius \(radius) at \(scale)x")
            }
        }
    }

    /// Against the corner as it was really drawn, not only the model of it.
    @Test func nothingShowsThroughTheMeasuredChromeCorner() {
        let c = WindowCorner.pixels(radius: 20, scale: 2)
        expectNothingShowsThrough(c, over: Self.measured(side: c.side), "the capture")
        // The plain complement of the window's own edge would: that is the leak.
        var complement = 0.0
        let real = Self.measured(side: c.side)
        for j in 0..<c.side { for i in 0..<c.side { complement = max(complement, c.window[j][i] * (1 - real[j][i])) } }
        #expect(complement > 0.2)
    }

    /// The cut is the window's corner moved one device pixel into the window
    /// on both axes: no further.
    @Test func theNotchReachesOnePixelIntoTheWindowAndNoFurther() {
        for (radius, scale) in [(CGFloat(16), CGFloat(2)), (20, 2), (26, 2), (20, 1), (20, 3)] {
            let c = WindowCorner.pixels(radius: radius, scale: scale)
            for j in 0..<c.side {
                for i in 0..<c.side where c.window[j][i] >= CornerPixels.opaque {
                    if i == 0 || j == 0 { #expect(c.notch[j][i] == 0) }
                    else { #expect(abs(c.notch[j][i] - (1 - c.window[j - 1][i - 1])) < 1e-12, "radius \(radius) at \(scale)x, pixel \(i), \(j)") }
                }
            }
        }
    }

    /// Any corner, not only the measured curve: a plain quarter circle.
    @Test func theRuleHoldsForAnyCornerShape() {
        let r = 12.0, n = 14
        let grid: [[Double]] = (0..<n).map { j in
            (0..<n).map { i in
                // Coverage by 8x8 samples: inside when past the arc.
                var inside = 0
                for sy in 0..<8 { for sx in 0..<8 {
                    let x = Double(i) + (Double(sx) + 0.5) / 8, y = Double(j) + (Double(sy) + 0.5) / 8
                    if x >= r || y >= r || (r - x) * (r - x) + (r - y) * (r - y) <= r * r { inside += 1 }
                } }
                return Double(inside) / 64
            }
        }
        let c = CornerPixels(window: grid)
        expectNothingShowsThrough(c, over: grid, "a quarter circle")
        #expect(c.notch[0][0] == 1 && c.notch[n - 1][n - 1] == 0)
    }

    @Test func theEdgeIsStraightFromTheFirstRowWhoseFirstPixelIsMostlyCovered() {
        let c = CornerPixels(window: [[0, 0.2, 1, 1], [0.3, 1, 1, 1], [0.6, 1, 1, 1], [1, 1, 1, 1]])
        #expect(c.straightAfter(over: 0.5) == 2)
        #expect(c.straightAfter(over: 0.7) == 3)
        #expect(CornerPixels(window: [[1, 1], [1, 1]]).straightAfter(over: 0.5) == 0)
    }
}
