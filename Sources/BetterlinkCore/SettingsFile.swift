import Foundation

/// Writing a JSON file in the settings folder safely; shared by rules.json and
/// sidebar.json.
public enum SettingsFile {
    /// Pretty-printed JSON, readable only by the user. When the file is a
    /// symlink (into a dotfiles repo, say), the file it points to is written:
    /// an atomic write to the link itself would replace the link with a plain
    /// file and leave its target stale. A link to a file that isn't there is
    /// refused: saving would create that file wherever the link points, with
    /// betterlink's own permissions, and any program can plant such a link in a
    /// settings folder. (fileExists follows the link, so it is false for one.)
    public static func write<T: Encodable>(_ value: T, to file: URL, what: String) throws {
        let dir = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let fm = FileManager.default
        if let destination = try? fm.destinationOfSymbolicLink(atPath: file.path), !fm.fileExists(atPath: file.path) {
            throw ConfigError.unsafeFile("Refused to save \(what): it is a link to \(destination), which doesn't exist. Create that file or remove the link.")
        }
        let target = file.resolvingSymlinksInPath()
        try enc.encode(value).write(to: target, options: [.atomic])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    /// Runs `body` holding an exclusive lock on a file beside `file`, so the app
    /// and the CLI (an agent) never interleave a read-change-write.
    public static func withLock<T>(beside file: URL, name: String, what: String, _ body: () throws -> T) throws -> T {
        let dir = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(dir.appendingPathComponent(name).path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { throw ConfigError.unsafeFile("Couldn't lock \(what) (\(String(cString: strerror(errno)))).") }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw ConfigError.unsafeFile("Couldn't lock \(what) (\(String(cString: strerror(errno)))).") }
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
