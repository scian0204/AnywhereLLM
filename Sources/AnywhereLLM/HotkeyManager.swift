import AppKit
import Carbon.HIToolbox

/// Global hotkeys via Carbon RegisterEventHotKey. Fires even when the app is not
/// active and needs no accessibility permission for the registration itself.
///
/// Holds one or more `Hotkey` bindings, each with its own Carbon id, its own pair
/// of UserDefaults keys, and its own action. A single installed Carbon event
/// handler routes by the fired hotkey's id — using one handler (not one per
/// binding) avoids event-chain ambiguity when several hotkeys share our signature.
@MainActor
final class HotkeyManager {
    /// One registered global hotkey: Carbon id, the UserDefaults keys holding its
    /// combo, safe defaults, and what to run when it fires.
    struct Hotkey {
        let id: UInt32
        let keyCodeDefaultsKey: String
        let modifiersDefaultsKey: String
        let defaultKeyCode: UInt32
        let defaultModifiers: UInt32
        let action: () -> Void
    }

    // nonisolated(unsafe): main에서만 변경되는 Carbon 포인터. nonisolated deinit이
    // 정리하려면 격리를 벗겨야 한다 — deinit은 배타적 접근이라 레이스 없음.
    nonisolated(unsafe) private var eventHandler: EventHandlerRef?
    nonisolated(unsafe) private var refs: [UInt32: EventHotKeyRef] = [:] // id → ref
    let hotkeys: [Hotkey]

    // Carbon signature ('ALLM') shared by every binding; the id disambiguates.
    private static let signature: OSType = 0x414C4C4D // 'ALLM'

    init(hotkeys: [Hotkey]) {
        self.hotkeys = hotkeys
    }

    /// Register every not-yet-registered hotkey from current settings. Idempotent
    /// (an already-registered id is skipped). Returns the ids that FAILED to
    /// register (empty = all good) so the caller can surface a conflict per hotkey.
    @discardableResult
    func start() -> [UInt32] {
        guard installHandlerIfNeeded() else { return hotkeys.map(\.id) }

        var failed: [UInt32] = []
        for hk in hotkeys where refs[hk.id] == nil {
            // UserDefaults는 검증 대상 신뢰 경계다 — 범위 밖 값(음수/초과)에 트래핑
            // UInt32(Int) 이니셜라이저는 실행 즉시 크래시하고 값이 저장돼 매 실행
            // 크래시한다. exactly로 안전 폴백.
            let keyCode = (UserDefaults.standard.object(forKey: hk.keyCodeDefaultsKey) as? Int)
                .flatMap { UInt32(exactly: $0) } ?? hk.defaultKeyCode
            let modifiers = (UserDefaults.standard.object(forKey: hk.modifiersDefaultsKey) as? Int)
                .flatMap { UInt32(exactly: $0) } ?? hk.defaultModifiers

            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: hk.id)
            let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref)
            if status == noErr, let ref {
                refs[hk.id] = ref
            } else {
                failed.append(hk.id)
                NSLog("AnywhereLLM: RegisterEventHotKey failed (\(status)) for id \(hk.id) — likely a conflict.")
            }
        }
        return failed
    }

    func stop() {
        for (_, ref) in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
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
                let firedId = firedID.id
                // Callback runs on the main run loop; hop to the main actor to run the
                // matching binding's action.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        manager.hotkeys.first { $0.id == firedId }?.action()
                    }
                }
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
        for (_, ref) in refs { UnregisterEventHotKey(ref) }
    }
}
