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
    // nonisolated(unsafe): main에서만 변경되는 Carbon 포인터. nonisolated deinit이
    // 정리하려면 격리를 벗겨야 한다 — deinit은 배타적 접근이라 레이스 없음.
    nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?
    nonisolated(unsafe) private var eventHandler: EventHandlerRef?
    private let handler: () -> Void

    // Carbon signature ('ALLM') + id; only one hotkey so id is fixed.
    private static let signature: OSType = 0x414C4C4D // 'ALLM'
    private let hotKeyID = EventHotKeyID(signature: HotkeyManager.signature, id: 1)

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    /// Register the hotkey and install the Carbon event handler. Idempotent.
    /// Returns false if the handler install or the registration failed (e.g.
    /// eventHotKeyExistsErr when another app owns the combo) so the caller can
    /// surface it — a menubar-only app whose sole trigger silently dies is unusable.
    @discardableResult
    func start() -> Bool {
        guard hotKeyRef == nil else { return true }

        guard installHandlerIfNeeded() else { return false }

        // UserDefaults는 검증 대상 신뢰 경계다 — 손상된 plist나 외부 프로세스가 쓴
        // 범위 밖 값(음수/초과)에 대해 트래핑 UInt32(Int) 이니셜라이저는 실행 즉시
        // 크래시하고, 값이 저장돼 있어 매 실행 크래시한다. exactly로 안전 폴백.
        let keyCode = (UserDefaults.standard.object(forKey: "hotkeyKeyCode") as? Int)
            .flatMap { UInt32(exactly: $0) } ?? UInt32(kVK_Space)
        let modifiers = (UserDefaults.standard.object(forKey: "hotkeyModifiers") as? Int)
            .flatMap { UInt32(exactly: $0) } ?? UInt32(cmdKey | shiftKey)

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref)
        if status == noErr {
            hotKeyRef = ref
            return true
        }
        NSLog("AnywhereLLM: RegisterEventHotKey failed (\(status)) — likely a system-wide conflict.")
        return false
    }

    func stop() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    @discardableResult
    private func installHandlerIfNeeded() -> Bool {
        guard eventHandler == nil else { return true }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // Pass self through userData so the C callback can route back without capturing.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let status = InstallEventHandler(
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
        if status != noErr {
            NSLog("AnywhereLLM: InstallEventHandler failed (\(status)).")
            return false
        }
        return true
    }

    // 핸들러는 userData로 self의 unretained 포인터를 들고 있다. 현재 인스턴스는
    // 앱 수명 내내 살아 있어 도달 불가하지만, stop()이 완전한 teardown처럼 읽히는데
    // C 콜백은 계속 살아 있다 — 인스턴스가 해제/교체되면 다음 핫키가 해제된
    // 메모리를 참조(use-after-free)한다. deinit에서 확실히 정리해 하자를 봉인.
    deinit {
        if let eventHandler { RemoveEventHandler(eventHandler) }
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
    }
}
