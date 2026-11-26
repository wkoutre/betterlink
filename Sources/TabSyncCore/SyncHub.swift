import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// One connected browser (one host process).
public struct BrowserSession: Identifiable, Sendable {
    public var id: String { socketPath }
    public var socketPath: String
    public var browser: String = "Browser"
    public var pid: Int = 0
    /// The browser's own process id, to match a session to the frontmost app.
    public var browserPid: Int = 0
    public var brands: [String] = []
    /// The extension's id for its browser profile (see ProfileLocator).
    public var instance: String?
    /// The extension's version, from its hello.
    public var extensionVersion: String?
    /// The commands this browser's copy of the extension runs.
    public var ops: Set<String> = Command.Op.original
    public var store = TabStore()
    /// Browser event -> app, measured on the shared machine clock.
    public var lastEventLatencyMs: Double?
    public var lastEventKind: String?
    /// App command -> browser ack, round trip.
    public var lastCommandRoundTripMs: Double?

    public init(socketPath: String) { self.socketPath = socketPath }

    /// Whether the installed extension runs `op`. An older copy keeps working
    /// with what it has; the sidebar offers only what will happen.
    public func can(_ op: Command.Op) -> Bool { ops.contains(op.rawValue) }

    /// Takes in the extension's hello.
    public mutating func greet(_ m: Inbound) {
        brands = m.brands ?? []
        instance = m.instance
        extensionVersion = m.extensionVersion
        ops = m.ops.map(Set.init) ?? Command.Op.original
    }
}

/// Finds every running host (one socket each), connects, keeps a TabStore per
/// browser, and sends commands. Discovery is push-based: the socket directory is
/// watched with kqueue (macOS) or inotify (Linux), never rescanned on a timer.
public final class SyncHub: @unchecked Sendable {
    public typealias Listener = @Sendable ([BrowserSession]) -> Void

    private let dir: String
    private let q = DispatchQueue(label: "betterlink.tabs.hub")
    private var sessions: [String: BrowserSession] = [:]
    private var connections: [String: Int32] = [:]
    private var pending: [String: Double] = [:]
    private var watcher: DirectoryWatcher?
    private let onChange: Listener
    private let onLine: (@Sendable (String, Inbound) -> Void)?

    /// Whether a change to what tabs only show (a title, an icon) is handed on
    /// once and the ones after it held until `collect()`.
    private let holdingContent: Bool
    /// One such change was handed on and the lists weren't collected since.
    private var handedContent = false
    /// Title changes taken in since then and not read yet, by connection, in
    /// the order they came, each with when it came.
    private var held: [String: [(line: Data, at: Double)]] = [:]

    /// `holdingContent`: for the app, which draws what tabs show at most once
    /// per `PublishPacer.interval` and takes the newest lists then
    /// (`collect()`). A window of 56 tabs changing their titles twice a second
    /// is 112 messages a second. The first title or icon change after a
    /// collect is read and handed on; the title changes after it are kept
    /// unread, and the collect reads only each tab's newest (`readHeld`).
    /// A change the app needs at once (opens, closes, moves, switches, a tab's
    /// address, anything but a title or icon) is read with everything kept
    /// before it, in order, and handed on at once; so is a kept title line
    /// found, when read, to carry a new address. Off, every line is read
    /// and handed on as it comes (the terminal view, the e2e test).
    public init(directory: String = SocketDirectory.path,
                holdingContent: Bool = false,
                onLine: (@Sendable (String, Inbound) -> Void)? = nil,
                onChange: @escaping Listener) {
        self.holdingContent = holdingContent
        self.dir = directory
        self.onChange = onChange
        self.onLine = onLine
    }

    private let dec = JSONDecoder()
    /// How many lines were decoded, for the tab churn guard (TabChurnTests).
    private var decodes = 0
    var decodeCount: Int { q.sync { decodes } }
    /// How many lines came in, read or held.
    private var lines = 0
    var lineCount: Int { q.sync { lines } }

