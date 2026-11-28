import Foundation

// Opening and closing folders is the most frequent change to sidebar.json and
// the only one made on a click that then animates. The sidebar shows it at
// once; the file follows off the main thread (the app's SidebarLibraryModel).
// What makes that safe is here, where it can be tested: the change says where
// a folder ends up, so saving it late, twice, or on top of someone else's edit
// loses nothing.

/// Which folders are to be open: one folder, or every folder of a Sidebar
/// Profile (Option-click). It names the state they end in, never "the other
/// one", so applying it again changes nothing.
public enum SidebarOpenChange: Equatable, Sendable {
    case folder(profile: UUID, id: UUID, open: Bool)
    case all(profile: UUID, open: Bool)

    public func apply(to library: inout SidebarLibrary) {
        switch self {
        case .folder(let profile, let id, let open): library.update(profile) { $0.setExpanded(id, open) }
        case .all(let profile, let open): library.update(profile) { $0.setAllExpanded(open) }
        }
    }
}

/// The changes waiting to be saved, in the order they were made. Only the
/// last word on each folder is kept, and "every folder" replaces what was
/// waiting for its profile.
public struct SidebarOpenChanges: Equatable, Sendable {
    public private(set) var changes: [SidebarOpenChange] = []

    public init() {}

    public var isEmpty: Bool { changes.isEmpty }

    public mutating func add(_ change: SidebarOpenChange) {
        switch change {
        case .folder(let profile, let id, _):
            changes.removeAll { if case .folder(let p, let i, _) = $0 { return p == profile && i == id }; return false }
        case .all(let profile, _):
            changes.removeAll {
                switch $0 {
                case .folder(let p, _, _), .all(let p, _): return p == profile
                }
            }
        }
        changes.append(change)
    }

    public mutating func add(_ other: SidebarOpenChanges) { other.changes.forEach { add($0) } }

    public func apply(to library: inout SidebarLibrary) { changes.forEach { $0.apply(to: &library) } }
}

extension SidebarProfile {
    /// Opens or closes one folder. Nothing when it is already so.
    public mutating func setExpanded(_ id: UUID, _ open: Bool) {
        guard let f = folder(id), f.expanded != open else { return }
        items = Self.mapping(items) { item in
            if case .folder(var f) = item, f.id == id { f.expanded = open; return .folder(f) }
            return item
        }
    }
}

extension SidebarLibrary {
    /// Whether the two differ in nothing but which folders are open. That
    /// doesn't sync (each Mac keeps its own), so a save that changed nothing
    /// else has nothing to send.
    public func sameApartFromOpenFolders(as other: SidebarLibrary) -> Bool {
        func allOpen(_ library: SidebarLibrary) -> SidebarLibrary {
            var library = library
            for i in library.profiles.indices { library.profiles[i].setAllExpanded(true) }
            return library
        }
        return allOpen(self) == allOpen(other)
    }
}

extension SidebarStore {
    /// What a save left: the library the file now holds, and the file as it
    /// was read and as it is now (`FileSignature`), for telling this save's
    /// own change to the file from anyone else's.
    public struct Saved: Sendable {
        public var library: SidebarLibrary
        public var before: FileSignature?
        public var after: FileSignature?
        /// False when the file already had every folder as asked: it is untouched.
        public var wrote: Bool
        /// The save changed nothing but which folders are open, which doesn't sync.
        public var onlyOpenFolders: Bool
    }

    /// `update`, also saying what the file was and is.
    public func change(_ change: (inout SidebarLibrary) throws -> Void) throws -> Saved {
        try SettingsFile.withLock(beside: file, name: ".sidebar.lock", what: "sidebar.json") {
            let before = FileSignature.of(file)
            var library = try load()
            try change(&library)
            try SettingsFile.write(library, to: file, what: "sidebar.json")
            return Saved(library: library, before: before, after: FileSignature.of(file), wrote: true, onlyOpenFolders: false)
        }
    }

    /// Opens and closes folders starting from what is on disk now, under the
    /// file's lock, as `update` does. So an edit made since the app last read
    /// the file (the command line, a sync) is kept.
    public func save(_ changes: SidebarOpenChanges) throws -> Saved {
        try SettingsFile.withLock(beside: file, name: ".sidebar.lock", what: "sidebar.json") {
            let before = FileSignature.of(file)
            let was = try load()
            var library = was
            changes.apply(to: &library)
            guard library != was else { return Saved(library: library, before: before, after: before, wrote: false, onlyOpenFolders: true) }
            try SettingsFile.write(library, to: file, what: "sidebar.json")
            return Saved(library: library, before: before, after: FileSignature.of(file), wrote: true,
                         onlyOpenFolders: library.sameApartFromOpenFolders(as: was))
        }
    }
}

/// What tells one saved version of a file from the next without reading it:
/// which file it is (a save writes a new one and renames it into place), its
/// size and dates, and who may change it and its folder (what FileSafety
/// judges, so the chmod it asks for reads as a change). Nil: no such file.
public struct FileSignature: Equatable, Sendable {
    var device: Int64, inode: UInt64, size: Int64
    var modified: Int64, modifiedNanos: Int64, changed: Int64, changedNanos: Int64
    var mode: UInt32, owner: UInt32, folderMode: UInt32, folderOwner: UInt32

    public static func of(_ url: URL) -> FileSignature? {
        let real = url.resolvingSymlinksInPath()
        var f = stat(), d = stat()
        guard stat(real.path, &f) == 0, stat(real.deletingLastPathComponent().path, &d) == 0 else { return nil }
        return FileSignature(device: Int64(f.st_dev), inode: UInt64(f.st_ino), size: Int64(f.st_size),
                             modified: Int64(f.st_mtimespec.tv_sec), modifiedNanos: Int64(f.st_mtimespec.tv_nsec),
                             changed: Int64(f.st_ctimespec.tv_sec), changedNanos: Int64(f.st_ctimespec.tv_nsec),
                             mode: UInt32(f.st_mode), owner: f.st_uid, folderMode: UInt32(d.st_mode), folderOwner: d.st_uid)
    }
}
