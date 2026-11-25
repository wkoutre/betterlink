import Foundation

/// Chrome native messaging framing: a 32-bit length in native byte order
/// (little-endian on every Mac), then that many bytes of UTF-8 JSON.
public enum NativeFraming {
    /// Chrome refuses host -> browser messages over 1 MB.
    public static let maxOutbound = 1024 * 1024

    public static func encode(_ json: Data) -> Data {
        var len = UInt32(json.count).littleEndian
        var out = Data(bytes: &len, count: 4)
        out.append(json)
        return out
    }

    /// Accumulates bytes from the browser's stdout pipe and yields whole messages.
    public struct Decoder {
        private var buf = Data()
        public init() {}
        public mutating func feed(_ chunk: Data) -> [Data] {
            buf.append(chunk)
            var out: [Data] = []
            while buf.count >= 4 {
                let b = [UInt8](buf.prefix(4))
                let len = Int(UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24)
                guard buf.count >= 4 + len else { break }
                out.append(Data(buf.dropFirst(4).prefix(len)))
                buf = Data(buf.dropFirst(4 + len))
            }
            return out
        }
    }
}

/// Newline-delimited JSON, used on the host <-> app Unix socket.
/// JSON.stringify and JSONEncoder never emit a raw newline, so "\n" is a safe delimiter.
public struct LineDecoder {
    private var buf = Data()
    public init() {}
    public mutating func feed(_ chunk: Data) -> [Data] {
        buf.append(chunk)
        var out: [Data] = []
        while let nl = buf.firstIndex(of: 0x0A) {
            let line = buf[buf.startIndex..<nl]
            if !line.isEmpty { out.append(Data(line)) }
            buf = Data(buf[buf.index(after: nl)...])
        }
        return out
    }
}

/// Where hosts put their sockets and the app looks for them.
public enum SocketDirectory {
    public static var path: String {
        if let o = ProcessInfo.processInfo.environment["BETTERLINK_TABS_SOCKET_DIR"], !o.isEmpty { return o }
        #if os(macOS)
        return NSHomeDirectory() + "/Library/Application Support/betterlink-tabs/sockets"
        #else
        return NSTemporaryDirectory() + "betterlink-tabs-sockets"
        #endif
    }
}
