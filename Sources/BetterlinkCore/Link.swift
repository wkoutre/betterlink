import Foundation

/// A web link after betterlink has parsed it the way a browser would.
///
/// `href` is rebuilt from the parsed parts, and it is the string betterlink
/// hands to the browser, so the browser loads exactly the host the rules saw.
public struct Link: Equatable, Sendable {
    public let scheme: String   // "http" or "https"
    public let host: String     // lowercase ASCII, no trailing dot
    public let port: Int?       // nil when absent or the scheme's default
    public let path: String     // starts with "/"
    public let query: String?   // without the "?"
    public let fragment: String? // without the "#"

    public var href: String {
        var s = "\(scheme)://\(host)"
        if let port { s += ":\(port)" }
        s += path
        if let query { s += "?" + query }
        if let fragment { s += "#" + fragment }
        return s
    }
}

/// What a raw string the system handed betterlink turned out to be.
public enum ParsedInput: Equatable, Sendable {
    /// An http(s) link with a host betterlink can match rules against.
    case web(Link)
    /// A local file (macOS hands the default browser `.html` files too).
    case file(String)
    /// Looks like an http(s) link, but the host is not one betterlink can
    /// read with certainty. It may open, but only in the fallback profile.
    case unroutable(String, reason: String)
    /// Not something a browser should open (`javascript:`, `ftp:`, junk).
    case refused(reason: String)
}