    public func start() {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        watcher = DirectoryWatcher(path: dir) { [weak self] in
            guard let hub = self else { return }
            hub.q.async { hub.rescan() }
        }
        q.async { self.rescan() }
    }

    public var current: [BrowserSession] { q.sync { orderedSessions() } }

    /// The newest tab lists, for the app publishing them: the next change to
    /// what tabs show is handed on again.
    /// A held line that turns out to move a tab's address or window is
    /// handed on as well, at once (`movesAddress`).
    public func collect() -> [BrowserSession] {
        q.sync {
            var moved = false
            for (path, lines) in held {
                guard var s = sessions.removeValue(forKey: path) else { continue }
                if readHeld(lines, into: &s, from: path) { moved = true }
                sessions[path] = s
            }
            held = [:]
            handedContent = moved
            if moved { publish() }
            return orderedSessions()
        }
    }

    public func send(_ cmd: Command, to socketPath: String) {
        q.async {
            guard let fd = self.connections[socketPath], var data = try? JSONEncoder().encode(cmd) else { return }
            data.append(0x0A)
            self.pending[cmd.id] = cmd.t
            _ = writeAllBytes(fd, data)
        }
    }

    // MARK: - internals (on q)

    private func orderedSessions() -> [BrowserSession] {
        sessions.values.sorted { ($0.browser, $0.pid) < ($1.browser, $1.pid) }
    }
    private func publish() { onChange(orderedSessions()) }

