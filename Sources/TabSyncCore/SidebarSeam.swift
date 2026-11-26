import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Where a sidebar panel meets its browser window. Beside the window the
/// panel lies under it and reaches under its edge, past the window's rounded
/// corners: the window draws its own corners over the sidebar, whatever
/// their shape, and nothing shows between the two. Pure math over Cocoa
/// frames, so it is unit tested.
public enum SidebarSeam {
    /// `v` on the nearest pixel of a screen with `scale` pixels per point.
    public static func aligned(_ v: CGFloat, scale: CGFloat) -> CGFloat {
        scale > 0 ? (v * scale).rounded() / scale : v
    }

    /// How far the panel reaches under its window: as far as a window
    /// corner's curve runs along the edge (`cornerExtent`), rounded up to
    /// whole pixels.
    public static func overlap(cornerExtent: CGFloat, scale: CGFloat) -> CGFloat {
        scale > 0 ? (max(0, cornerExtent) * scale).rounded(.up) / scale : max(0, cornerExtent)
    }

    /// The overlap for a sidebar placed at `p`, on its screen's pixels. None
    /// when it covers the window's edge: it lies on top then.
    public static func overlap(for p: SidebarPlacement, cornerExtent: CGFloat) -> CGFloat {
        p.overlaps ? 0 : overlap(cornerExtent: cornerExtent, scale: p.scale)
    }

    /// The panel's frame: the sidebar and, on the window's side, `overlap`
    /// more under the window. Top and bottom stay the sidebar's, which are
    /// the window's (`SidebarGeometry.place`).
    public static func panel(for p: SidebarPlacement, overlap: CGFloat) -> CGRect {
        var f = p.sidebar
        f.size.width += overlap
        if p.side == .right { f.origin.x -= overlap }
        return f
    }

    /// Where a slide's mask opens the panel from (screen x): `seam`, where
    /// this moment of the slide puts the sidebar's inner edge. While that is
    /// the window's own edge (`windowEdge`), `overlap` further under the
    /// window, so the window's corners stay filled as it moves. Ahead of the
    /// window there is nothing over the panel, and no more of it shows.
    public static func reveal(seam: CGFloat, windowEdge: CGFloat?, overlap: CGFloat, side: SidebarSide) -> CGFloat {
        guard let windowEdge, abs(seam - windowEdge) < 0.5 else { return seam }
        return side == .right ? seam - overlap : seam + overlap
    }
}
