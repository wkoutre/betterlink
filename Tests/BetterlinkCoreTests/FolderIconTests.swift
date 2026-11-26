import Foundation
import Testing
@testable import BetterlinkCore

/// A folder's icon (an emoji or a built-in symbol): what typing one accepts,
/// how sidebar.json keeps it, and how sync carries it between Macs.
struct FolderIconTests {
    static let folderID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    static let profileID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!

    /// sidebar.json as betterlink wrote it before folders had icons.
    static let oldFile = """
    {"version":1,"profiles":[{"id":"\(profileID.uuidString)","name":"Primary","browserProfiles":[],
    "favorites":[{"id":"99999999-0000-0000-0000-000000000001","title":"Mail","url":"https://mail.example"}],
    "items":[{"folder":{"id":"\(folderID.uuidString)","name":"Docs","expanded":false,"items":[
    {"link":{"id":"99999999-0000-0000-0000-000000000002","title":"A","url":"https://a.example"}}]}}]}]}
    """

    func folder(_ lib: SidebarLibrary) -> SidebarFolder? {
        guard case .folder(let f)? = lib.profiles.first?.items.first else { return nil }
        return f
    }

    // MARK: sidebar.json

    @Test func oldDataDecodesWithNoIcon() throws {
        let lib = try JSONDecoder().decode(SidebarLibrary.self, from: Data(Self.oldFile.utf8))
        let f = try #require(folder(lib))
        #expect(f.name == "Docs")
        #expect(!f.expanded)
        #expect(f.icon == nil)
        #expect(f.items.count == 1)
        // And it is written back without an icon field, as before.
        let json = String(decoding: try JSONEncoder().encode(lib), as: UTF8.self)
        #expect(!json.contains("\"icon\""))
    }

    @Test func iconsRoundTripThroughSidebarJSON() throws {
        for icon: FolderIcon in [.emoji("🚀"), .emoji("👩‍👩‍👧"), .symbol("star.fill"), .unknown("image:abc")] {
            var p = SidebarProfile(name: "Primary")
            let id = p.addFolder("Docs")
            #expect(p.setIcon(id, to: icon))
            let lib = SidebarLibrary(profiles: [p])
            let back = try JSONDecoder().decode(SidebarLibrary.self, from: JSONEncoder().encode(lib))
            #expect(back == lib)
            #expect(folder(back)?.icon == icon)
        }
    }

    @Test func theIconIsOneStringInTheFile() throws {
        var p = SidebarProfile(name: "Primary")
        let id = p.addFolder("Docs")
        p.setIcon(id, to: .symbol("star.fill"))
        let json = String(decoding: try JSONEncoder().encode(p), as: UTF8.self)
        #expect(json.contains(#""icon":"symbol:star.fill""#))
    }

    @Test func setIconChangesOnlyFoldersAndClears() {
        var p = SidebarProfile(name: "Primary")
        let outer = p.addFolder("Outer")
        let inner = p.addFolder("Inner", in: outer)
        let link = SavedLink(title: "A", url: "https://a.example")
        p.addLink(link, in: inner)
        #expect(p.setIcon(inner, to: .emoji("📚")))
        #expect(p.folder(inner)?.icon == .emoji("📚"))
        #expect(p.folder(outer)?.icon == nil)
        #expect(!p.setIcon(link.id, to: .emoji("📚")))   // a link has a site icon, not this
        #expect(!p.setIcon(UUID(), to: .emoji("📚")))
        #expect(p.setIcon(inner, to: nil))
        #expect(p.folder(inner)?.icon == nil)
    }

    // MARK: Checking what is typed

    @Test(arguments: ["🚀", "👩‍👩‍👧", "🇯🇵", "1️⃣", "❤️", "👍🏽", " 📚 "])
    func oneEmojiIsAccepted(_ text: String) throws {
        let icon = try FolderIcon.checkedEmoji(text)
        #expect(icon == .emoji(text.trimmingCharacters(in: .whitespaces)))
    }

