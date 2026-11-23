import Foundation

/// Parses links following the parts of the WHATWG URL standard that decide the
/// host for http and https, which is what Chromium browsers implement.
///
/// The rule for anything it can't read with certainty: return `.unroutable`,
/// which only ever opens in the fallback profile. Disagreeing with the browser
/// in that direction is safe. Disagreeing the other way would let a crafted
/// link open some other site in a profile a rule protects.
///
/// Finch, which betterlink is derived from, cut the host out with string
/// searches that ignored `\`. Browsers treat `\` as `/` in http(s) links, so
/// `https://evil.com\@acme.com/` routed as acme.com but loaded evil.com.
public enum LinkParser {
    public static func parse(_ raw: String) -> ParsedInput {
        // WHATWG: strip leading and trailing C0 controls and spaces, then
        // remove every tab and newline anywhere in the input.
        var s = Substring(raw)
        while let f = s.unicodeScalars.first, f.value <= 0x20 { s = s.dropFirst() }
        while let l = s.unicodeScalars.last, l.value <= 0x20 { s = s.dropLast() }
        let cleaned = String(String.UnicodeScalarView(s.unicodeScalars.filter { $0 != "\t" && $0 != "\n" && $0 != "\r" }))

        // Delimiters are compared as Unicode scalars, never as Characters: a
        // "/" followed by a combining mark is one Character that isn't "/",
        // but the browser still ends the host at that "/".
        let u = Array(cleaned.unicodeScalars)
        guard let colon = u.firstIndex(of: ":") else { return .refused(reason: "no scheme") }
        let scheme = text(u[..<colon]).lowercased()
        guard let first = scheme.unicodeScalars.first, isAlpha(first),
              scheme.unicodeScalars.allSatisfy({ isAlpha($0) || isDigit($0) || "+-.".unicodeScalars.contains($0) })
        else { return .refused(reason: "no scheme") }

        if scheme == "file" { return .file(cleaned) }
        guard scheme == "http" || scheme == "https" else { return .refused(reason: "scheme \(scheme) is not opened in a browser") }

        // Rebuilt from parts below; `cleaned` is what the browser will see if
        // the link is unroutable and still opens in the fallback profile.
        func unroutable(_ why: String) -> ParsedInput { .unroutable(cleaned, reason: why) }

        // For http(s), WHATWG skips any run of "/" and "\" after the scheme,
        // so "https:evil.com", "https:/evil.com" and "https:\\evil.com" all
        // have the host evil.com.
        var start = colon + 1
        while start < u.count, u[start] == "/" || u[start] == "\\" { start += 1 }

        // The authority ends at the first "/", "\", "?" or "#".
        let authEnd = u[start...].firstIndex(where: { $0 == "/" || $0 == "\\" || $0 == "?" || $0 == "#" }) ?? u.count

        // Credentials end at the LAST "@". They are dropped from the link
        // betterlink opens: they only ever disguise the real host.
        if let at = u[start..<authEnd].lastIndex(of: "@") { start = at + 1 }

        // Port: after the last ":" outside IPv6 brackets.
        var hostEnd = authEnd
        var port: Int?
        if let c = u[start..<authEnd].lastIndex(of: ":"), !u[c..<authEnd].contains("]") {
            hostEnd = c
            let digits = u[(c + 1)..<authEnd]
            if !digits.isEmpty {
                guard digits.allSatisfy(isDigit), let p = Int(text(digits)), p <= 65535 else {
                    return unroutable("invalid port")
                }
                port = p
            }
        }
        if port == 80 && scheme == "http" || port == 443 && scheme == "https" { port = nil }

        guard let host = canonicalHost(text(u[start..<hostEnd])) else { return unroutable("host is not plain ASCII DNS name or IP address") }

        // Path, query and fragment. "\" counts as "/" in the path only.
        var pathEnd = u.count
        var query: String?
        var fragment: String?
        if let h = u[authEnd...].firstIndex(of: "#") { fragment = text(u[(h + 1)...]); pathEnd = h }
        if let q = u[authEnd..<pathEnd].firstIndex(of: "?") { query = text(u[(q + 1)..<pathEnd]); pathEnd = q }
        let path = removingDotSegments(u[authEnd..<pathEnd].map { (c: Unicode.Scalar) -> Unicode.Scalar in c == "\\" ? "/" : c })
        // Each part is percent-encoded with the WHATWG set for that part, so
        // the rebuilt link keeps what a browser keeps ("[]" in a query, "#" in
        // a fragment) and encodes what it encodes (spaces, quotes, non-ASCII).
        let link = Link(scheme: scheme, host: host, port: port,
                        path: encode(path, pathEncodeSet),
                        query: query.map { encode($0, queryEncodeSet) },
                        fragment: fragment.map { encode($0, fragmentEncodeSet) })
        return .web(link)
    }