    private func rescan() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        let paths = Set(names.filter { $0.hasSuffix(".sock") }.map { "\(dir)/\($0)" })
        for p in paths where connections[p] == nil { connect(p) }
        for p in Array(connections.keys) where !paths.contains(p) { disconnect(p) }
    }

    private func connect(_ path: String) {
        let fd = connectUnix(path)
        guard fd >= 0 else {
            // A host that crashed leaves its socket file behind. Nobody listens: remove it.
            if errno == ECONNREFUSED { unlink(path) }
            return
        }
        connections[path] = fd
        sessions[path] = BrowserSession(socketPath: path)
        publish()
        Thread.detachNewThread { [weak self] in
            var dec = LineDecoder()
            var buf = [UInt8](repeating: 0, count: 256 * 1024)
            while true {
                let n = read(fd, &buf, buf.count)
                if n <= 0 { if n < 0 && errno == EINTR { continue }; break }
                let lines = pooled { dec.feed(Data(buf[0..<n])) }
                let received = nowMs()
                guard let hub = self else { return }
                // On this thread, in the hub's turn: waking another thread
                // for every message cost more than most messages do.
                hub.q.sync { hub.handle(lines, from: path, receivedAt: received) }
            }
            guard let hub = self else { return }
            hub.q.async { hub.disconnect(path) }
        }
    }

    private func disconnect(_ path: String) {
        held[path] = nil
        if let fd = connections.removeValue(forKey: path) { close(fd) }
        if sessions.removeValue(forKey: path) != nil { publish() }
    }

    private func handle(_ lines: [Data], from path: String, receivedAt: Double) {
        guard var s = sessions.removeValue(forKey: path) else { return }
        self.lines += lines.count
        var rest = lines[...]
        // A title change after one was handed on: kept unread until the app
        // collects, or until a line that isn't one comes (`readHeld`).
        if holdingContent && handedContent {
            while let line = rest.first, let id = Self.titleOnlyTab(line), s.store.tabs[id] != nil {
                held[path, default: []].append((line, receivedAt))
                rest.removeFirst()
            }
        }
        guard !rest.isEmpty else {
            sessions[path] = s
            return
        }
        var decoded = false, atOnce = false
        // What was kept came before these.
        if let kept = held.removeValue(forKey: path), readHeld(kept, into: &s, from: path) {
            decoded = true
            atOnce = true
        }
        for line in rest {
            decodes += 1
            guard let m = try? dec.decode(Inbound.self, from: line) else { continue }
            decoded = true
            onLine?(path, m)
            if !PublishPacer.isContent(m) || Self.movesAddress(m, in: s.store) { atOnce = true }
            take(m, into: &s, from: path, receivedAt: receivedAt)
        }
        sessions[path] = s
        guard decoded else { return }
        if holdingContent {
            if handedContent && !atOnce { return }
            handedContent = true
        }
        publish()
    }

    private func take(_ m: Inbound, into s: inout BrowserSession, from path: String, receivedAt: Double) {
        switch m.type {
        case "host":
            s.browser = m.browser ?? s.browser
            s.pid = m.pid ?? s.pid
            s.browserPid = m.browserPid ?? s.browserPid
        case "hello":
            s.greet(m)
        case "ack":
            if let id = m.id, let sent = pending.removeValue(forKey: id) {
                s.lastCommandRoundTripMs = receivedAt - sent
            }
        default:
            if s.store.apply(m) == .needsSnapshot, let fd = connections[path],
               var data = try? JSONEncoder().encode(Command.snapshot()) {
                data.append(0x0A)
                _ = writeAllBytes(fd, data)
            }
            if m.type == "event", let t = m.t {
                s.lastEventLatencyMs = receivedAt - t
                s.lastEventKind = m.kind
            }
        }
    }

    /// Reads kept title changes. Each replaces its tab whole but for an icon
    /// the app already has (`TabStore.applyTitles`), so only each tab's
    /// newest is read, when they are what they looked like: title changes of
    /// known tabs, numbered one after another from the store's last. Else
    /// every one is read, in order, as it would have been. The extension sends
    /// the whole tab with each update, whatever its `changes` name, so a line
    /// that looked like a title can move the tab's address: then every one is
    /// read, and true says the app is to hear of it at once (`movesAddress`).
    /// Only each tab's newest is checked on the way: a tab whose address went
    /// away and back between two collects is where it was.
    private func readHeld(_ kept: [(line: Data, at: Double)], into s: inout BrowserSession, from path: String) -> Bool {
        var newest: [Int: Int] = [:]
        for (i, k) in kept.enumerated() { if let id = Self.titleOnlyTab(k.line) { newest[id] = i } }
        var read: [Inbound] = []
        if s.store.hasSnapshot {
            for i in newest.values.sorted() {
                decodes += 1
                guard let m = try? dec.decode(Inbound.self, from: kept[i].line), m.type == "event", m.kind == "tabUpdated",
                      m.changes == ["title"], let t = m.tab, s.store.tabs[t.id] != nil, let seq = m.seq,
                      seq > (read.last?.seq ?? s.store.lastSeq), !Self.movesAddress(m, in: s.store) else { read = []; break }
                read.append(m)
            }
        }
        if let last = read.last, let seq = last.seq, read.count == newest.count,
           newest.values.max() == kept.count - 1, seq == s.store.lastSeq + kept.count {
            s.store.applyTitles(read, through: seq)
            for m in read { onLine?(path, m) }
            if let t = last.t { s.lastEventLatencyMs = kept[kept.count - 1].at - t }
            s.lastEventKind = last.kind
            return false
        }
        var moved = false
        for k in kept {
            decodes += 1
            guard let m = try? dec.decode(Inbound.self, from: k.line) else { continue }
            onLine?(path, m)
            if Self.movesAddress(m, in: s.store) { moved = true }
            take(m, into: &s, from: path, receivedAt: k.at)
        }
        return moved
    }

    /// The tab a line names when it looks like a change of that tab's title
    /// alone, read off its bytes without decoding it (in any order of keys:
    /// the browser may sort them). Nil when it may be anything else; such a
    /// line is read as it comes.
    static func titleOnlyTab(_ line: Data) -> Int? {
        line.withUnsafeBytes { raw -> Int? in
            guard Self.find(Self.eventMark, in: raw) != nil, Self.find(Self.updatedMark, in: raw) != nil,
                  Self.find(Self.titleMark, in: raw) != nil,
                  let at = Self.find(Self.idMark, in: raw) else { return nil }
            // One id only: the tab's.
            let after = at + Self.idMark.count
            guard Self.find(Self.idMark, in: UnsafeRawBufferPointer(rebasing: raw[after...])) == nil else { return nil }
            var id = 0, i = after
            while i < raw.count, raw[i] >= 0x30, raw[i] <= 0x39, i - after < 15 {
                id = id * 10 + Int(raw[i] - 0x30)
                i += 1
            }
            guard i > after, i < raw.count, raw[i] == 0x2C || raw[i] == 0x7D else { return nil } // , or }
            return id
        }
    }
    private static let eventMark = Array(#""type":"event""#.utf8)
    private static let updatedMark = Array(#""kind":"tabUpdated""#.utf8)
    private static let titleMark = Array(#""changes":["title"]"#.utf8)
    private static let idMark = Array(#""id":"#.utf8)

    private static func find(_ needle: [UInt8], in raw: UnsafeRawBufferPointer) -> Int? {
        guard let base = raw.baseAddress, raw.count >= needle.count else { return nil }
        return needle.withUnsafeBytes { n -> Int? in
            guard let hit = memmem(base, raw.count, n.baseAddress!, n.count) else { return nil }
            return base.distance(to: UnsafeRawPointer(hit))
        }
    }

    /// A tab update that changes a tab's address or window, or names a tab
    /// not known yet: the saved links' held tabs follow addresses, and must
    /// know a new one before the tab can close.
    static func movesAddress(_ m: Inbound, in store: TabStore) -> Bool {
        guard m.type == "event", m.kind == "tabUpdated", let t = m.tab else { return false }
        guard let old = store.tabs[t.id] else { return true }
        return old.url != t.url || old.windowId != t.windowId
    }
}

// MARK: - POSIX helpers

@discardableResult
func writeAllBytes(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { raw -> Bool in
        var off = 0
        while off < raw.count {
            let n = write(fd, raw.baseAddress! + off, raw.count - off)
            if n < 0 { if errno == EINTR { continue }; return false }
            off += n
        }
        return true
    }
}

func connectUnix(_ path: String) -> Int32 {
    #if canImport(Darwin)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    #else
    let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    #endif
    guard fd >= 0 else { return -1 }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let fits = withUnsafeMutableBytes(of: &addr.sun_path) { raw -> Bool in
        guard bytes.count < raw.count else { return false }
        raw.copyBytes(from: bytes); raw[bytes.count] = 0
        return true
    }
    guard fits else { close(fd); return -1 }
    #if canImport(Darwin)
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    #endif
    let r = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Glue.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    if r != 0 { let e = errno; close(fd); errno = e; return -1 }
    return fd
}

enum Glue {
    static func connect(_ fd: Int32, _ a: UnsafePointer<sockaddr>, _ l: socklen_t) -> Int32 {
        #if canImport(Darwin)
        return Darwin.connect(fd, a, l)
        #else
        return Glibc.connect(fd, a, l)
        #endif
    }
}

/// Calls `onChange` whenever an entry is added to or removed from `path`.
/// kqueue vnode events on macOS, inotify on Linux. Blocking, not polling.
final class DirectoryWatcher: @unchecked Sendable {
    #if canImport(Darwin)
    private var source: DispatchSourceFileSystemObject?
    init(path: String, onChange: @escaping @Sendable () -> Void) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .link, .rename], queue: .global())
        src.setEventHandler(handler: onChange)
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }
    deinit { source?.cancel() }
    #else
    init(path: String, onChange: @escaping @Sendable () -> Void) {
        let fd = inotify_init1(Int32(IN_CLOEXEC))
        guard fd >= 0 else { return }
        guard inotify_add_watch(fd, path, UInt32(IN_CREATE | IN_DELETE | IN_MOVED_TO | IN_MOVED_FROM)) >= 0 else { close(fd); return }
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 4096)
            while read(fd, &buf, buf.count) > 0 { onChange() }
        }
    }
    #endif
}
