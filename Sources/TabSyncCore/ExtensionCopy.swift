import Foundation

/// The Tabs extension as files on this Mac.
///
/// The extension ships inside betterlink.app (Contents/Resources/browser-extension).
/// A browser loads an unpacked extension from a folder and remembers that
/// folder's path, so the app keeps a copy in one fixed folder (`folder`) and
/// replaces its files when the app has a newer version. The browser reads the
/// files again each time it starts; a copy that is running is told to reload
/// (`Command.reloadSelf`). So the extension is loaded once per browser profile
/// and then follows the app.
public enum ExtensionCopy {
    /// Where the browser loads the extension from. The same path on every Mac.
    /// `BETTERLINK_TABS_EXTENSION_DIR` moves it; under `BETTERLINK_HOME` (tests
    /// and development) it is a folder in there, so such a run never replaces
    /// the extension a browser is really using.
    public static var folder: URL { folder(environment: ProcessInfo.processInfo.environment) }

    static func folder(environment: [String: String]) -> URL {
        if let o = environment["BETTERLINK_TABS_EXTENSION_DIR"], !o.isEmpty {
            return URL(fileURLWithPath: o, isDirectory: true)
        }
        if let home = environment["BETTERLINK_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("tabs-extension", isDirectory: true)
        }
        #if os(macOS)
        return URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/betterlink-tabs/extension", isDirectory: true)
        #else
        return URL(fileURLWithPath: NSTemporaryDirectory() + "betterlink-tabs-extension", isDirectory: true)
        #endif
    }

    /// The extension inside an app bundle, or nil when this build has none (a
    /// bare `swift run`).
    public static func bundled(in bundle: Bundle = .main) -> URL? {
        let url = (bundle.resourceURL ?? bundle.bundleURL).appendingPathComponent("browser-extension", isDirectory: true)
        return version(of: url) == nil ? nil : url
    }

    /// The version in a folder's manifest.json, or nil when it holds no extension.
    public static func version(of folder: URL) -> String? {
        manifest(of: folder)?["version"] as? String
    }

    public enum Outcome: Equatable, Sendable {
        /// The folder already holds exactly these files.
        case current
        /// The folder was empty or missing.
        case installed(String)
        case updated(from: String, to: String)
        /// The folder holds a newer version than `source` (another, newer
        /// betterlink put it there). Left alone: never downgrade what the
        /// browser is running.
        case kept(newer: String)
    }

    public enum Failure: Error, Equatable, LocalizedError {
        /// `source` has no manifest.json with a version.
        case noExtension(String)
        /// `destination` holds something other than this extension. Nothing was
        /// written or removed.
        case notOurs(String)

        public var errorDescription: String? {
            switch self {
            case .noExtension: "This build of betterlink has no Tabs extension in it."
            case .notOurs(let path): "\(path) holds something else, so betterlink left it alone."
            }
        }
    }

    /// Makes `destination` hold the extension in `source`.
    ///
    /// manifest.json is written last, so a browser never finds a new version
    /// number beside old scripts. Files the extension no longer has are removed.
    @discardableResult
    public static func refresh(from source: URL, to destination: URL) throws -> Outcome {
        let fm = FileManager.default
        guard let incoming = manifest(of: source), let version = incoming["version"] as? String else {
            throw Failure.noExtension(source.path)
        }
        let wanted = files(in: source)
        let present = files(in: destination)
        let existing = manifest(of: destination)

        // Only ever write into an empty folder or an earlier copy of this
        // extension (the same key), so a wrong path can't cost anyone a file.
        if !present.isEmpty, existing?["key"] as? String != incoming["key"] as? String || existing == nil {
            throw Failure.notOurs(destination.path)
        }
        let old = existing?["version"] as? String
        if let old {
            switch compare(old, version) {
            case .orderedDescending: return .kept(newer: old)
            case .orderedSame where wanted == present && wanted.allSatisfy({ same($0, source, destination) }): return .current
            default: break
            }
        }

        for path in wanted.sorted() where path != manifestName {
            try copy(path, from: source, to: destination)
        }
        for path in present.subtracting(wanted) {
            try? fm.removeItem(at: destination.appendingPathComponent(path))
        }
        try copy(manifestName, from: source, to: destination)
        return old.map { .updated(from: $0, to: version) } ?? .installed(version)
    }

    /// Whether to tell a connected copy of the extension to reload: it runs
    /// another version than the folder holds, and it knows how. The extension
    /// checks its own files before it does, so a copy loaded from somewhere
    /// else says no.
    public static func shouldReload(running: String?, folderVersion: String?, canReload: Bool) -> Bool {
        guard canReload, let running, let folderVersion else { return false }
        return running != folderVersion
    }

    /// Dotted version numbers, compared part by part ("0.10.0" is after "0.9.1").
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    // MARK: - internals

    private static let manifestName = "manifest.json"

    private static func manifest(of folder: URL) -> [String: Any]? {
        guard let d = try? Data(contentsOf: folder.appendingPathComponent(manifestName)) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    /// Every regular file under `folder`, as paths relative to it.
    private static func files(in folder: URL) -> Set<String> {
        guard let names = FileManager.default.enumerator(atPath: folder.path) else { return [] }
        var out: Set<String> = []
        for case let name as String in names {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path, isDirectory: &isDir), !isDir.boolValue {
                out.insert(name)
            }
        }
        return out
    }

    private static func same(_ path: String, _ a: URL, _ b: URL) -> Bool {
        guard let x = try? Data(contentsOf: a.appendingPathComponent(path)),
              let y = try? Data(contentsOf: b.appendingPathComponent(path)) else { return false }
        return x == y
    }

    private static func copy(_ path: String, from source: URL, to destination: URL) throws {
        let to = destination.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contentsOf: source.appendingPathComponent(path)).write(to: to, options: .atomic)
    }
}