    /// The path a browser loads: WHATWG drops "." segments and lets ".."
    /// remove the segment before it, so /billing/../admin is /admin. "%2e"
    /// counts as ".". Returns a path starting with "/".
    static func removingDotSegments(_ scalars: [Unicode.Scalar]) -> String {
        // Split on "/" scalars, like the parser above.
        let body = scalars.first == Unicode.Scalar("/") ? scalars.dropFirst() : scalars[...]
        let segments = body.split(separator: "/", omittingEmptySubsequences: false).map { text($0) }
        var out: [String] = []
        for (i, segment) in segments.enumerated() {
            let last = i == segments.count - 1
            switch segment.lowercased() {
            case "..", ".%2e", "%2e.", "%2e%2e":
                if !out.isEmpty { out.removeLast() }
                if last { out.append("") }
            case ".", "%2e":
                if last { out.append("") }
            default:
                out.append(segment)
            }
        }
        return "/" + out.joined(separator: "/")
    }

    private static func text(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    /// The host as a browser would see it, or nil when betterlink can't be
    /// sure. Accepts lowercase ASCII DNS names, dotted IPv4, and bracketed IPv6.
    static func canonicalHost(_ raw: String) -> String? {
        guard !raw.isEmpty, let decoded = raw.removingPercentEncoding else { return nil }
        if decoded.hasPrefix("[") {
            // IPv6: hex digits, ":" and "." inside one pair of brackets.
            guard decoded.hasSuffix("]"), decoded.count > 2 else { return nil }
            let inner = decoded.dropFirst().dropLast()
            guard inner.unicodeScalars.allSatisfy({ isHex($0) || $0 == ":" || $0 == "." }), inner.contains(":") else { return nil }
            return "[" + inner.lowercased() + "]"
        }
        var host = decoded.lowercased()
        // Anything outside this set (non-ASCII, which a browser converts with
        // IDNA; spaces; control bytes; "%" left after decoding) is unroutable.
        guard host.unicodeScalars.allSatisfy({ isAlpha($0) || isDigit($0) || $0 == "-" || $0 == "." || $0 == "_" }) else { return nil }
        if host.hasSuffix(".") { host.removeLast() }  // "acme.com." is the same DNS name
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty, labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 }) else { return nil }
        // Punycode labels: the browser validates and may reject them; skip.
        if labels.contains(where: { $0.hasPrefix("xn--") }) { return nil }
        // WHATWG reads a host whose last label is numeric as an IPv4 address
        // (0x7f.1 is 127.0.0.1). Only plain dotted-quad is accepted as is.
        if let last = labels.last, last.allSatisfy({ $0.isASCII && $0.isNumber }) || last.hasPrefix("0x") {
            guard labels.count == 4, labels.allSatisfy({ l in
                l.allSatisfy { $0.isASCII && $0.isNumber } && (l == "0" || !l.hasPrefix("0")) && (Int(l) ?? 256) <= 255
            }) else { return nil }
        }
        return host
    }

    private static func isAlpha(_ u: Unicode.Scalar) -> Bool { (u >= "a" && u <= "z") || (u >= "A" && u <= "Z") }
    private static func isDigit(_ u: Unicode.Scalar) -> Bool { u >= "0" && u <= "9" }
    private static func isHex(_ u: Unicode.Scalar) -> Bool { isDigit(u) || (u >= "a" && u <= "f") || (u >= "A" && u <= "F") }

    // The WHATWG percent-encode sets (for http and https). Every other
    // printable ASCII character is kept as it is, "%" included, so an
    // already-encoded link is not encoded twice; controls, space and
    // non-ASCII (as UTF-8 bytes) are always encoded.
    private static let pathEncodeSet: Set<UInt8> = Set(" \"#<>?`{}".utf8)
    private static let queryEncodeSet: Set<UInt8> = Set(" \"#<>'".utf8)
    private static let fragmentEncodeSet: Set<UInt8> = Set(" \"<>`".utf8)

    private static func encode(_ s: String, _ set: Set<UInt8>) -> String {
        var out = ""
        for byte in s.utf8 {
            if byte > 0x20 && byte < 0x7F && !set.contains(byte) {
                out.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }
}
