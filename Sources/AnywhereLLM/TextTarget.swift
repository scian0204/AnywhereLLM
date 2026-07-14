import AppKit
import ApplicationServices

/// Snapshot of the focused text element captured at hotkey time.
struct TargetContext {
    let appName: String?        // 대상 앱 localizedName
    let bundleId: String?
    let selectedText: String?   // nil = 선택 없음 (또는 보안 필드)
    let fullText: String?       // 전체 필드 내용 (보안 필드면 nil)
    let isSecureField: Bool     // 하드 차단용
    let isEditable: Bool        // false = 결과 삽입 불가 대상 — 보기 전용 흐름
    let axElement: AXUIElement? // 쓰기 시 재사용
}

/// Read/write abstraction for the system-wide focused text element.
///
/// Reads prefer AX attributes and fall back to a clipboard-backed ⌘C when AX
/// returns nothing. Writes prefer AX `kAXSelectedTextAttribute` (반영 검증 포함)
/// and fall back to Unicode key-event typing, which replaces the live selection.
/// Secure fields (password inputs) are hard-blocked: no text is ever captured
/// and no clipboard fallback runs.
enum TextTargetService {

    // MARK: - Capture

    static func captureContext() -> TargetContext {
        let app = NSWorkspace.shared.frontmostApplication
        let appName = app?.localizedName
        let bundleId = app?.bundleIdentifier

        guard let element = focusedElement(wakeIfNeeded: true) else {
            // 포커스 요소 없음 (AX 미노출 네이티브 — 카카오톡류). 앱 어딘가의 선택은
            // ⌘C로만 잡을 수 있다 — 나오면 위치를 모르는 선택 = 보기 전용.
            if let copied = clipboardCopyFallback(timeout: 0.15), !copied.isEmpty {
                return TargetContext(appName: appName, bundleId: bundleId,
                                     selectedText: copied, fullText: nil,
                                     isSecureField: false, isEditable: false,
                                     axElement: nil)
            }
            // 불명 = 편집 가능: CGEvent 타이핑 쓰기는 AX가 불필요해 기존 흐름이
            // 그대로 동작한다. false로 두면 그 앱들의 삽입이 전면 회귀한다.
            return TargetContext(appName: appName, bundleId: bundleId,
                                 selectedText: nil, fullText: nil,
                                 isSecureField: false, isEditable: true, axElement: nil)
        }

        let isSecure = isSecureField(element)
        if isSecure {
            // Hard rule: never read a secure field, never fall back to clipboard.
            return TargetContext(appName: appName, bundleId: bundleId,
                                 selectedText: nil, fullText: nil,
                                 isSecureField: true, isEditable: true, axElement: element)
        }

        var selected = stringAttribute(element, kAXSelectedTextAttribute as CFString)
        let full = stringAttribute(element, kAXValueAttribute as CFString)

        if selected == nil || selected?.isEmpty == true {
            if selectedRangeLength(element) > 0 {
                // 요소 안에 선택은 있는데 selectedText 속성이 비는 앱
                // (웹뷰/Electron 일부) → ⌘C 클립보드 폴백.
                selected = clipboardCopyFallback()
            } else if let webArea = webAreaAncestor(of: element) {
                // 웹 계열: 문서 선택은 웹 영역이 권위. Slack류 메신저는 채팅
                // 텍스트를 선택해도 컴포저가 포커스를 쥔다 (실측: progress/20) —
                // 선택이 포커스 요소 밖 = 삽입 대상 아님 → 보기 전용 컨텍스트.
                // axElement는 웹 영역: 패널 앵커(선택 위치 텍스트마커 bounds)용.
                // 웹 영역이 "선택 없음"이면 그대로 믿는다 — 여기서 ⌘C를 쏘면
                // 줄 복사 에디터(VS Code 등)의 빈 선택 오탐이 부활한다.
                if let webSelection = stringAttribute(webArea, kAXSelectedTextAttribute as CFString),
                   !webSelection.isEmpty {
                    return TargetContext(appName: appName, bundleId: bundleId,
                                         selectedText: webSelection, fullText: nil,
                                         isSecureField: false, isEditable: false,
                                         axElement: webArea)
                }
            } else if full == nil {
                // AX가 아예 침묵(full도 없음)하는 앱 → ⌘C 폴백, 요소 소속 선택으로
                // 간주 (레거시 — 이런 앱은 요소 상태를 알 길이 없다).
                selected = clipboardCopyFallback()
            } else if let copied = clipboardCopyFallback(timeout: 0.15), !copied.isEmpty,
                      full?.contains(copied) != true {
                // 네이티브: 요소는 "선택 없음"(범위 0)이라는데 ⌘C로 텍스트가 나왔고
                // 요소 자기 내용의 일부도 아님(빈 선택에 현재 줄을 복사하는 에디터
                // 오탐 배제) → 앱 내 다른 곳의 선택 = 보기 전용. 위치를 모르므로
                // 앵커는 nil(마우스 폴백 — 선택 직후라 선택 근처).
                return TargetContext(appName: appName, bundleId: bundleId,
                                     selectedText: copied, fullText: nil,
                                     isSecureField: false, isEditable: false,
                                     axElement: nil)
            }
        }

        return TargetContext(appName: appName, bundleId: bundleId,
                             selectedText: (selected?.isEmpty == true) ? nil : selected,
                             fullText: (full?.isEmpty == true) ? nil : full,
                             isSecureField: false, isEditable: isEditableElement(element),
                             axElement: element)
    }

