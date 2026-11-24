import Darwin
import Foundation

/// Reading and replacing config.ts without losing what someone saves to it
/// meanwhile. Editors take no lock, so a compare followed by a write leaves a
/// gap. Instead the new text is written under the backup's name and the two
/// files change places in one step (renamex_np): what was displaced is already
/// the backup, and is then compared.
///
/// It must be the backup's own name, not a temporary one: a Foundation save in
/// progress follows the file it opened, so when that file is displaced the
/// save can land under its new name. There it is a visible .bak.
enum ConfigSwap {
    /// The file was no longer what the caller read.
    struct Changed: Error {}

    /// The text at `url`, nil when there is no file. Throws when there is one
    /// that can't be read as text: that isn't the same as no file.
    static func read(_ url: URL) throws -> String? {
        let data: Data
        do { data = try Data(contentsOf: url.resolvingSymlinksInPath()) } catch CocoaError.fileReadNoSuchFile { return nil }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ConfigError.unsafeFile("\(url.lastPathComponent) isn't UTF-8 text.")
        }
        return text
    }

    /// Puts `new` (nil: no file) where `expected` (nil: no file) is, and
    /// returns the backup of what it replaced (none for an empty file). Throws
    /// `Changed`, with the file as someone else left it, when it wasn't
    /// `expected`. A symlink stays one: the file it points to is replaced, and
    /// the backup is beside that file.
    static func replace(_ url: URL, expected: String?, with new: String?, backup name: String) throws -> URL? {
        let real = url.resolvingSymlinksInPath(), dir = real.deletingLastPathComponent()
        switch (expected, new) {
        case (nil, nil):
            return nil
        case (nil, let new?):
            let temp = dir.appendingPathComponent(".\(real.lastPathComponent).\(UUID().uuidString).tmp")
            try Data(new.utf8).write(to: temp, options: .withoutOverwriting)
            if move(temp, real, RENAME_EXCL) { return nil }
            let e = errno
            unlink(temp.path) // only our own text
            if e == EEXIST { throw Changed() }
            throw failure(e)
        case (let expected?, nil):
            let bak = try claim(dir, name) { move(real, $0, RENAME_EXCL) }
            guard let bak else { throw Changed() } // gone already
            if text(bak) == expected { return try backup(bak, expected) }
            // Not what was read: back where it was, unless a newer one is
            // there (then it stays as a backup).
            _ = move(bak, real, RENAME_EXCL)
            throw Changed()
        case (let expected?, let new?):
            let bak = try claim(dir, name) { bak in
                do { try Data(new.utf8).write(to: bak, options: .withoutOverwriting); return true }
                catch CocoaError.fileWriteFileExists { errno = EEXIST; return false }
            }
            guard let bak else { throw Changed() }
            if let mode = try? FileManager.default.attributesOfItem(atPath: real.path)[.posixPermissions] {
                try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: bak.path)
            }
            guard move(bak, real, RENAME_SWAP) else {
                let e = errno
                discard(bak, new)
                if e == ENOENT { throw Changed() }
                throw failure(e)
            }
            if text(bak) == expected { return try backup(bak, expected) }
            // Someone saved meanwhile: theirs goes back. What comes out should
            // be our text; anything else is a newer save, which gets its place
            // again, and the older one stays as a backup.
            guard move(bak, real, RENAME_SWAP) else { _ = move(bak, real, RENAME_EXCL); throw Changed() }
            if !discard(bak, new) { _ = move(bak, real, RENAME_SWAP) }
            throw Changed()
        }
    }

    private static func text(_ url: URL) -> String? { (try? read(url)) ?? nil }

    /// The displaced file, as its backup; an empty one needs none.
    private static func backup(_ bak: URL, _ text: String) throws -> URL? {
        text.isEmpty && discard(bak, text) ? nil : bak
    }

    /// The first backup name nothing has that `take` can have: nil when there
    /// is nothing to take.
    private static func claim(_ dir: URL, _ name: String, _ take: (URL) throws -> Bool) throws -> URL? {
        for n in 1... {
            let bak = dir.appendingPathComponent(n == 1 ? "\(name).bak" : "\(name)-\(n).bak")
            if try take(bak) { return bak }
            let e = errno
            if e == ENOENT { return nil }
            guard e == EEXIST else { throw failure(e) }
        }
        return nil
    }

    /// Deletes `url` only if it holds `text`, checked once it is out of the
    /// way, so a save that lands on it meanwhile is never deleted.
    @discardableResult
    private static func discard(_ url: URL, _ text: String) -> Bool {
        let aside = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        guard move(url, aside, RENAME_EXCL) else { return true } // gone
        if self.text(aside) == text { unlink(aside.path); return true }
        if !move(aside, url, RENAME_EXCL) {
            // Something has that name again: both stay, as backups.
            _ = move(aside, url.deletingPathExtension().appendingPathExtension("\(UUID().uuidString).bak"), RENAME_EXCL)
        }
        return false
    }

    private static func move(_ a: URL, _ b: URL, _ flags: Int32) -> Bool { renamex_np(a.path, b.path, UInt32(flags)) == 0 }
    private static func failure(_ e: Int32) -> ConfigError { .unsafeFile("Couldn't replace config.ts (\(String(cString: strerror(e)))).") }
}
