import Foundation

/// What a row dragged from the sidebar carries: its key, as data of a type
/// only betterlink reads. As plain text, a web page the row was dropped on
/// opened "betterlink-saved:…" as an address.
public enum SidebarDrag {
    /// Declared in Info.plist (UTExportedTypeDeclarations) as data only: never
    /// text or a URL, which other apps take.
    public static let typeIdentifier = "com.wkoutre.betterlink.sidebar-item"

    public static func data(for key: String) -> Data { Data(key.utf8) }

    /// Several rows dragged as one (the picked rows): their keys, one to a
    /// line, in the order they are on screen.
    public static func joined(_ keys: [String]) -> String { keys.joined(separator: "\n") }

    /// The keys a drag carries: one, or several picked rows' (`joined`).
    public static func keys(in key: String) -> [String] {
        key.split(separator: "\n").map(String.init)
    }

    /// The key in dropped data, or nil when there is none to read.
    public static func key(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
