// betterlink-tabhost: the native messaging host a Chrome-family browser launches when
// the betterlink Tabs extension calls chrome.runtime.connectNative("com.wkoutre.betterlink.tabs").
//
//   browser  <-- stdio, 4-byte length + JSON -->  host  <-- Unix socket, NDJSON -->  app
//
// One host process per browser profile. It listens on its own socket in the
// shared socket directory; the app watches that directory (kqueue, no polling)
// and connects to each new socket, so either side can start first.
// Every message is forwarded the instant it is read. Nothing here polls.
import Foundation
import TabSyncCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

setvbuf(stderr, nil, _IONBF, 0)
signal(SIGPIPE, SIG_IGN)

func log(_ s: String) { FileHandle.standardError.write(("[betterlink-tabhost] " + s + "\n").data(using: .utf8)!) }

// MARK: - Who launched us

func parentAppName() -> String? {
    // Tests name the "browser" themselves; a real browser never sets this.
    if let n = ProcessInfo.processInfo.environment["BETTERLINK_TABS_BROWSER_NAME"], !n.isEmpty { return n }
    #if canImport(Darwin)
    var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    guard proc_pidpath(getppid(), &buf, UInt32(buf.count)) > 0 else { return nil }
    let path = String(cString: buf)
    // ".../Google Chrome.app/Contents/MacOS/Google Chrome" -> "Google Chrome"
    if let app = path.components(separatedBy: "/").first(where: { $0.hasSuffix(".app") }) {
        return String(app.dropLast(4))
    }
    return (path as NSString).lastPathComponent
    #else
    return nil
    #endif
}

let origin = CommandLine.arguments.dropFirst().first(where: { $0.hasPrefix("chrome-extension://") }) ?? ""
let browserName = parentAppName() ?? "Browser"
let myPid = Int(getpid())
let slug = browserName.lowercased().filter { $0.isLetter || $0.isNumber }

// MARK: - Socket

let dir = SocketDirectory.path
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
let socketPath = "\(dir)/\(slug.isEmpty ? "browser" : slug)-\(myPid).sock"

func makeAddr(_ path: String) -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    #if canImport(Darwin)
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    #endif
    let bytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        precondition(bytes.count < raw.count, "socket path too long: \(path)")
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    return addr
}

#if canImport(Darwin)
let streamType = SOCK_STREAM
#else
let streamType = Int32(SOCK_STREAM.rawValue)
#endif

let listenFd = socket(AF_UNIX, streamType, 0)
guard listenFd >= 0 else { log("socket() failed: \(errno)"); exit(1) }
unlink(socketPath)
var addr = makeAddr(socketPath)
let bound = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
guard bound == 0 else { log("bind(\(socketPath)) failed: \(errno)"); exit(1) }
chmod(socketPath, 0o600)
guard listen(listenFd, 8) == 0 else { log("listen failed: \(errno)"); exit(1) }

@Sendable func cleanupAndExit(_ code: Int32) -> Never {
    unlink(socketPath)
    exit(code)
}
for sig in [SIGTERM, SIGINT, SIGHUP] { signal(sig) { _ in unlink(socketPath); _exit(0) } }

// MARK: - Writers

let stdoutLock = NSLock()
@Sendable func writeAll(_ fd: Int32, _ data: Data) -> Bool {
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

/// host -> browser. Serialized: several app connections may write at once.
@Sendable func toBrowser(_ json: Data) {
    guard json.count <= NativeFraming.maxOutbound else { log("dropped oversize command"); return }
    stdoutLock.lock(); defer { stdoutLock.unlock() }
    if !writeAll(STDOUT_FILENO, NativeFraming.encode(json)) { cleanupAndExit(0) }
}

let clientsLock = NSLock()
var clients: [Int32] = []

/// host -> every connected app.
func toApps(_ line: Data) {
    var framed = line; framed.append(0x0A)
    clientsLock.lock()
    let snapshot = clients
    clientsLock.unlock()
    for fd in snapshot where !writeAll(fd, framed) { drop(fd) }
}

@Sendable func drop(_ fd: Int32) {
    clientsLock.lock()
    let had = clients.contains(fd)
    clients.removeAll { $0 == fd }
    clientsLock.unlock()
    if had { close(fd) }
}

@Sendable func json(_ obj: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: obj)) ?? Data() }

let hostHello = json(["type": "host", "browser": browserName, "pid": myPid, "origin": origin])
var lastHello: Data? // the extension's hello, replayed to apps that connect later
let helloLock = NSLock()

// MARK: - App connections

Thread.detachNewThread {
    while true {
        let fd = accept(listenFd, nil, nil)
        if fd < 0 { if errno == EINTR { continue }; log("accept failed: \(errno)"); continue }
        #if canImport(Darwin)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var greet = hostHello; greet.append(0x0A)
        helloLock.lock(); if let h = lastHello { greet.append(h); greet.append(0x0A) }; helloLock.unlock()
        guard writeAll(fd, greet) else { close(fd); continue }
        clientsLock.lock(); clients.append(fd); clientsLock.unlock()
        // A new app needs the full picture: ask the extension for a snapshot.
        toBrowser(json(["type": "cmd", "id": "host-\(fd)", "op": "snapshot", "t": Date().timeIntervalSince1970 * 1000]))
        Thread.detachNewThread {
            var dec = LineDecoder()
            var buf = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = read(fd, &buf, buf.count)
                if n <= 0 { if n < 0 && errno == EINTR { continue }; break }
                for line in dec.feed(Data(buf[0..<n])) {
                    // Only well-formed commands go to the browser.
                    guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          obj["type"] as? String == "cmd" else { continue }
                    toBrowser(line)
                }
            }
            drop(fd)
        }
    }
}

// MARK: - Browser -> apps (main thread)

toBrowser(hostHello) // tells the extension the host is really up (resets its backoff)
log("listening on \(socketPath) for \(browserName)")

var dec = NativeFraming.Decoder()
var buf = [UInt8](repeating: 0, count: 256 * 1024)
while true {
    let n = read(STDIN_FILENO, &buf, buf.count)
    if n == 0 { break }                       // browser closed the pipe: it quit or the extension disconnected
    if n < 0 { if errno == EINTR { continue }; break }
    for msg in dec.feed(Data(buf[0..<n])) {
        if let obj = try? JSONSerialization.jsonObject(with: msg) as? [String: Any], obj["type"] as? String == "hello" {
            helloLock.lock(); lastHello = msg; helloLock.unlock()
        }
        toApps(msg)
    }
}
cleanupAndExit(0)
