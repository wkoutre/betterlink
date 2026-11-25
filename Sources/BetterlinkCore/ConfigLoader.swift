import Foundation

/// The folder that holds all of betterlink's settings: rules.json (Link
/// Rules and profiles), the optional config.ts, and the betterlink.d.ts and
/// tsconfig.json betterlink writes there for editors.
public struct SettingsFolder: Equatable, Sendable {
    public let directory: URL
    public var rulesFile: URL { directory.appendingPathComponent("rules.json") }
    public var configFile: URL { directory.appendingPathComponent("config.ts") }
    public var declarationsFile: URL { directory.appendingPathComponent("betterlink.d.ts") }
    public var tsconfigFile: URL { directory.appendingPathComponent("tsconfig.json") }

    public init(directory: URL) { self.directory = directory }

    /// The macOS standard place for an app's own files.
    public static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/betterlink")

    /// The UserDefaults key holding a folder the user chose.
    public static let defaultsKey = "settingsFolder"

    /// `BETTERLINK_HOME` wins (for tests and development), then the folder
    /// the user chose, then the standard one.
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                               defaults: UserDefaults = .standard) -> SettingsFolder {
        if let home = environment["BETTERLINK_HOME"], !home.isEmpty {
            return SettingsFolder(directory: URL(fileURLWithPath: (home as NSString).expandingTildeInPath, isDirectory: true))
        }
        if let chosen = defaults.string(forKey: defaultsKey), !chosen.isEmpty {
            return SettingsFolder(directory: URL(fileURLWithPath: chosen, isDirectory: true))
        }
        return SettingsFolder(directory: defaultDirectory)
    }

    /// Before 0.2, config.ts lived in ~/.config/betterlink. Copies it here once
    /// when this folder has none, and says whether it did.
    @discardableResult
    public func adoptLegacyConfig(from legacy: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/betterlink/config.ts")) throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: configFile.path) else { return false }
        // Copying must not turn a file betterlink would refuse into one it trusts.
        if let problem = FileSafety.problem(with: legacy) { throw ConfigError.unsafeFile("Didn't copy the old config.ts: \(problem).") }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.copyItem(at: legacy, to: configFile)
        return true
    }

    /// Copies rules.json and config.ts into `target` where it has none, so
    /// switching folders keeps the user's settings. Refuses a folder that
    /// FileSafety would refuse to read from. A file that is a symlink (into
    /// a dotfiles repo, say) is linked again, not copied: see below.
    public func copySettings(to target: SettingsFolder) throws {
        let fm = FileManager.default
        let sidebar = directory.appendingPathComponent("sidebar.json")
        let copies = [(rulesFile, target.rulesFile), (configFile, target.configFile),
                      (sidebar, target.directory.appendingPathComponent("sidebar.json"))]
            .filter { fm.fileExists(atPath: $0.0.path) && !fm.fileExists(atPath: $0.1.path) }
        // Copying must not turn a file betterlink would refuse into one it trusts.
        for (from, _) in copies {
            if let problem = FileSafety.problem(with: from) { throw ConfigError.unsafeFile("Didn't switch: \(problem).") }
        }
        // Check a folder that already exists before touching it. One betterlink
        // creates is private to the user (0700), so it passes.
        if fm.fileExists(atPath: target.directory.path), let problem = FileSafety.folderProblem(target.directory) {
            throw ConfigError.unsafeFile("Can't use that folder: \(problem).")
        }
        try fm.createDirectory(at: target.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let problem = FileSafety.folderProblem(target.directory) {
            throw ConfigError.unsafeFile("Can't use that folder: \(problem).")
        }
        for (from, to) in copies {
            if (try? fm.destinationOfSymbolicLink(atPath: from.path)) != nil {
                // Link to the same file, by its full path (a relative link
                // would point nowhere from the new folder). Never copy what a
                // link points to: any program can put a link to a file only
                // betterlink may read (with Full Disk Access) in a settings
                // folder, and a copy would hand it that file's contents.
                try fm.createSymbolicLink(at: to, withDestinationURL: from.resolvingSymlinksInPath())
            } else {
                try fm.copyItem(at: from, to: to)
            }
        }
    }
}

