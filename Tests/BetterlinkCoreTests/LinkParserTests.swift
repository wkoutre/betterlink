import Foundation
import Testing
@testable import BetterlinkCore

private struct Vector: Decodable {
    let input: String
    let ok: Bool
    let `protocol`: String?
    let host: String?
}
private struct VectorFile: Decodable { let vectors: [Vector] }

private func loadVectors() throws -> [Vector] {
    let url = try #require(Bundle.module.url(forResource: "url-vectors", withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode(VectorFile.self, from: Data(contentsOf: url)).vectors
}

@Suite struct LinkParserTests {
    /// The safety property: whenever betterlink reads a host, it is the host
    /// the browser reads (Node's WHATWG parser stands in for the browser).
    /// betterlink may refuse to read a host, never read a different one.
    @Test func neverDisagreesWithTheBrowserAboutTheHost() throws {
        for v in try loadVectors() {
            guard case .web(let link) = LinkParser.parse(v.input) else { continue }
            #expect(v.ok, "betterlink routed \(v.input.debugDescription) but browsers reject it")
            let oracle = (v.host ?? "").hasSuffix(".") ? String(v.host!.dropLast()) : v.host
            #expect(link.host == oracle, "\(v.input.debugDescription): betterlink read \(link.host), browser reads \(oracle ?? "nil")")
        }
    }

    /// The link handed to the browser parses back to the same host.
    @Test func rebuiltLinkKeepsTheHost() throws {
        for v in try loadVectors() {
            guard case .web(let link) = LinkParser.parse(v.input) else { continue }
            guard case .web(let again) = LinkParser.parse(link.href) else {
                Issue.record("\(link.href) did not parse again"); continue
            }
            #expect(again == link, "\(v.input.debugDescription) -> \(link.href) -> \(again.href)")
            #expect(URLComponents(string: link.href, encodingInvalidCharacters: true)?.host?.lowercased() == link.host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) || link.host.hasPrefix("["),
                    "Foundation reads a different host from \(link.href)")
        }
    }

    @Test(arguments: [
        ("https://evil.com\\@acme.com/", "evil.com"),
        ("https://evil.com\\@app.acme.com/x", "evil.com"),
        ("https:\\\\evil.com\\acme.com", "evil.com"),
        ("https:evil.com/acme.com", "evil.com"),
        ("https://acme.com@evil.com/", "evil.com"),
        ("https://user:p@ss@evil.com/", "evil.com"),
        ("https://evil.com#@acme.com", "evil.com"),
        ("https://evil.com?x=@acme.com", "evil.com"),
        ("https://ev\til.com/", "evil.com"),
        ("https://acme%2ecom/", "acme.com"),
        ("https://acme.com./", "acme.com"),
        ("HTTPS://APP.ACME.COM/Swap", "app.acme.com"),
        ("https://evil.com%2f@acme.com/", "acme.com"),
        // Review F3: a combining mark after "/" doesn't hide the "/".
        ("https://evil.com/\u{301}@acme.com/", "evil.com"),
        ("https://evil.com\\\u{301}@acme.com/", "evil.com"),
        ("https://evil.com?\u{301}@acme.com/", "evil.com"),
        ("https://evil.com#\u{301}@acme.com/", "evil.com"),
    ])
    func readsTheHostABrowserReads(input: String, host: String) {
        guard case .web(let link) = LinkParser.parse(input) else {
            Issue.record("\(input.debugDescription) was not routable"); return
        }
        #expect(link.host == host)
    }

    /// Hosts the browser rewrites (IDNA, numeric IPv4) or rejects are never
    /// matched against rules.
    @Test(arguments: [
        "https://acmе.org/",          // Cyrillic а
        "https://xn--acm-4ve.com/",
        "http://0x7f.1/",
        "https://%E2%80%8Bacme.com/", // zero-width space
        "https://acme.com%00.evil.com/",
        "https://ex ample.com/",
        "https://",
        "https://[acme.com]/",
        "https://acme.com:99999/",
    ])
    func unreadableHostsAreUnroutable(input: String) {
        if case .unroutable = LinkParser.parse(input) { return }
        Issue.record("\(input.debugDescription) parsed as \(LinkParser.parse(input))")
    }

    @Test func dropsCredentialsDefaultPortsAndFixesBackslashesInThePath() {
        guard case .web(let link) = LinkParser.parse("https://me:pw@Acme.com:443\\a\\b?q=1#f") else {
            Issue.record("not routable"); return
        }
        #expect(link.href == "https://acme.com/a/b?q=1#f")
    }

    @Test func keepsNonDefaultPortsAndEncodedPaths() {
        guard case .web(let link) = LinkParser.parse("http://localhost:3000/a%20b/c d") else {
            Issue.record("not routable"); return
        }
        #expect(link.href == "http://localhost:3000/a%20b/c%20d")
    }

    /// Review F2: the path is the one the browser loads, dot segments removed.
    @Test(arguments: [
        ("https://a.com/x/../y", "/y"), ("https://a.com/x/./y", "/x/y"), ("https://a.com/x/..", "/"),
        ("https://a.com/x/.", "/x/"), ("https://a.com/../../y", "/y"), ("https://a.com/x/%2E%2e/y", "/y"),
        ("https://a.com/x/%2e/y", "/x/y"), ("https://a.com", "/"), ("https://a.com//x", "//x"),
        ("https://a.com/x/..\u{301}/y", "/x/..%CC%81/y"),
    ])
    func removesDotSegmentsLikeABrowser(input: String, path: String) {
        guard case .web(let link) = LinkParser.parse(input) else { Issue.record("not routable"); return }
        #expect(link.path == path)
    }

    /// Review F4: each part keeps what a browser keeps and encodes what it
    /// encodes (the WHATWG percent-encode sets).
    @Test(arguments: [
        ("https://a.com/#/#room", "https://a.com/#/#room"),
        ("https://a.com/?a[]=1&b=|^", "https://a.com/?a[]=1&b=|^"),
        ("https://a.com/[x]|^", "https://a.com/[x]|^"),
        ("https://a.com/a b?c d#e f", "https://a.com/a%20b?c%20d#e%20f"),
        ("https://a.com/café?q=é#é", "https://a.com/caf%C3%A9?q=%C3%A9#%C3%A9"),
        ("https://a.com/{x}<y>`?'\"", "https://a.com/%7Bx%7D%3Cy%3E%60?%27%22"),
        ("https://a.com/%5B?%23", "https://a.com/%5B?%23"),
    ])
    func encodesEachPartLikeABrowser(input: String, href: String) {
        guard case .web(let link) = LinkParser.parse(input) else { Issue.record("not routable"); return }
        #expect(link.href == href)
    }

    @Test(arguments: ["javascript:alert(1)", "ftp://acme.com/", "notaurl", "mailto:a@b.c"])
    func refusesNonWebSchemes(input: String) {
        if case .refused = LinkParser.parse(input) { return }
        Issue.record("\(input) parsed as \(LinkParser.parse(input))")
    }

    @Test func filesAreRecognised() {
        #expect(LinkParser.parse("file:///Users/me/page.html") == .file("file:///Users/me/page.html"))
    }
}
