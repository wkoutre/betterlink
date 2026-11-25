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
        home.appendingPathComponent("Library/Application Support")
            .appendingPathComponent(dataFolder)
            .appendingPathComponent("NativeMessagingHosts/\(hostName).json")
    }

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

    public static func state(dataFolder: String, hostPath: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> State {
        let url = manifestURL(dataFolder: dataFolder, home: home)
        guard let d = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return .notInstalled }
        let p = obj["path"] as? String ?? ""
        let allowed = obj["allowed_origins"] as? [String] ?? []
        return p == hostPath && allowed.contains(origin) ? .installed : .stale(path: p)
    }

    /// Writes the manifest. Refuses when the browser's data folder does not
    /// exist (the browser was never run), so we never create a browser's folder.
    public static func install(dataFolder: String, hostPath: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let url = manifestURL(dataFolder: dataFolder, home: home)
        let browserDir = url.deletingLastPathComponent().deletingLastPathComponent()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: browserDir.path, isDirectory: &isDir), isDir.boolValue else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: browserDir.path])
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manifest(hostPath: hostPath).write(to: url, options: .atomic)
    }

    public static func uninstall(dataFolder: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let url = manifestURL(dataFolder: dataFolder, home: home)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
