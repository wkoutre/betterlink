import Foundation

/// Registers betterlink's tab host with a Chromium-family browser by writing
/// one JSON file into that browser's NativeMessagingHosts folder. That file is
/// the only thing outside betterlink's own folders that Tabs ever writes, and
/// only when the user asks for it per browser.
public enum HostRegistration {
    public static let hostName = "com.wkoutre.betterlink.tabs"
    /// The extension's Chrome Web Store item id. The "key" in
    /// browser-extension/manifest.json is that item's public key, so an unpacked
    /// copy has this id too and both match `allowed_origins`.
    public static let extensionId = "gjjllnebeeegbipppiclhlomdppbnljh"
    static var origin: String { "chrome-extension://\(extensionId)/" }

    /// `dataFolder` is the browser's folder under ~/Library/Application Support
    /// (`Browser.dataFolder`, e.g. "Google/Chrome" or "Dia/User Data").
    public static func manifestURL(dataFolder: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        support(home).appendingPathComponent(dataFolder)
            .appendingPathComponent("NativeMessagingHosts/\(hostName).json")
    }

    /// The folder whose NativeMessagingHosts a browser really reads. Brave on
    /// macOS reads Google Chrome's, never its own: verified live on Brave
    /// 1.100 (158) with its default and a custom data folder (its log names
    /// the file it found). So Brave and Chrome share one file.
    public static func readFolder(dataFolder: String) -> String {
        dataFolder.hasPrefix("BraveSoftware/") ? chromeFolder : dataFolder
    }
    static let chromeFolder = "Google/Chrome"

    /// The file the browser reads, which `state` checks.
    public static func readURL(dataFolder: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        manifestURL(dataFolder: readFolder(dataFolder: dataFolder), home: home)
    }

    static func support(_ home: URL) -> URL { home.appendingPathComponent("Library/Application Support") }

    public static func manifest(hostPath: String) -> Data {
        let obj: [String: Any] = [
            "name": hostName,
            "description": "betterlink Tabs: live tab sync with the betterlink app",
            "path": hostPath,
            "type": "stdio",
            "allowed_origins": [origin],
        ]
        return try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    }

    public enum State: Equatable, Sendable {
        case notInstalled
        case installed
        /// Registered, but not for this betterlink: the host binary is at another
        /// path (an older or moved betterlink), or the file allows another
        /// extension id (written before the extension took its store id).
        case stale(path: String)
    }

    /// Whether the file the browser reads (`readURL`) is set up for this betterlink.
    public static func state(dataFolder: String, hostPath: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> State {
        ownState(readURL(dataFolder: dataFolder, home: home), hostPath: hostPath)
    }

    /// Writes the manifest into the browser's own folder and, for a browser
    /// that reads another's (`readFolder`), into that one too, so it works
    /// today and if the browser starts reading its own. Refuses when the
    /// browser's data folder does not exist (the browser was never run), so
    /// we never create a browser's folder for a browser that isn't used.
    public static func install(dataFolder: String, hostPath: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let browserDir = support(home).appendingPathComponent(dataFolder)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: browserDir.path, isDirectory: &isDir), isDir.boolValue else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: browserDir.path])
        }
        for url in Set([manifestURL(dataFolder: dataFolder, home: home), readURL(dataFolder: dataFolder, home: home)]) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manifest(hostPath: hostPath).write(to: url, options: .atomic)
        }
    }

    /// What `uninstall` did.
    public enum Removal: Equatable, Sendable {
        case removed
        /// The shared file stays, because these browsers also read it and
        /// are still set up (`sharers`).
        case keptFor([String])
    }

    /// Removes the browser's own file, and the file it reads unless another
    /// set-up browser reads the same one. `sharers` are the other browsers'
    /// data folders (`Browser.dataFolder`) to weigh.
    @discardableResult
    public static func uninstall(dataFolder: String, sharers: [String] = [], home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> Removal {
        let own = manifestURL(dataFolder: dataFolder, home: home), read = readURL(dataFolder: dataFolder, home: home)
        if own != read, FileManager.default.fileExists(atPath: own.path) { try FileManager.default.removeItem(at: own) }
        let users = sharers.filter { $0 != dataFolder && readFolder(dataFolder: $0) == readFolder(dataFolder: dataFolder) && isSetUp(dataFolder: $0, home: home) }
        if !users.isEmpty { return .keptFor(users) }
        if FileManager.default.fileExists(atPath: read.path) { try FileManager.default.removeItem(at: read) }
        return .removed
    }

    /// Whether a browser still counts as set up for sharing the read file: a
    /// browser that reads another's folder by its own file, the folder's
    /// owner by having been run (its data folder holds Local State).
    static func isSetUp(dataFolder: String, home: URL) -> Bool {
        if readFolder(dataFolder: dataFolder) != dataFolder {
            return FileManager.default.fileExists(atPath: manifestURL(dataFolder: dataFolder, home: home).path)
        }
        return FileManager.default.fileExists(atPath: support(home).appendingPathComponent(dataFolder).appendingPathComponent("Local State").path)
    }

    /// A browser set up before betterlink knew where it reads (its own file
    /// is there, the read one isn't): writes the read one. Run at launch.
    @discardableResult
    public static func repair(dataFolder: String, hostPath: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let own = manifestURL(dataFolder: dataFolder, home: home), read = readURL(dataFolder: dataFolder, home: home)
        guard own != read, FileManager.default.fileExists(atPath: own.path), !FileManager.default.fileExists(atPath: read.path),
              ownState(own, hostPath: hostPath) == .installed else { return false }
        do {
            try FileManager.default.createDirectory(at: read.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manifest(hostPath: hostPath).write(to: read, options: .atomic)
            return true
        } catch { return false }
    }

    static func ownState(_ url: URL, hostPath: String) -> State {
        guard let d = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return .notInstalled }
        let p = obj["path"] as? String ?? ""
        let allowed = obj["allowed_origins"] as? [String] ?? []
        return p == hostPath && allowed.contains(origin) ? .installed : .stale(path: p)
    }
}
