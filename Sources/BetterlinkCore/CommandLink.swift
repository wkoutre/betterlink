import Foundation

/// The link Install Command puts in ~/.local/bin, pointing at the command
/// inside the app. It only ever replaces or removes a link to some copy of
/// betterlink's own command (a path ending in `.app/Contents/Helpers/betterlink`);
/// a real file, or another tool's link, is left alone.
public struct CommandLink: Sendable {
    public enum Status: Equatable, Sendable {
        case installed
        case notInstalled
        /// A link to another copy of betterlink (the app moved, or an old copy).
        case pointsElsewhere(String)
        /// A real file, or a link to something that isn't betterlink.
        case blocked
    }

    public struct Problem: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public let link: URL
    public let bundled: URL

    public init(link: URL, bundled: URL) {
        self.link = link
        self.bundled = bundled
    }

    /// Where the link points, resolved against its folder; nil when it isn't a link.
    private func target() -> URL? {
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else { return nil }
        return URL(fileURLWithPath: dest, relativeTo: link.deletingLastPathComponent()).standardizedFileURL
    }

    private static func isBetterlinkCommand(_ u: URL) -> Bool {
        u.path.hasSuffix(".app/Contents/Helpers/betterlink")
    }

    public func status() -> Status {
        let fm = FileManager.default
        guard let t = target() else {
            return fm.fileExists(atPath: link.path) ? .blocked : .notInstalled
        }
        if t.path == bundled.standardizedFileURL.path && fm.isExecutableFile(atPath: t.path) { return .installed }
        return Self.isBetterlinkCommand(t) ? .pointsElsewhere(t.path) : .blocked
    }

    public func install() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: bundled.path) else {
            throw Problem(message: "This copy of betterlink has no bundled command.")
        }
        switch status() {
        case .blocked:
            throw Problem(message: "\(link.path) already exists and isn't betterlink's link, so it was left alone.")
        case .installed, .pointsElsewhere:
            try fm.removeItem(at: link)
        case .notInstalled:
            try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try fm.createSymbolicLink(at: link, withDestinationURL: bundled)
    }

    public func uninstall() throws {
        switch status() {
        case .installed, .pointsElsewhere: try FileManager.default.removeItem(at: link)
        case .notInstalled: return
        case .blocked: throw Problem(message: "\(link.path) isn't betterlink's link, so it was left alone.")
        }
    }
}