    // MARK: - Insert

    /// Insert `text` at the caret (replacing any selection) in the captured target.
    static func insert(_ text: String, into context: TargetContext) {
        guard !context.isSecureField else { return } // hard block

        // Try AX first: setting kAXSelectedTextAttribute replaces the selection
        // (or inserts at caret when empty) in apps that support it.
        if let element = context.axElement, setSelectedTextVerified(element, text) {
            return
        }

        // AX 실패 또는 무시(Chromium은 success를 반환하고 조용히 무시 — 실측:
        // docs/progress/18). 이때 대상의 선택은 그대로 살아 있으므로 유니코드
        // 타이핑이 선택을 자연스럽게 대체한다. 삽입 모드에서 검증된 경로와 동일.
        typeText(text)
    }

    // MARK: - AX helpers

    /// 포커스 요소 조회. systemwide 질의는 Chrome에서 트리 상태와 무관하게 항상
    /// -25204로 실패한다 (실측: docs/progress/18) — frontmost 앱 요소 경유로 재시도.
    /// `wakeIfNeeded`: Chromium 웹 콘텐츠 AX 트리는 클라이언트 질의를 감지해야
    /// 생성된다. AXWindows 질의가 생성 트리거(~250ms 내 하이드레이션, 실측),
    /// Electron은 AXManualAccessibility. 재시도 대기(최대 ~300ms)가 있으므로
    /// 핫키 캡처 경로에서만 켠다 — 스트리밍 중 보안 필드 재확인은 false.
    private static func focusedElement(wakeIfNeeded: Bool = false) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
           let value {
            // AXUIElement is a CFType; force-cast is the documented pattern here.
            return (value as! AXUIElement)
        }

        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
           let focused {
            return (focused as! AXUIElement)
        }

