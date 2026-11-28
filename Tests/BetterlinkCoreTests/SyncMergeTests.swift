import Foundation
import Testing
@testable import BetterlinkCore

/// Adding a Sidebar Profile another Mac shares, and making same-named
/// profiles from different Macs one (docs/sync.md, Same-named profiles).
struct SyncMergeTests {
    let pa = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    let pb = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    let work = UUID(uuidString: "00000000-0000-0000-0000-0000000000C0")!
    let ref = ProfileRef(browser: "com.google.Chrome", directory: "Profile 3")

    func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("bl-merge-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// A Mac with `profiles`, syncing the ones in `synced`.
    func mac(_ name: String, sync: URL, _ profiles: [SidebarProfile], synced: [UUID]) throws -> SyncSession {
        let s = SettingsFolder(directory: tempDir())
        _ = try SidebarStore(folder: s).update { $0 = SidebarLibrary(profiles: profiles) }
        _ = try RuleStore(folder: s).update { _ in }
        return SyncSession(settings: s, folder: SyncFolder(sync), device: name, name: "Mac \(name)",
                           selection: SyncSelection(global: true, profiles: Dictionary(uniqueKeysWithValues: synced.map { ($0, .init()) })))
    }

    func t(_ s: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + s) }
    func link(_ s: String) -> SavedLink { SavedLink(title: s, url: "https://\(s).example") }
    func lib(_ m: SyncSession) throws -> SidebarLibrary { try SidebarStore(folder: m.settings).load() }

    // MARK: Add

    /// The reported bug: Add turned the profile's switch on before the
    /// profile was here, so the push marked it deleted on every Mac.
    @Test func addingASharedProfileCopiesItInAndDeletesItNowhere() throws {
        let sync = tempDir()
        let a = try mac("A", sync: sync, [SidebarProfile(id: pa, name: "Primary"),
                                          SidebarProfile(id: work, name: "Work", favorites: [link("mail")],
                                                         items: [.folder(SidebarFolder(name: "Docs", items: [.link(link("doc"))]))])],
                        synced: [pa, work])
        let b = try mac("B", sync: sync, [SidebarProfile(id: pb, name: "Home")], synced: [pb])
        try a.pull(now: t(1)); try b.pull(now: t(2))
        #expect(b.offers().map(\.id).contains(work))

        try SyncLocalStore(folder: b.settings).update { $0.adding = [work] }
        let r = try b.pull(now: t(3))
        #expect(r.selectionChanged)
        #expect(b.selection.profiles[work] != nil)
        let added = try #require(try lib(b).profiles.first { $0.id == work })
        #expect(added.name == "Work")
        #expect(added.favorites.map(\.title) == ["mail"])
        #expect(added.allLinks.map(\.title).sorted() == ["doc", "mail"])
        #expect(SyncLocalStore(folder: b.settings).load().adding == nil)
        #expect(b.offers().isEmpty || !b.offers().map(\.id).contains(work))

        try a.pull(now: t(4))
        #expect(try lib(a).profiles.contains { $0.id == work && $0.favorites.count == 1 })
        #expect(a.state.isLive("sp:\(work.uuidString)"))
        #expect(SyncLocalStore(folder: a.settings).load().history.isEmpty)
    }

    /// The old Add: a selected profile that isn't here reads as deleted. Kept
    /// as the reason Add goes through the notes.
    @Test func selectingAProfileThatIsntHereStillReadsAsADelete() throws {
        let sync = tempDir()
        let a = try mac("A", sync: sync, [SidebarProfile(id: work, name: "Work")], synced: [work])
        let b = try mac("B", sync: sync, [SidebarProfile(id: pb, name: "Home")], synced: [pb])
        try a.pull(now: t(1)); try b.pull(now: t(2))
        b.selection.profiles[work] = .init()
        try b.pull(now: t(3))
        #expect(!b.state.isLive("sp:\(work.uuidString)"))
    }

    /// A crash after the Add saved the selection but before sidebar.json
    /// was written: the next push must not read the profile as deleted.
    @Test func aProfileAnAddWaitsOnIsNeverReadAsDeleted() throws {
        let sync = tempDir()
        let a = try mac("A", sync: sync, [SidebarProfile(id: work, name: "Work", favorites: [link("w1")])], synced: [work])
        let b = try mac("B", sync: sync, [SidebarProfile(id: pb, name: "Home")], synced: [pb])
        try a.pull(now: t(1)); try b.pull(now: t(2))
        try SyncLocalStore(folder: b.settings).update { $0.adding = [work] }
        b.selection.profiles[work] = .init()
        try b.push(now: t(3))
        #expect(b.state.isLive("sp:\(work.uuidString)"))
        try b.pull(now: t(4))
        #expect(try lib(b).profiles.first { $0.id == work }?.favorites.map(\.title) == ["w1"])
        #expect(SyncLocalStore(folder: b.settings).load().adding == nil)
    }

