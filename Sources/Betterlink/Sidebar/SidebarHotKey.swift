import BetterlinkCore
import Carbon.HIToolbox
import Foundation

/// A system-wide keyboard shortcut. Registered only while it is needed, so it
/// never takes the keys from other apps the rest of the time. No permission is
/// needed for a registered hot key (unlike watching every key press).
@MainActor
final class SidebarHotKey {
    /// Changing it re-registers at once when it is registered.
    var shortcut = Shortcut.sidebarDefault {
        didSet {
            guard shortcut != oldValue else { return }
            refused = nil; problem = nil
            if ref != nil { unregister(); register() }
        }
    }

    var onPress: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    var isRegistered: Bool { ref != nil }
    /// Why macOS refused the shortcut, or nil. A refused shortcut is not tried
    /// again until it changes (review F3).
    private(set) var problem: String?
    private var refused: Shortcut?

    func setRegistered(_ on: Bool) {
        on ? register() : unregister()
    }

    private func register() {
        guard ref == nil, refused != shortcut else { return }
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
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            ref = nil
            refused = shortcut
            problem = "macOS refused \(shortcut.display) (error \(status)); another app may use it. Pick another."
        }
    }

    private func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }
}
