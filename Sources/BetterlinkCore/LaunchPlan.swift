import Foundation

/// The exact process launch that opens a link in one browser profile.
///
/// The link travels on the browser's command line, which is the only way a
/// Chromium browser that is already running honours --profile-directory
/// (Finch sent the link separately, and the running browser used whichever
/// profile was last active). The command line is new attack surface, so:
/// - the link argument must start with http://, https:// or file:// and hold
///   no control characters, so it can never be read as a switch;
/// - for Chromium it also comes after "--";
/// - the browser must be one betterlink knows, and the profile one it has
///   stored (or the fallback), named the way that browser family names
///   profiles ("Default"/"Profile 3" for Chromium; a Firefox name may not
///   start with "-"), so nothing else reaches the command line through it.
/// Browsers without profiles (Safari, Arc) get the link the ordinary way.
/// Dia allows one process only, so it gets `.switchSpace`: see `DiaSpace`.
public struct LaunchPlan: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        /// Start the browser with these arguments (a running browser hands
        /// them to its existing process).
        case commandLine([String])
        /// Hand the link to the browser the ordinary way: no profile choice.
        case openURL(String)
        /// Switch the running browser's front window to the profile with this
        /// name by AppleScript, then hand it the link the ordinary way, so the
        /// link opens in that profile. For browsers that refuse a second
        /// process (Dia, where a profile is a space).
        case switchSpace(name: String, link: String)
    }

    public let bundleId: String
    public let mode: Mode

    /// The command-line arguments, or [] for `.openURL`.
    public var arguments: [String] {
        if case .commandLine(let a) = mode { return a }
        return []
    }

    public enum Failure: Error, Equatable, Sendable {
        case targetsSelf
        case unknownBrowser(String)
        case unknownProfile(String)
        case unsafeArgument
    }

    /// - Parameter fallback: the fallback profile. It is allowed even when no
    ///   profiles are stored, so links still open somewhere.
    public static func make(profile: BrowserProfile, argument: String, catalog: ProfileCatalog,
                            fallback: ProfileRef? = nil, ownBundleId: String) -> Result<LaunchPlan, Failure> {
        // A browser target that is betterlink itself would hand the link back
        // to betterlink forever.
        guard profile.browser.lowercased() != ownBundleId.lowercased() else { return .failure(.targetsSelf) }
        guard let browser = Browser.known(bundleId: profile.browser) else { return .failure(.unknownBrowser(profile.browser)) }
        guard BrowserProfile.isValid(directory: profile.directory, family: browser.family),
              catalog.profile(profile.ref) != nil || profile.ref == fallback
        else { return .failure(.unknownProfile(profile.directory)) }
        let lower = argument.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("file://"),
              !argument.unicodeScalars.contains(where: { $0.value < 0x20 })
        else { return .failure(.unsafeArgument) }
        if browser.switchesProfileByScript {
            // The script finds the space by its name, which travels as an
            // osascript argument (never in the script's source), so any name
            // is safe there; control characters still mean a broken file.
            let name = catalog.profile(profile.ref)?.name ?? profile.name
            guard !name.isEmpty, !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
            else { return .failure(.unknownProfile(profile.directory)) }
            return .success(LaunchPlan(bundleId: browser.bundleId, mode: .switchSpace(name: name, link: argument)))
        }
        switch browser.family {
        case .chromium:
            return .success(LaunchPlan(bundleId: browser.bundleId,
                                       mode: .commandLine(["--profile-directory=\(profile.directory)", "--", argument])))
        case .firefox:
            // Firefox has no "--" terminator; the link can't be read as a
            // switch because it must start with http(s):// or file://.
            return .success(LaunchPlan(bundleId: browser.bundleId, mode: .commandLine(["-P", profile.directory, argument])))
        case .plain:
            return .success(LaunchPlan(bundleId: browser.bundleId, mode: .openURL(argument)))
        }
    }
}