public enum FileSafety {
    /// Why betterlink refuses to read this file, or nil when it is safe: the
    /// file (after following symlinks) and its folder must belong to the
    /// current user and not be writable by anyone else.
    public static func problem(with url: URL, uid: uid_t = getuid()) -> String? {
        let real = url.resolvingSymlinksInPath()
        return check(real.path, "\(url.lastPathComponent)", uid)
            ?? check(real.deletingLastPathComponent().path, "the folder holding \(url.lastPathComponent)", uid)
    }

    /// The same check for a settings folder on its own.
    public static func folderProblem(_ url: URL, uid: uid_t = getuid()) -> String? {
        check(url.resolvingSymlinksInPath().path, "the folder \(url.lastPathComponent)", uid)
    }

    private static func check(_ path: String, _ what: String, _ uid: uid_t) -> String? {
        var st = stat()
        guard stat(path, &st) == 0 else { return "can't read \(what)" }
        if st.st_uid != uid { return "\(what) is not owned by you" }
        if st.st_mode & (S_IWGRP | S_IWOTH) != 0 { return "\(what) can be changed by other users (run chmod go-w on it)" }
        return nil
    }
}

public enum ConfigLoadResult: Sendable {
    /// No config.ts: routing uses the editor rules only.
    case absent
    case loaded(ConfigScript)
    case failed(ConfigError)
}

public enum ConfigLoader {
    /// - Parameter timeLimitAvailable: whether a looping script can be
    ///   stopped. Without that, config.ts is not used at all, because one
    ///   loop would freeze every link.
    public static func load(paths: SettingsFolder, compiler: TypeScriptCompiler, catalog: ProfileCatalog,
                            timeLimitAvailable: Bool = ConfigScript.hasTimeLimit,
                            log: (@Sendable (String) -> Void)? = nil) -> ConfigLoadResult {
        let file = paths.configFile
        guard FileManager.default.fileExists(atPath: file.path) else { return .absent }
        guard timeLimitAvailable else {
            return .failed(.engine("config.ts is not used: this macOS doesn't offer betterlink a time limit for scripts."))
        }
        if let problem = FileSafety.problem(with: file) { return .failed(.unsafeFile("Refused config.ts: \(problem).")) }
        guard let source = try? String(contentsOf: file, encoding: .utf8) else {
            return .failed(.unsafeFile("Couldn't read config.ts as UTF-8 text."))
        }
        let out = compiler.compile(source, declarations: configDeclarations(catalog: catalog))
        guard let js = out.javascript else { return .failed(.compile(out.errors)) }
        do { return .loaded(try ConfigScript(javascript: js, log: log)) }
        catch let e as ConfigError { return .failed(e) }
        catch { return .failed(.engine("\(error)")) }
    }

    /// Writes betterlink.d.ts and tsconfig.json next to config.ts so an editor
    /// type-checks and autocompletes it the same way betterlink does.
    public static func writeEditorSupport(paths: SettingsFolder, catalog: ProfileCatalog) throws {
        try FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try configDeclarations(catalog: catalog).write(to: paths.declarationsFile, atomically: true, encoding: .utf8)
        let tsconfig = """
        {
          "compilerOptions": { "target": "ES2020", "module": "CommonJS", "lib": ["ES2020"], "types": [], "strict": true, "noEmit": true },
          "files": ["config.ts", "betterlink.d.ts"]
        }

        """
        try tsconfig.write(to: paths.tsconfigFile, atomically: true, encoding: .utf8)
    }

    public static let starterConfig = """
    // betterlink runs this before your Link Rules. Return a profile name to
    // open the link there, or undefined to let the Link Rules decide.
    // Types are in betterlink.d.ts. console.log output shows in the log view.
    export default function route(link: Link): Target | undefined {
      return undefined;
    }

    """
}