    @Test func addingSavesTheSelectionBeforeTheSidebar() throws {
        let sync = tempDir()
        let a = try mac("A", sync: sync, [SidebarProfile(id: work, name: "Work")], synced: [work])
        let b = try mac("B", sync: sync, [SidebarProfile(id: pb, name: "Home")], synced: [pb])
        try a.pull(now: t(1)); try b.pull(now: t(2))
        var saved: SyncSelection?
        b.saveSelection = { sel in
            saved = sel
            // Not written yet when the selection is saved.
            let here = (try? SidebarStore(folder: b.settings).load().profiles.map(\.id)) ?? []
            #expect(!here.contains(work))
        }
        try SyncLocalStore(folder: b.settings).update { $0.adding = [work] }
        try b.pull(now: t(3))
        #expect(saved?.profiles[work] != nil)
    }

    // MARK: Merge

    /// A Mac on a betterlink from before merges would delete the merged
    /// profile outright, so a Merge waits for it.
    @Test func aMergeWaitsForAMacThatDoesntKnowMerges() throws {
        let sync = tempDir()
        let a = try mac("A", sync: sync, [SidebarProfile(id: pa, name: "Primary", favorites: [link("a1")])], synced: [pa])
        let b = try mac("B", sync: sync, [SidebarProfile(id: pb, name: "Primary", favorites: [link("b1")])], synced: [pb])
        try a.pull(now: t(1)); try b.pull(now: t(2))
        // A's file as an older betterlink writes it: no features.
        let f = SyncFolder(sync)
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        var old = try d.decode(SyncDeviceFile.self, from: Data(contentsOf: f.file(for: "A")))
        old.features = nil
        try f.write(old)
        try SyncLocalStore(folder: b.settings).update { $0.merging = [[pa, pb]] }
        try b.pull(now: t(3))
        #expect(b.mergeWaitsFor == ["Mac A"])
        #expect(try lib(b).profiles.map(\.id) == [pb])
        #expect(b.state.isLive("sp:\(pa.uuidString)"))
        #expect(SyncLocalStore(folder: b.settings).load().merging == [[pa, pb]])  // still asked for
        // A updates and relaunches: it rewrites its file with the feature, and the merge goes ahead.
        let a2 = SyncSession(settings: a.settings, folder: f, device: "A", name: "Mac A", selection: a.selection)
        try a2.pull(now: t(4)); try b.pull(now: t(5))
        #expect(b.mergeWaitsFor.isEmpty)
        #expect(try lib(b).profiles.map(\.id) == [pa])
    }

    @Test func offersNameASameNamedProfileHere() throws {
        let sync = tempDir()
        let a = try mac("A", sync: sync, [SidebarProfile(id: pa, name: "Primary")], synced: [pa])
        let b = try mac("B", sync: sync, [SidebarProfile(id: pb, name: " primary ")], synced: [pb])
        try a.pull(now: t(1)); try b.pull(now: t(2))
        #expect(b.offers() == [SyncOffer(id: pa, name: "Primary", sameNameAs: pb)])
    }

