import Foundation

/// Keeps betterlink's command-line modes (`agent`, `--test`,
/// `--import-profiles`) from running with betterlink's own privacy grants.
///
/// macOS decides what a process may read (Full Disk Access, another app's
/// data) by its *responsible* process. Run from a terminal, a script or a
/// coding agent, betterlink's command is that caller's child, the caller is
/// responsible, and the command can read only what the caller can.
///
/// Started through LaunchServices or launchd instead
/// (`open -n -a betterlink.app --args agent …`), betterlink is responsible for
/// itself, so the command would run with whatever the user granted the app.
/// The commands read and copy files a settings folder names, and any program
/// can choose that folder, so a program without Full Disk Access could have
/// betterlink read a protected file for it. Refusing to run that way closes it:
/// nothing legitimate starts the command through LaunchServices.
public enum CommandLineGuard {
    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t

    /// `responsibility_get_pid_responsible_for_pid`, which libSystem exports
    /// but no public header declares, so it is looked up at run time.
    private static let responsibleFn: ResponsibleFn? = {
        // RTLD_DEFAULT: search every image already loaded.
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()

    /// The process macOS holds responsible for `pid`, or nil when macOS
    /// doesn't say.
    public static func responsiblePid(for pid: pid_t = getpid()) -> pid_t? {
        guard let responsibleFn else { return nil }
        let r = responsibleFn(pid)
        return r > 0 ? r : nil
    }

    /// Why a command-line mode must not run in this process, or nil when it
    /// may. When macOS doesn't say who is responsible, the command runs:
    /// refusing would break it for everyone.
    public static func refusal(ownPid: pid_t = getpid(), responsiblePid: pid_t? = responsiblePid()) -> String? {
        guard let responsiblePid, responsiblePid == ownPid else { return nil }
        return "betterlink's command can't be started as an app (with open, or as a launch agent): "
            + "it would run with the app's own permissions instead of the caller's. "
            + "Run the betterlink command from a terminal or a script."
    }
}
