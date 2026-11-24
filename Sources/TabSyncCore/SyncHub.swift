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
    public var store = TabStore()
    /// Browser event -> app, measured on the shared machine clock.
    public var lastEventLatencyMs: Double?
    public var lastEventKind: String?
    /// App command -> browser ack, round trip.
    public var lastCommandRoundTripMs: Double?
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

    public init(directory: String = SocketDirectory.path,
                onLine: (@Sendable (String, Inbound) -> Void)? = nil,
                onChange: @escaping Listener) {
        self.dir = directory
        self.onChange = onChange
        self.onLine = onLine
    }

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
                let lines = dec.feed(Data(buf[0..<n]))
                let received = nowMs()
                guard let hub = self else { return }
                hub.q.async { hub.handle(lines, from: path, receivedAt: received) }
            }
            guard let hub = self else { return }
            hub.q.async { hub.disconnect(path) }
        }
    }

    private func disconnect(_ path: String) {
        if let fd = connections.removeValue(forKey: path) { close(fd) }
        if sessions.removeValue(forKey: path) != nil { publish() }
    }

    private func handle(_ lines: [Data], from path: String, receivedAt: Double) {
        guard var s = sessions[path] else { return }
        let dec = JSONDecoder()
        for line in lines {
            guard let m = try? dec.decode(Inbound.self, from: line) else { continue }
            onLine?(path, m)
            switch m.type {
            case "host":
                s.browser = m.browser ?? s.browser
                s.pid = m.pid ?? s.pid
                s.browserPid = m.browserPid ?? s.browserPid
            case "hello":
                s.brands = m.brands ?? []
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
        sessions[path] = s
        publish()
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
