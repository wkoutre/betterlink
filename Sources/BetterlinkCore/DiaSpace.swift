import Foundation

/// Opening a link in one Dia profile.
///
/// Dia refuses a second process ("Dia is already open. Only one instance of
/// Dia can be opened at a time."), so the `--profile-directory` launch every
/// other Chromium browser gets never reaches it. Dia's AppleScript dictionary
/// (Dia.sdef, read from Dia 1.58) calls each space a `profile`: a window lists
/// its `profiles`, and `focus` switches the window to one. betterlink focuses
/// the space whose name matches the profile's, in Dia's front window, then
/// hands Dia the link the ordinary way, which opens it in that space. Raycast's
/// Dia extension switches spaces with the same `focus profile <name> of <window>`.
///
/// The space name is passed as an osascript argument after `--`, so no name
/// can change the script: without `--`, a name such as `-e <code>` would be
/// read as another script line.
public enum DiaSpace {
    /// The AppleScript source; argument 1 is the space name. It starts Dia if
    /// needed, waits up to 5 s for a window, and prints one `Outcome` word.
    public static let script = """
    on run argv
      set spaceName to item 1 of argv
      tell application "Dia"
        repeat 50 times
          if (count of windows) > 0 then exit repeat
          delay 0.1
        end repeat
        if (count of windows) = 0 then return "nowindow"
        set w to window 1
        try
          set p to profile spaceName of w
          get name of p
        on error number n
          if n is -1743 then error number n
          return "nospace"
        end try
        focus p
        return "focused"
      end tell
    end run
    """

    /// The `osascript` arguments that run `script` for `space`.
    public static func osascriptArguments(space: String) -> [String] {
        ["-e", script, "--", space]
    }

    /// What the switch came to. Only `.focused` puts the link in the space it
    /// was meant for. After anything else Dia would open it in whichever space
    /// is in front, which may be another profile, so the link goes to the
    /// fallback profile instead (`LaunchPlan.afterFailedSwitch`). It opens in
    /// Dia's current space only when it was headed for the fallback already
    /// and there is nowhere else to send it.
    public enum Outcome: Equatable, Sendable {
        /// The front window now shows the space.
        case focused
        /// Dia has no space with that name.
        case noSuchSpace
        /// Dia showed no window in time.
        case noWindow
        /// macOS refused betterlink control of Dia (Privacy & Security ›
        /// Automation).
        case notAllowed
        /// osascript failed some other way; the message is its error text.
        case failed(String)

        /// Whether Dia's front window shows the space the link is for.
        public var switched: Bool { self == .focused }

        /// Reads osascript's exit status, standard output and standard error.
        public static func parse(status: Int32, output: String, error: String) -> Outcome {
            if status == 0 {
                switch output.trimmingCharacters(in: .whitespacesAndNewlines) {
                case "focused": return .focused
                case "nospace": return .noSuchSpace
                case "nowindow": return .noWindow
                default: return .failed("unexpected reply: \(output.prefix(200))")
                }
            }
            // -1743: errAEEventNotPermitted, the Automation permission.
            if error.contains("-1743") || error.localizedCaseInsensitiveContains("not authorized") { return .notAllowed }
            let text = error.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(text.isEmpty ? "osascript exited with \(status)" : String(text.prefix(300)))
        }

        /// A line for the Log, or nil when the space was found.
        /// - Parameter fallback: the name of the fallback profile the link
        ///   opened in instead, or nil when it was handed to Dia anyway.
        public func note(space: String, openedIn fallback: String? = nil) -> String? {
            let why: String
            switch self {
            case .focused: return nil
            case .noSuchSpace: why = "Dia has no space named \"\(space)\""
            case .noWindow: why = "Dia had no window to switch to \"\(space)\""
            case .notAllowed: why = "betterlink isn't allowed to control Dia"
            case .failed(let reason): why = "Couldn't switch Dia to \"\(space)\" (\(reason))"
            }
            let allow = self == .notAllowed ? " Allow it in System Settings › Privacy & Security › Automation." : ""
            if let fallback { return "\(why), so the link opened in \(fallback) instead.\(allow)" }
            let place = self == .noWindow ? "wherever Dia put it" : "in the current space"
            return "\(why), so the link opened \(place).\(allow)"
        }
    }
}