    @Test(arguments: ["", "  ", "a", "1", "#", "ab", "🚀🚀", "🚀a", "star.fill"])
    func anythingButOneEmojiIsRefused(_ text: String) {
        #expect(throws: FolderIcon.Invalid.self) { try FolderIcon.checkedEmoji(text) }
    }

    @Test(arguments: ["star.fill", "folder", "1.circle", "arrow.up.right.square", "folder.badge.person.crop"])
    func aSymbolNameIsAccepted(_ name: String) throws {
        #expect(try FolderIcon.checkedSymbol(name) == .symbol(name))
    }

    @Test(arguments: ["", "star fill", "star..fill", ".star", "star.", "star/fill", "🚀", "symbol:star", String(repeating: "a", count: 101)])
    func aMalformedSymbolNameIsRefused(_ name: String) {
        #expect(throws: FolderIcon.Invalid.self) { try FolderIcon.checkedSymbol(name) }
    }

    @Test func aSymbolThisMacDoesNotHaveIsRefused() throws {
        let known: Set<String> = ["star.fill"]
        #expect(try FolderIcon.checkedSymbol("star.fill", exists: known.contains) == .symbol("star.fill"))
        do {
            _ = try FolderIcon.checkedSymbol("star.sparkly", exists: known.contains)
            Issue.record("a symbol this Mac doesn't have was accepted")
        } catch let e as FolderIcon.Invalid {
            #expect(e.message.contains("no symbol called"))
        }
    }

