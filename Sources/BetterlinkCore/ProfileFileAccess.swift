import Foundation

/// Whether this process can read a browser's profile list, and if not, why.
///
/// Chrome's and Brave's "Local State" sit in ~/Library/Application Support,
/// which macOS does not normally guard, so a failed read is not always about
/// Full Disk Access: on a managed Mac, security software can refuse it with
/// Full Disk Access granted. The errno tells the cases apart, so the app can
/// say which one it is instead of always blaming Full Disk Access.
public enum ProfileFileAccess: Equatable, Sendable {
    case readable
    /// No file there: the browser was never opened.
    case missing
    /// The system refused (EPERM): a privacy grant is missing, or security
    /// software blocks the read.
    case blocked
    /// The file's own permissions refuse this user (EACCES).
    case filePermissions
    /// Any other failure, with the system's description.
    case failed(String)

    /// Opens `url` and reads one byte, so a block at read time counts too.
    public static func check(_ url: URL) -> ProfileFileAccess {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return classify(errno: errno) }
        defer { close(fd) }
        var byte: UInt8 = 0
        return read(fd, &byte, 1) >= 0 ? .readable : classify(errno: errno)
    }

    public static func classify(errno code: Int32) -> ProfileFileAccess {
        switch code {
        case ENOENT, ENOTDIR: return .missing
        case EPERM: return .blocked
        case EACCES: return .filePermissions
        default: return .failed(String(cString: strerror(code)))
        }
    }

    /// A short status for the Permissions page.
    public func badge(fullDiskAccess: Bool?) -> String {
        switch self {
        case .readable: return "Readable"
        case .missing: return "No profiles yet"
        case .blocked: return fullDiskAccess == true ? "Blocked" : "Not allowed"
        case .filePermissions: return "No permission"
        case .failed: return "Can't read"
        }
    }

    /// What is wrong and what to do, or nil when nothing is.
    public func explanation(browser: String, fullDiskAccess: Bool?) -> String? {
        switch self {
        case .readable, .missing:
            return nil
        case .blocked where fullDiskAccess == true:
            return "Full Disk Access is on, but something else on this Mac blocks reading \(browser)'s profiles, "
                + "usually a work Mac's security software. Add profiles by hand, or ask IT to allow betterlink."
        case .blocked:
            return "macOS blocks reading \(browser)'s profiles. Allow Full Disk Access, then quit and reopen betterlink."
        case .filePermissions:
            return "\(browser)'s profile list isn't readable by your user account (its file permissions). Add profiles by hand."
        case .failed(let reason):
            return "Couldn't read \(browser)'s profiles: \(reason)."
        }
    }
}

/// Whether this process has Full Disk Access.
public enum FullDiskAccess {
    /// The user's TCC database: only a process with Full Disk Access may open it.
    public static func probeFile(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
    }

    /// True or false by opening the probe file; nil when it can't tell (no
    /// probe file, or an unexpected error).
    public static func isGranted(probe: URL = probeFile()) -> Bool? {
        switch ProfileFileAccess.check(probe) {
        case .readable: return true
        case .blocked: return false
        case .missing, .filePermissions, .failed: return nil
        }
    }
}