        guard wakeIfNeeded else { return nil }
        var windows: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windows)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        for _ in 0..<3 {
            Thread.sleep(forTimeInterval: 0.1)
            var retried: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &retried) == .success,
               let retried {
                return (retried as! AXUIElement)
            }
        }
        return nil
    }

    private static func stringAttribute(_ element: AXUIElement, _ attr: CFString) -> String? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attr, &value)
        guard err == .success else { return nil }
        return value as? String
    }

    private static func isSecureField(_ element: AXUIElement) -> Bool {
        guard let subrole = stringAttribute(element, kAXSubroleAttribute as CFString) else { return false }
        return subrole == (kAXSecureTextFieldSubrole as String)
    }

    /// 포커스 요소가 텍스트 "입력" 대상인지. 웹페이지 본문/PDF/파인더처럼 편집 불가면
    /// 삽입·교체 흐름 대신 보기 전용(패널에 결과 유지) 흐름을 태운다.
    ///
    /// 판정 원칙 = 거부 목록: 오탐(편집 가능 오판)은 기존 동작과 동일해 무해하지만
    /// 미탐(편집 필드를 보기 전용 오판)은 삽입 기능 회귀라 치명적 — 그래서
    /// "확실히 편집 불가"(콘텐츠 표시 전용 role + settable 아님)일 때만 false,
    /// 불명·AX 오류는 전부 true. settable 검사를 role보다 먼저 해 contenteditable
    /// AXWebArea(웹 리치 에디터)가 거부 목록에 걸리지 않게 한다.
    private static func isEditableElement(_ element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return true
        }
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return true
        }
        // 콘텐츠 표시 전용 role — 웹 본문/정적 텍스트/이미지/PDF 스크롤 영역/목록류.
        let viewOnlyRoles: Set<String> = [
            "AXWebArea", // WebKit/Chromium 문서 본문 (공개 kAX 상수 없음)
            kAXStaticTextRole as String,
            kAXImageRole as String,
            kAXScrollAreaRole as String,
            kAXListRole as String,
            kAXOutlineRole as String,
            kAXTableRole as String,
            kAXBrowserRole as String,
        ]
        if let role = stringAttribute(element, kAXRoleAttribute as CFString),
           viewOnlyRoles.contains(role) {
            return false
        }
        return true
    }

    /// 조상 중 웹 영역(AXWebArea). 웹 계열 앱은 포커스가 입력칸에 있어도 문서
    /// 다른 곳의 선택을 웹 영역이 들고 있다 (Chrome 실측: 본문 선택을 selectedText로
    /// 노출). Slack 실측: 컴포저 → 웹 영역 15홉이라 여유 있게 25홉까지.
    private static func webAreaAncestor(of element: AXUIElement) -> AXUIElement? {
        var current = element
        for _ in 0..<25 {
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let parent else { return nil }
            let ancestor = parent as! AXUIElement
            let role = stringAttribute(ancestor, kAXRoleAttribute as CFString)
            if role == "AXWebArea" { return ancestor }
            if role == (kAXWindowRole as String) || role == (kAXApplicationRole as String) {
                return nil // 네이티브 계층 도달 — 웹 영역 없음
            }
            current = ancestor
        }
        return nil
    }

    /// kAXSelectedTextRangeAttribute의 선택 길이. 속성 미지원/오류면 0.
    private static func selectedRangeLength(_ element: AXUIElement) -> Int {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return 0 }
        var range = CFRange()
        guard AXValueGetValue((value as! AXValue), .cfRange, &range) else { return 0 }
        return range.length
    }

    /// kAXSelectedTextAttribute 쓰기 + 실제 반영 검증. Chromium은 무시하면서도
    /// .success를 반환하므로 성공 코드를 믿을 수 없다 — value/selectedText가
    /// 실제로 변했을 때만 true. 검증 불능(둘 다 못 읽음)도 미적용으로 취급해
    /// 폴백을 태운다.
    private static func setSelectedTextVerified(_ element: AXUIElement, _ text: String) -> Bool {
        let valueBefore = stringAttribute(element, kAXValueAttribute as CFString)
        let selectionBefore = stringAttribute(element, kAXSelectedTextAttribute as CFString)
        let err = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
        guard err == .success else { return false }
        // 일부 앱은 반영이 비동기 — 짧게 기다렸다 재확인 (미적용 오판 시 이중 입력 위험).
        Thread.sleep(forTimeInterval: 0.05)
        if valueBefore != stringAttribute(element, kAXValueAttribute as CFString) { return true }
        if selectionBefore != stringAttribute(element, kAXSelectedTextAttribute as CFString) { return true }
        return false
    }

    // MARK: - Clipboard fallbacks

    /// Backs up the pasteboard, injects ⌘C, polls for a changeCount bump, reads
    /// the copied string, then restores the original pasteboard. Returns nil if
    /// nothing was copied within the timeout. 투기적 프로브(선택이 없을 확률이
    /// 높은 경로)는 짧은 timeout으로 핫키 지연을 줄인다.
    private static func clipboardCopyFallback(timeout: TimeInterval = 0.3) -> String? {
        let pb = NSPasteboard.general
        let backup = backupPasteboard(pb)
        let before = pb.changeCount

        sendKey(0x08, command: true) // 'c'

        let copied = waitForChange(pb, from: before, timeout: timeout) ? pb.string(forType: .string) : nil

        restorePasteboard(pb, items: backup)
        return copied
    }

    private static func waitForChange(_ pb: NSPasteboard, from before: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pb.changeCount != before { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return pb.changeCount != before
    }

    /// Snapshot every type on every pasteboard item so restore is lossless.
    private static func backupPasteboard(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var typed: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { typed[type] = data }
            }
            return typed
        }
    }

    private static func restorePasteboard(_ pb: NSPasteboard, items backup: [[NSPasteboard.PasteboardType: Data]]) {
        pb.clearContents()
        guard !backup.isEmpty else { return }
        let newItems = backup.map { typed -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in typed { item.setData(data, forType: type) }
            return item
        }
        pb.writeObjects(newItems)
    }

    // MARK: - Unicode typing (real-time streaming insert)

    /// Type `text` into the focused element as synthetic Unicode key events —
    /// no clipboard, no AX. Used for streaming insert so chunks land as they arrive.
    /// 주의: 합성 키 이벤트는 시스템의 key window로 간다. 패널이 key인 채로 부르면
    /// 패널이 이벤트를 먹는다 — 호출 전에 패널을 숨겨 대상 앱에 key를 돌려줄 것.
    static func typeText(_ text: String) {
        guard !text.isEmpty else { return }
        // 하드 룰: 캡처 이후 포커스가 보안 필드로 옮겨졌을 수 있다 — 타이핑 직전 재확인,
        // 보안 필드면 무조건 드롭 (설정으로 풀 수 없음).
        if let focused = focusedElement(), isSecureField(focused) { return }
        // ponytail: 20 UTF-16 units/event is a safe chunk; CGEventKeyboardSetUnicodeString
        // truncates very long strings. Bump if a target drops characters.
        let units = Array(text.utf16)
        let source = CGEventSource(stateID: .privateState)
        for start in stride(from: 0, to: units.count, by: 20) {
            var slice = Array(units[start..<min(start + 20, units.count)])
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { continue }
            down.keyboardSetUnicodeString(stringLength: slice.count, unicodeString: &slice)
            up.keyboardSetUnicodeString(stringLength: slice.count, unicodeString: &slice)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    // MARK: - CGEvent injection

    /// Post a ⌘+<key> keystroke. Uses a private (non-HID) event source so the
    /// synthetic event doesn't re-trigger our own global hotkey tap.
    private static func sendKey(_ keyCode: CGKeyCode, command: Bool) {
        // ponytail: .privateState source keeps injected events off the HID stream our hotkey listens on
        let source = CGEventSource(stateID: .privateState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        if command {
            down?.flags = .maskCommand
            up?.flags = .maskCommand
        }
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
