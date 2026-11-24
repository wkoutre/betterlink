import Carbon.HIToolbox
import Foundation

/// A system-wide keyboard shortcut. Registered only while it is needed, so it
/// never takes the keys from other apps the rest of the time. No permission is
/// needed for a registered hot key (unlike watching every key press).
@MainActor
final class SidebarHotKey {
    /// Control-Option-S.
    static let display = "⌃⌥S"
    private let keyCode = UInt32(kVK_ANSI_S)
    private let modifiers = UInt32(controlKey | optionKey)

    var onPress: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    var isRegistered: Bool { ref != nil }

    func setRegistered(_ on: Bool) {
        on ? register() : unregister()
    }

    private func register() {
        guard ref == nil else { return }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let me = Unmanaged.passUnretained(self).toOpaque()
            InstallEventHandler(GetApplicationEventTarget(), { _, _, refcon in
                guard let refcon else { return noErr }
                let hk = Unmanaged<SidebarHotKey>.fromOpaque(refcon).takeUnretainedValue()
                MainActor.assumeIsolated { hk.onPress?() }
                return noErr
            }, 1, &spec, me, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x626C_7362), id: 1) // "blsb"
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }

    private func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }
}
