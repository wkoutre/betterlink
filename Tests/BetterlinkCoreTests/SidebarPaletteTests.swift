import Foundation
import Testing
@testable import BetterlinkCore

struct SidebarPaletteTests {
    // The two Chrome profiles on the Mac mini, plus pale, saturated and grey colors.
    let colors: [UInt32] = [0xB71C1C, 0x2F1B0C, 0x6D1212, 0xFF8000, 0xFFE082, 0x1565C0, 0x00C853, 0xFFFFFF, 0x000000, 0x808080, 0xE91E63]

    @Test func theSystemSchemeFollowsTheTextColor() {
        // Light text (dark profile) wants the dark scheme, so system text fields read.
        #expect(SidebarPalette(profileColor: 0x2F1B0C).wantsDarkScheme)
        #expect(!SidebarPalette(profileColor: 0xFFE082).wantsDarkScheme)
    }

    @Test func everyTextLevelMeetsWCAG_AA() {
        for c in colors {
            let p = SidebarPalette(profileColor: c)
            for level in [1.0, SidebarPalette.secondaryOpacity, SidebarPalette.tertiaryOpacity] {
                let ratio = SidebarPalette.contrast(p.level(level), p.background)
                #expect(ratio >= SidebarPalette.minimumContrast, "\(String(c, radix: 16)) at \(level): \(ratio)")
            }
        }
    }

    @Test func aColorThatAlreadyPassesIsKept() {
        // The Claude profile's dark brown: white text already reads.
        #expect(SidebarPalette(profileColor: 0x2F1B0C).background.hex == 0x2F1B0C)
    }

    @Test func aStrongRedIsTonedDownKeepingItsHue() {
        let p = SidebarPalette(profileColor: 0xB71C1C)
        #expect(p.background.hex != 0xB71C1C)
        let (h0, _, l0) = SidebarPalette.hsl(.init(hex: 0xB71C1C)), (h1, _, l1) = SidebarPalette.hsl(p.background)
        #expect(abs(h0 - h1) < 0.01)
        #expect(l1 < l0)
    }

    @Test func paleColorsGetDarkText() {
        let p = SidebarPalette(profileColor: 0xFFE082)
        #expect(SidebarPalette.luminance(p.foreground) < 0.1)
    }

    @Test func whiteOnRedContrastMatchesTheWCAGFormula() {
        // Reference: white on #B71C1C is 6.6:1 by the WCAG formula.
        let r = SidebarPalette.contrast(.init(1, 1, 1), .init(hex: 0xB71C1C))
        #expect(abs(r - 6.6) < 0.1)
    }
}