    @Test func rawStringsKeepTheirKind() {
        #expect(FolderIcon(raw: "emoji:🚀") == .emoji("🚀"))
        #expect(FolderIcon(raw: "symbol:star.fill") == .symbol("star.fill"))
        #expect(FolderIcon(raw: "image:x") == .unknown("image:x"))
        for icon: FolderIcon in [.emoji("🚀"), .symbol("star.fill"), .unknown("image:x")] { #expect(FolderIcon(raw: icon.raw) == icon) }
    }

    // MARK: Sync

    /// One simulated Mac, as in SyncConvergenceTests.
    struct Mac {
        var clock: HLCClock
        var state = SyncState()
        var library: SidebarLibrary
        let selection = SyncSelection(global: false, profiles: [FolderIconTests.profileID: .init()])

        init(_ device: String, library: SidebarLibrary) {
            clock = HLCClock(device: device); self.library = library
        }

        mutating func record(now: Int64) {
            let local = SyncModel.project(rules: RuleStore.Contents(), library: library, selection: selection,
                                          identity: { ProfileIdentity(name: $0.directory, account: nil) }, state: state)
            state.record(local, scope: SyncModel.scope(selection, state: state), clock: &clock, now: now)
        }

        mutating func read(_ other: SyncState, now: Int64) {
            state = state.merged(with: other)
            if let m = state.maxStamp { clock.observe(m) }
            library = SyncModel.materialize(state, rules: RuleStore.Contents(), library: library, selection: selection,
                                            resolve: { _, d, _ in d }).library
            record(now: now)
        }

        mutating func setIcon(_ icon: FolderIcon?) {
            library.update(FolderIconTests.profileID) { $0.setIcon(FolderIconTests.folderID, to: icon) }
        }

        var icon: FolderIcon? { library.profiles.first?.folder(FolderIconTests.folderID)?.icon }
    }

    static func starter() -> SidebarLibrary {
        try! JSONDecoder().decode(SidebarLibrary.self, from: Data(oldFile.utf8))
    }

    @Test func anIconSetOnOneMacArrivesOnTheOtherAndSoDoesClearingIt() {
        var a = Mac("A", library: Self.starter()), b = Mac("B", library: Self.starter())
        a.record(now: 1_000); b.read(a.state, now: 1_001); a.read(b.state, now: 1_002)
        #expect(b.icon == nil)

        a.setIcon(.emoji("🚀")); a.record(now: 2_000)
        b.read(a.state, now: 2_001)
        #expect(b.icon == .emoji("🚀"))
        // The rest of the folder came through untouched.
        #expect(b.library.profiles.first?.folder(Self.folderID)?.name == "Docs")

        b.setIcon(.symbol("star.fill")); b.record(now: 3_000)
        a.read(b.state, now: 3_001)
        #expect(a.icon == .symbol("star.fill"))

        a.setIcon(nil); a.record(now: 4_000)
        b.read(a.state, now: 4_001)
        #expect(b.icon == nil)
        #expect(a.state == b.state)
    }

    @Test func theIconSyncsAsOneFieldOfTheFolder() {
        var a = Mac("A", library: Self.starter())
        a.setIcon(.symbol("star.fill")); a.record(now: 1_000)
        #expect(a.state.value(SyncModel.nodeID(Self.folderID), "icon") == .string("symbol:star.fill"))
    }

    /// A Mac on a betterlink from before folder icons sends folders with no
    /// icon field. That must neither clear an icon nor fail.
    @Test func aMacThatDoesNotKnowIconsLeavesThemAlone() {
        var a = Mac("A", library: Self.starter())
        a.setIcon(.emoji("🚀")); a.record(now: 1_000)
        // The old Mac renames the folder; its view has no icon field at all.
        var old = SyncState()
        var oldClock = HLCClock(device: "Old")
        let node = SyncModel.nodeID(Self.folderID)
        var fields = a.state.entities[node]!.mapValues(\.value)
        fields.removeValue(forKey: "icon")
        fields["title"] = .string("Papers")
        old = old.merged(with: a.state)
        old.record([node: fields], scope: { _ in false }, clock: &oldClock, now: 5_000)
        a.read(old, now: 5_001)
        #expect(a.icon == .emoji("🚀"))
        #expect(a.library.profiles.first?.folder(Self.folderID)?.name == "Papers")
    }

    /// A Mac that has never seen an icon on a folder sends no icon field for
    /// it: an upgrade must not stamp "no icon" over one another Mac just set.
    @Test func aFolderWithNoIconSendsNoIconField() {
        var a = Mac("A", library: Self.starter()), b = Mac("B", library: Self.starter())
        a.record(now: 1_000)
        #expect(a.state.entities[SyncModel.nodeID(Self.folderID)]?["icon"] == nil)
        // A sets an icon early; B records later, by the clock, before it reads A.
        a.setIcon(.emoji("🚀")); a.record(now: 2_000)
        b.record(now: 9_000)
        b.read(a.state, now: 9_001)
        a.read(b.state, now: 9_002)
        #expect(a.icon == .emoji("🚀"))
        #expect(b.icon == .emoji("🚀"))
    }

    /// Synced state with no icon field (written before folder icons) keeps
    /// an icon this Mac has set and not yet sent.
    @Test func stateWithNoIconFieldKeepsTheLocalIcon() {
        var a = Mac("A", library: Self.starter())
        a.record(now: 1_000)
        a.setIcon(.symbol("star.fill"))
        let r = SyncModel.materialize(a.state, rules: RuleStore.Contents(), library: a.library, selection: a.selection,
                                      resolve: { _, d, _ in d })
        #expect(r.library.profiles.first?.folder(Self.folderID)?.icon == .symbol("star.fill"))
    }

    @Test func anUnknownKindIsCarriedAsItIs() {
        var a = Mac("A", library: Self.starter()), b = Mac("B", library: Self.starter())
        a.setIcon(.unknown("image:abc")); a.record(now: 1_000)
        b.read(a.state, now: 1_001)
        #expect(b.icon == .unknown("image:abc"))
        #expect(b.state.value(SyncModel.nodeID(Self.folderID), "icon") == .string("image:abc"))
    }
}
