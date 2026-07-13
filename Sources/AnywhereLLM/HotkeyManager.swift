import AppKit
import Carbon.HIToolbox

/// Global hotkey via Carbon RegisterEventHotKey. Fires even when the app is not active
/// and needs no accessibility permission for the registration itself.
///
/// Defaults (overridable via UserDefaults, settings UI comes in step 6):
///   "hotkeyKeyCode"   — virtual key code (default kVK_Space)
///   "hotkeyModifiers" — Carbon modifier mask (default cmd+shift)
@MainActor
final class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let handler: () -> Void

    // Carbon signature ('ALLM') + id; only one hotkey so id is fixed.
    private static let signature: OSType = 0x414C4C4D // 'ALLM'
    private let hotKeyID = EventHotKeyID(signature: HotkeyManager.signature, id: 1)

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    /// Register the hotkey and install the Carbon event handler. Idempotent.
    func start() {
        guard hotKeyRef == nil else { return }

        installHandlerIfNeeded()

        let keyCode = UInt32(UserDefaults.standard.object(forKey: "hotkeyKeyCode") as? Int ?? kVK_Space)
        let modifiers = UInt32(
            UserDefaults.standard.object(forKey: "hotkeyModifiers") as? Int ?? (cmdKey | shiftKey)
        )

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref)
        if status == noErr {
            hotKeyRef = ref
        } else {
            NSLog("AnywhereLLM: RegisterEventHotKey failed (\(status)) — likely a system-wide conflict.")
        }
    }

    func stop() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // Pass self through userData so the C callback can route back without capturing.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                var firedID = EventHotKeyID()
                let err = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &firedID
                )
                guard err == noErr, firedID.signature == HotkeyManager.signature else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                // Callback runs on the main run loop; hop to the main actor for the Swift-side handler.
                DispatchQueue.main.async { MainActor.assumeIsolated { manager.handler() } }
                return noErr
            },
            1, &spec, selfPtr, &eventHandler
        )
    }
}
