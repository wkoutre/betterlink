import Foundation
import Testing
@testable import BetterlinkCore

struct ChangelogTests {
    /// The shape scripts/gen-changelog.py writes.
    private let json = #"""
    {
     "repository": "wkoutre/betterlink",
     "releases": [
      {"version": "0.3.22", "date": "2026-11-26", "changes": [
        {"text": "Fit two- and three-digit Link Rules numbers on one line", "pr": 91},
        {"text": "A change with no pull request", "pr": null}]},
      {"version": "0.3.21", "date": "2026-11-26", "changes": [{"text": "Give tour topic cards more vertical padding", "pr": 89}]},
      {"version": "0.3.10", "date": "2026-11-25", "changes": []},
      {"version": "0.3.9", "date": "2026-11-25", "changes": [{"text": "Starting a drag no longer moves the sidebar's rows", "pr": 71}]}
     ],
     "unreleased": [{"text": "Not yet", "pr": 93}]
    }
    """#

    private func log() throws -> Changelog {
        try JSONDecoder().decode(Changelog.self, from: Data(json.utf8))
    }

    @Test func readsWhatTheGeneratorWrites() throws {
        let log = try log()
        #expect(log.releases.map(\.version) == ["0.3.22", "0.3.21", "0.3.10", "0.3.9"])
        #expect(log.releases[0].changes[1] == Changelog.Change(text: "A change with no pull request", pr: nil))
        #expect(log.unreleased == [Changelog.Change(text: "Not yet", pr: 93)])
        // A file from before "unreleased" existed still reads.
        let old = try JSONDecoder().decode(Changelog.self, from: Data(#"{"repository":null,"releases":[]}"#.utf8))
        #expect(old.releases.isEmpty && old.unreleased == nil)
    }

    @Test func linksAChangeToItsPullRequest() throws {
        let log = try log()
        #expect(log.link(for: log.releases[0].changes[0])?.absoluteString == "https://github.com/wkoutre/betterlink/pull/91")
        #expect(log.link(for: log.releases[0].changes[1]) == nil)
        let noRepo = Changelog(repository: nil, releases: log.releases)
        #expect(noRepo.link(for: log.releases[0].changes[0]) == nil)
    }

    @Test func sinceAndLimitCompareVersionsAsNumbers() throws {
        let log = try log()
        // 0.3.10 is newer than 0.3.9, though "10" sorts before "9" as text.
        #expect(log.releases(since: "0.3.9").map(\.version) == ["0.3.22", "0.3.21", "0.3.10"])
        #expect(log.releases(since: "0.3.21").map(\.version) == ["0.3.22"])
        #expect(log.releases(since: "0.3.22").isEmpty)
        #expect(log.releases(limit: 2).map(\.version) == ["0.3.22", "0.3.21"])
        #expect(log.releases(since: "0.3.9", limit: 1).map(\.version) == ["0.3.22"])
    }

    @Test func parsesOnlyThreeWholeNumbers() {
        #expect(Changelog.parts("0.3.22") == [0, 3, 22])
        #expect(Changelog.parts("0.3") == nil)
        #expect(Changelog.parts("0.3.x") == nil)
        #expect(Changelog.parts("0.3.-1") == nil)
        #expect(Changelog.parts("") == nil)
    }

    @Test func aReleaseDateIsADay() throws {
        let day = try #require(try log().releases[0].day)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let c = utc.dateComponents([.year, .month, .day], from: day)
        #expect(c.year == 2026 && c.month == 11 && c.day == 26)
        #expect(Changelog.Release(version: "1.0.0", date: "soon", changes: []).day == nil)
    }

    @Test func loadsFromAFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("changelog-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(Changelog.load(from: url)?.releases.count == 4)
        #expect(Changelog.load(from: url.appendingPathExtension("missing")) == nil)
    }

    // MARK: betterlink changelog list

    @Test func theCommandListsReleasesWithLinks() throws {
        let log = try log()
        guard case .success(let data) = ChangelogAgent.run("changelog.list", input: ["limit": 1], changelog: log, installed: "0.3.22") else {
            Issue.record("refused"); return
        }
        #expect(data["installed"] as? String == "0.3.22")
        let releases = try #require(data["releases"] as? [[String: Any]])
        #expect(releases.count == 1)
        #expect(releases[0]["version"] as? String == "0.3.22")
        let changes = try #require(releases[0]["changes"] as? [[String: Any]])
        #expect(changes[0]["pr"] as? Int == 91)
        #expect(changes[0]["link"] as? String == "https://github.com/wkoutre/betterlink/pull/91")
        #expect(changes[1].keys.sorted() == ["text"])
    }

    @Test func theCommandRefusesBadInput() throws {
        let log = try log()
        for input: [String: Any] in [["since": "soon"], ["since": 3], ["limit": 0], ["limit": 1.5], ["limit": true], ["limit": "2"]] {
            guard case .failure = ChangelogAgent.run("changelog.list", input: input, changelog: log, installed: "0.3.22") else {
                Issue.record("accepted \(input)"); continue
            }
        }
        guard case .success(let data) = ChangelogAgent.run("changelog.list", input: ["since": "0.3.21"], changelog: log, installed: "") else {
            Issue.record("refused since"); return
        }
        #expect((data["releases"] as? [[String: Any]])?.count == 1)
    }

    @Test func aBuildWithoutHistorySaysSo() {
        guard case .success(let data) = ChangelogAgent.run("changelog.list", input: [:], changelog: nil, installed: "0.3.22") else {
            Issue.record("refused"); return
        }
        #expect((data["releases"] as? [Any])?.isEmpty == true)
        #expect(data["note"] is String)
    }
}