    @Test func mergingMakesOneProfileOnEveryMacWithEverythingInBoth() throws {
        let sync = tempDir()
        let a = try mac("A", sync: sync, [SidebarProfile(id: pa, name: "Primary", favorites: [link("a1"), link("a2")],
                                                         items: [.folder(SidebarFolder(name: "Reading", items: [.link(link("ar"))]))])],
                        synced: [pa])
        let b = try mac("B", sync: sync, [SidebarProfile(id: pb, name: "Primary", browserProfiles: [ref], favorites: [link("b1")],
                                                         items: [.link(link("bl"))])],
                        synced: [pb])
        try a.pull(now: t(1)); try b.pull(now: t(2)); try a.pull(now: t(3))

        try SyncLocalStore(folder: b.settings).update { $0.merging = [[pa, pb]] }
        try b.pull(now: t(4))
        try a.pull(now: t(5))
        try b.pull(now: t(6))

        for m in [a, b] {
            let profiles = try lib(m).profiles
            #expect(profiles.count == 1)
            let p = try #require(profiles.first)
            #expect(p.id == pa)  // the lower id survives, so Macs merging at once agree
            #expect(p.name == "Primary")
            #expect(p.favorites.map(\.title) == ["a1", "a2", "b1"])  // the survivor's first
            #expect(p.allLinks.map(\.title).sorted() == ["a1", "a2", "ar", "b1", "bl"])
            #expect(m.selection.profiles.keys.sorted { $0.uuidString < $1.uuidString } == [pa])
            #expect(m.offers().isEmpty)
            // A merge deletes nothing worth a history entry.
            #expect(SyncLocalStore(folder: m.settings).load().history.isEmpty)
        }
        // B's browser profile still shows the profile it showed.
        #expect(try lib(b).profile(for: ref)?.id == pa)
        #expect(try lib(b).profiles.first?.browserProfiles == [ref])
    }

    /// The laptop's case: its own Primary was never synced. Merging keeps
    /// everything in it and starts syncing it.
    @Test func mergingAProfileThisMacKeptToItselfKeepsWhatIsInIt() throws {
        let sync = tempDir()
        let a = try mac("A", sync: sync, [SidebarProfile(id: pa, name: "Primary", favorites: [link("a1")])], synced: [pa])
        let b = try mac("B", sync: sync, [SidebarProfile(id: pb, name: "Primary", browserProfiles: [], favorites: [link("b1")],
                                                         items: [.folder(SidebarFolder(name: "Mine", items: [.link(link("b2"))]))])],
                        synced: [])
        try a.pull(now: t(1)); try b.pull(now: t(2))
        #expect(b.offers().first?.sameNameAs == pb)

        try SyncLocalStore(folder: b.settings).update { $0.merging = [[pa, pb]] }
        try b.pull(now: t(3)); try a.pull(now: t(4)); try b.pull(now: t(5))
        for m in [a, b] {
            let p = try #require(try lib(m).profiles.first)
            #expect(try lib(m).profiles.count == 1)
            #expect(p.id == pa)
            #expect(p.allLinks.map(\.title).sorted() == ["a1", "b1", "b2"])
            #expect(SidebarProfile.allFolders(in: p.items).map(\.name) == ["Mine"])
        }
    }

    /// The survivor can be the one here that wasn't synced.
    @Test func theSurvivorCanBeTheProfileThisMacKeptToItself() throws {
        let sync = tempDir()
        let a = try mac("A", sync: sync, [SidebarProfile(id: pb, name: "Primary", favorites: [link("shared")])], synced: [pb])
        let b = try mac("B", sync: sync, [SidebarProfile(id: pa, name: "Primary", favorites: [link("mine")])], synced: [])
        try a.pull(now: t(1)); try b.pull(now: t(2))
        try SyncLocalStore(folder: b.settings).update { $0.merging = [[pa, pb]] }
        try b.pull(now: t(3)); try a.pull(now: t(4)); try b.pull(now: t(5))
        for m in [a, b] {
            let profiles = try lib(m).profiles
            #expect(profiles.map(\.id) == [pa])
            #expect(profiles.first?.favorites.map(\.title) == ["mine", "shared"])
        }
    }

    /// A third Mac syncing the merged profile follows: its copy becomes the
    /// survivor, links to browser profiles and all.
    @Test func aThirdMacFollowsTheMerge() throws {
        let sync = tempDir()
        let a = try mac("A", sync: sync, [SidebarProfile(id: pa, name: "Primary", favorites: [link("a1")])], synced: [pa])
        let b = try mac("B", sync: sync, [SidebarProfile(id: pb, name: "Primary", favorites: [link("b1")])], synced: [pb])
        let c = try mac("C", sync: sync, [SidebarProfile(id: work, name: "Work"),
                                          SidebarProfile(id: pb, name: "Primary", browserProfiles: [ref])], synced: [pb])
        try a.pull(now: t(1)); try b.pull(now: t(2)); try c.pull(now: t(3))
        try SyncLocalStore(folder: a.settings).update { $0.merging = [[pa, pb]] }
        try a.pull(now: t(4)); try c.pull(now: t(5)); try b.pull(now: t(6)); try c.pull(now: t(7))

        let cl = try lib(c)
        #expect(cl.profiles.map(\.id) == [work, pa])  // Work, kept to itself, untouched
        #expect(cl.profile(for: ref)?.id == pa)
        #expect(cl.profiles.last?.favorites.map(\.title) == ["a1", "b1"])
        #expect(c.selection.profiles.keys.sorted { $0.uuidString < $1.uuidString } == [pa])
        #expect(try lib(b).profiles.map(\.id) == [pa])
    }

