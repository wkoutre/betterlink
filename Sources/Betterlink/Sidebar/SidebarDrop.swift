import AppKit
import BetterlinkCore
import SwiftUI
import UniformTypeIdentifiers

/// Where a drag over a sidebar row would land, relative to that row.
enum DropZone: Equatable {
    case before, after, into

    /// For a row `extent` long along the drag axis, at `offset` along it.
    /// Folders take what lands on their middle; links and favorites only go
    /// before or after.
    static func at(_ offset: CGFloat, extent: CGFloat, canHold: Bool) -> DropZone {
        guard extent > 0 else { return .after }
        let f = offset / extent
        if canHold { return f < 0.25 ? .before : (f > 0.75 ? .after : .into) }
        return f < 0.5 ? .before : .after
    }
}

/// The row a drag is over and where in it, for the insertion line.
struct DropTarget: Equatable {
    var id: UUID
    var zone: DropZone
}

/// One row's drop handling: reports where the drag is as it moves (so the
/// sidebar can draw the line), and hands over the dragged strings on drop.
struct SidebarRowDrop: DropDelegate {
    let id: UUID
    let size: CGSize
    let horizontal: Bool
    let canHold: Bool
    @Binding var target: DropTarget?
    let allowed: (DropZone) -> Bool
    let perform: ([String], DropZone) -> Void

    private func zone(_ info: DropInfo) -> DropZone {
        horizontal ? .at(info.location.x, extent: size.width, canHold: canHold)
                   : .at(info.location.y, extent: size.height, canHold: canHold)
    }

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.plainText]) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let z = zone(info)
        guard allowed(z) else {
            if target?.id == id { target = nil }
            return DropProposal(operation: .forbidden)
        }
        let t = DropTarget(id: id, zone: z)
        if target != t { target = t }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { if target?.id == id { target = nil } }

    func performDrop(info: DropInfo) -> Bool {
        let z = zone(info)
        target = nil
        guard allowed(z) else { return false }
        let providers = info.itemProviders(for: [.plainText])
        guard !providers.isEmpty else { return false }
        // Each in its provider's slot: several dropped at once keep their order (review F3).
        var keys = [String?](repeating: nil, count: providers.count)
        let group = DispatchGroup()
        let lock = NSLock()
        for (i, p) in providers.enumerated() {
            group.enter()
            _ = p.loadObject(ofClass: NSString.self) { s, _ in
                if let s = s as? String { lock.lock(); keys[i] = s; lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { perform(keys.compactMap { $0 }, z) }
        return true
    }
}

/// The insertion line (before or after) or the outline (into) on a row.
struct DropMarker: View {
    let zone: DropZone?
    let horizontal: Bool
    let color: Color

    var body: some View {
        GeometryReader { g in
            switch zone {
            case .before?:
                Capsule().fill(color)
                    .frame(width: horizontal ? 2 : g.size.width, height: horizontal ? g.size.height : 2)
                    .position(x: horizontal ? 0 : g.size.width / 2, y: horizontal ? g.size.height / 2 : 0)
            case .after?:
                Capsule().fill(color)
                    .frame(width: horizontal ? 2 : g.size.width, height: horizontal ? g.size.height : 2)
                    .position(x: horizontal ? g.size.width : g.size.width / 2, y: horizontal ? g.size.height / 2 : g.size.height)
            case .into?:
                RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(color, lineWidth: 1.5)
            case nil:
                EmptyView()
            }
        }
        .allowsHitTesting(false)
    }
}

/// A sidebar row as a drop target: measures the row, follows the drag over it,
/// and draws the insertion line where the drop would land.
struct DropRowModifier: ViewModifier {
    let id: UUID
    let horizontal: Bool
    let canHold: Bool
    let color: Color
    let size: CGSize
    @Binding var target: DropTarget?
    let measured: (CGSize) -> Void
    let allowed: (DropZone) -> Bool
    let perform: ([String], DropZone) -> Void

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { measured($0) }
            .onDrop(of: [.plainText], delegate: SidebarRowDrop(id: id, size: size, horizontal: horizontal,
                                                              canHold: canHold, target: $target, allowed: allowed, perform: perform))
            .overlay { DropMarker(zone: target?.id == id ? target?.zone : nil, horizontal: horizontal, color: color) }
    }
}