    /// A Mac that added a saved link to the merged profile before it heard of
    /// the merge keeps it, in the survivor.
    @Test func aLinkAddedMeanwhileOnAnotherMacLandsInTheSurvivor() throws {
        let sync = tempDir()
        let a = try mac("A", sync: sync, [SidebarProfile(id: pa, name: "Primary")], synced: [pa])
        let b = try mac("B", sync: sync, [SidebarProfile(id: pb, name: "Primary", favorites: [link("b1")])], synced: [pb])
        try a.pull(now: t(1)); try b.pull(now: t(2)); try a.pull(now: t(3))
        try SyncLocalStore(folder: a.settings).update { $0.merging = [[pa, pb]] }
        try a.pull(now: t(4))
        // B, offline, adds a favorite to its Primary, then syncs.
        _ = try SidebarStore(folder: b.settings).update { $0.update(pb) { $0.addFavorite(link("late")) } }
        try b.pull(now: t(5)); try a.pull(now: t(6)); try b.pull(now: t(7))
        for m in [a, b] {
            #expect(try lib(m).profiles.map(\.id) == [pa])
            #expect(Set(try lib(m).profiles.first?.favorites.map(\.title) ?? []) == ["b1", "late"])
        }
    }

    // MARK: Pure parts

    @Test func mergeTargetFollowsMergesOfMerges() {
        var s = SyncState()
        let x = UUID(), y = UUID(), z = UUID()
        let h = HLC(wall: 1, counter: 0, device: "t")
        s.entities["sp:\(x.uuidString)"] = ["mergedInto": Stamped(.string(y.uuidString), h)]
        s.entities["sp:\(y.uuidString)"] = ["mergedInto": Stamped(.string(z.uuidString), h)]
        #expect(SyncModel.mergeTarget(x, in: s) == z)
        #expect(SyncModel.mergeTarget(z, in: s) == z)
        // A loop (two Macs' merges crossing) stops instead of spinning.
        s.entities["sp:\(z.uuidString)"] = ["mergedInto": Stamped(.string(x.uuidString), h)]
        _ = SyncModel.mergeTarget(x, in: s)
    }

    @Test func foldingKeepsTheCatchAllAndSkipsWhatIsThereAlready() {
        let shared = link("same")
        var s = SidebarProfile(name: "P", favorites: [shared])
        s.fold(SidebarProfile(name: "P", browserProfiles: [ref], favorites: [shared, link("new")]))
        #expect(s.favorites.map(\.title) == ["same", "new"])
        #expect(s.browserProfiles.isEmpty)  // it still shows every unlinked browser profile
        var linked = SidebarProfile(name: "P", browserProfiles: [ref])
        linked.fold(SidebarProfile(name: "P", browserProfiles: [ProfileRef(browser: "b", directory: "Default")]))
        #expect(linked.browserProfiles.count == 2)
    }

    // MARK: Names

    @Test func aNewSidebarProfileNeedsANameNoOtherHas() {
        var l = SidebarLibrary(profiles: [SidebarProfile(id: pa, name: "Primary")])
        #expect(l.nameProblem("  ") != nil)
        #expect(l.nameProblem("primary ") != nil)
        #expect(l.nameProblem("Primary", except: pa) == nil)
        #expect(l.addProfile(named: "PRIMARY") == nil)
        let made = l.addProfile(named: " Work ", showingFor: ref)
        #expect(made?.name == "Work")
        #expect(l.profile(for: ref)?.id == made?.id)
    }

    @Test func theCommandRefusesADuplicateName() throws {
        let s = SettingsFolder(directory: tempDir())
        _ = try SidebarStore(folder: s).update { $0 = SidebarLibrary(profiles: [SidebarProfile(id: pa, name: "Primary")]) }
        let env = AgentEnvironment(folder: s, installed: [])
        #expect(!Agent.run("sidebar.profiles.add", input: ["name": "primary"], env: env).ok)
        #expect(Agent.run("sidebar.profiles.add", input: ["name": "Work"], env: env).ok)
        #expect(!Agent.run("sidebar.profiles.rename", input: ["profile": "Work", "name": "Primary"], env: env).ok)
    }
}
