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

    /// 패널을 숨긴 뒤 대상 앱으로 key 포커스가 돌아오기까지 기다리는 시간.
    /// 삽입 확정(PromptPanel.apply)과 스트리밍 첫 타이핑(ConversationController)이 공유 —
    /// 두 곳에 흩어진 리터럴이 과거에 어긋난 적이 있어 한 상수로 묶는다.
    static let focusReturnDelay: TimeInterval = 0.15

    // MARK: - Capture

    static func captureContext() -> TargetContext {
        let app = NSWorkspace.shared.frontmostApplication
        let appName = app?.localizedName
        let bundleId = app?.bundleIdentifier

        guard let element = focusedElement(wakeIfNeeded: true) else {
            // 포커스 요소 없음 (AX 미노출 네이티브 — 카카오톡류). 앱 어딘가의 선택은
            // ⌘C로만 잡을 수 있다 — 나오면 위치를 모르는 선택 = 보기 전용.
            if let copied = clipboardCopyFallback(timeout: 0.15), !copied.isEmpty {
                NSLog("AnywhereLLM capture: app=%@ no focused element → ⌘C hit (len %d) → view-only",
                      bundleId ?? "nil", copied.count)
                return TargetContext(appName: appName, bundleId: bundleId,
                                     selectedText: copied, fullText: nil,
                                     isSecureField: false, isEditable: false,
                                     axElement: nil)
            }
            // 불명 = 편집 가능: CGEvent 타이핑 쓰기는 AX가 불필요해 기존 흐름이
            // 그대로 동작한다. false로 두면 그 앱들의 삽입이 전면 회귀한다.
            NSLog("AnywhereLLM capture: app=%@ no focused element, ⌘C empty → editable insert",
                  bundleId ?? "nil")
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
        NSLog("AnywhereLLM capture: app=%@ role=%@ selLen=%d rangeLen=%d fullLen=%@",
              bundleId ?? "nil",
              stringAttribute(element, kAXRoleAttribute as CFString) ?? "nil",
              selected?.count ?? -1, selectedRangeLength(element),
              full.map { String($0.count) } ?? "nil")

        if selected == nil || selected?.isEmpty == true {
            if selectedRangeLength(element) > 0 {
                // 요소 안에 선택은 있는데 selectedText 속성이 비는 앱
                // (웹뷰/Electron 일부) → ⌘C 클립보드 폴백.
                selected = clipboardCopyFallback()
                NSLog("AnywhereLLM capture: range>0 → ⌘C (len %d)", selected?.count ?? -1)
            } else if let webArea = webAreaAncestor(of: element) {
                // 웹 계열: 문서 선택은 웹 영역이 권위. Slack류 메신저는 채팅
                // 텍스트를 선택해도 컴포저가 포커스를 쥔다 (실측: progress/20) —
                // 선택이 포커스 요소 밖 = 삽입 대상 아님 → 보기 전용 컨텍스트.
                // axElement는 웹 영역: 패널 앵커(선택 위치 텍스트마커 bounds)용.
                // 웹 영역이 "선택 없음"이어도 끝이 아니다 — 메타데이터 판별 ⌘C
                // 프로브(아래)만 허용. 결과 문자열을 무조건 채택하는 ⌘C는 여전히
                // 금지 — 줄 복사 에디터(VS Code 등)의 빈 선택 오탐이 부활한다.
                let webSelection = stringAttribute(webArea, kAXSelectedTextAttribute as CFString)
                NSLog("AnywhereLLM capture: webArea found, webSelLen=%@",
                      webSelection.map { String($0.count) } ?? "nil")
                if let webSelection, !webSelection.isEmpty {
                    return TargetContext(appName: appName, bundleId: bundleId,
                                         selectedText: webSelection, fullText: nil,
                                         isSecureField: false, isEditable: false,
                                         axElement: webArea)
                }
                // Monaco류(VS Code 등): 에디터 선택이 AX 어디에도 안 나온다 — 히든
                // textarea는 selLen=0·rangeLen=0, 웹 영역 selectedText도 nil (실측:
                // progress/30). 유일한 신호가 ⌘C인데 빈 선택 ⌘C = 줄 복사라 결과
                // 문자열만으론 구분 불가 → 클립보드 메타데이터(isFromEmptySelection)가
                // "진짜 선택"을 확정할 때만 채택. 메타데이터 없는 웹 앱은 전부 폐기 —
                // 줄 복사 오탐 차단(progress/21)은 그대로 유지된다.
                selected = clipboardCopyFallback(timeout: 0.15, requireWebEditorSelectionMetadata: true)
                NSLog("AnywhereLLM capture: web editor metadata probe (len %d)", selected?.count ?? -1)
            } else if full == nil {
                // AX가 아예 침묵(full도 없음)하는 앱 → ⌘C 폴백, 요소 소속 선택으로
                // 간주 (레거시 — 이런 앱은 요소 상태를 알 길이 없다).
                selected = clipboardCopyFallback()
                NSLog("AnywhereLLM capture: AX silent → ⌘C (len %d)", selected?.count ?? -1)
            } else if let copied = clipboardCopyFallback(timeout: 0.15), !copied.isEmpty,
                      full?.contains(copied) != true {
                // 네이티브: 요소는 "선택 없음"(범위 0)이라는데 ⌘C로 텍스트가 나왔고
                // 요소 자기 내용의 일부도 아님(빈 선택에 현재 줄을 복사하는 에디터
                // 오탐 배제) → 앱 내 다른 곳의 선택 = 보기 전용. 위치를 모르므로
                // 앵커는 nil(마우스 폴백 — 선택 직후라 선택 근처).
                NSLog("AnywhereLLM capture: native speculative ⌘C hit (len %d) → view-only", copied.count)
                return TargetContext(appName: appName, bundleId: bundleId,
                                     selectedText: copied, fullText: nil,
                                     isSecureField: false, isEditable: false,
                                     axElement: nil)
            } else {
                NSLog("AnywhereLLM capture: native, speculative ⌘C empty/phantom → insert context")
            }
        }

        let editable = isEditableElement(element, hasSelection: selected?.isEmpty == false)
        logElementDiagnostics(element)
        NSLog("AnywhereLLM capture: default return editable=%d selPresent=%d",
              editable ? 1 : 0, (selected?.isEmpty == false) ? 1 : 0)
        return TargetContext(appName: appName, bundleId: bundleId,
                             selectedText: (selected?.isEmpty == true) ? nil : selected,
                             fullText: (full?.isEmpty == true) ? nil : full,
                             isSecureField: false, isEditable: editable,
                             axElement: element)
    }

    // MARK: - Insert

    /// Insert `text` at the caret (replacing any selection) in the captured target.
    static func insert(_ text: String, into context: TargetContext) {
        guard !context.isSecureField else { return } // hard block

        // Try AX first: setting kAXSelectedTextAttribute replaces the selection
        // (or inserts at caret when empty) in apps that support it.
        // 하드 룰: 캡처 후 패널이 열린 사이 요소가 보안 필드로 바뀌었을 수 있다 —
        // AX 쓰기 직전 재확인(typeText와 대칭). 재확인 실패면 typeText로 떨어져
        // 거기서 다시 확인한다.
        if let element = context.axElement, !isSecureField(element),
           setSelectedTextVerified(element, text) {
            return
        }

        // AX 실패 또는 무시(Chromium은 success를 반환하고 조용히 무시 — 실측:
        // docs/progress/18). 이때 대상의 선택은 그대로 살아 있으므로 유니코드
        // 타이핑이 선택을 자연스럽게 대체한다. 삽입 모드에서 검증된 경로와 동일.
        typeText(text, expectedBundleId: context.bundleId)
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
    ///
    /// 예외 — `hasSelection`: 읽기 전용 메시지 뷰(Slack 메시지 AXGroup, 카카오톡
    /// 버블 AXTextArea — 실측 progress/22)도 포커스를 갖고 선택을 직접 들고 있다.
    /// 요소가 선택을 들고 있는데 value·selectedText 둘 다 "확정적으로"(.success +
    /// false) 쓰기 불가면 읽기 전용 뷰 = false. 편집 필드는 전부 settable YES를
    /// 반환하므로(카카오톡 입력칸·Slack 컴포저 실측) 교체 흐름 회귀 없음.
    /// AX 오류·불명은 여전히 true (기본 방향 유지).
    private static func isEditableElement(_ element: AXUIElement, hasSelection: Bool) -> Bool {
        var settable = DarwinBoolean(false)
        let valueErr = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        if valueErr == .success, settable.boolValue {
            return true
        }
        let selTextErr = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        if selTextErr == .success, settable.boolValue {
            return true
        }
        if hasSelection, valueErr == .success, selTextErr == .success {
            return false
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

    /// 캡처 진단 로그: 편집 가능성 판정 신호 덤프 (통합 로그, 텍스트 내용 무기록).
    /// GUI 동작은 자동 검증이 불가능해 미지의 앱에서 오판이 나오면 이 로그가 유일한
    /// 단서다 — `log show --predicate 'process == "AnywhereLLM"'` (실측: progress/22).
    private static func logElementDiagnostics(_ element: AXUIElement) {
        func settableStr(_ attr: CFString) -> String {
            var s = DarwinBoolean(false)
            let err = AXUIElementIsAttributeSettable(element, attr, &s)
            return err == .success ? (s.boolValue ? "YES" : "no") : "err\(err.rawValue)"
        }
        var names: CFArray?
        var extras = "-"
        if AXUIElementCopyAttributeNames(element, &names) == .success, let list = names as? [String] {
            let hits = list.filter { $0.contains("Edit") || $0 == "AXEnabled" || $0.contains("Focus") }
            if !hits.isEmpty { extras = hits.joined(separator: ",") }
        }
        var chain: [String] = []
        var current = element
        for _ in 0..<6 {
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let parent else { break }
            current = parent as! AXUIElement
            chain.append(stringAttribute(current, kAXRoleAttribute as CFString) ?? "?")
        }
        NSLog("AnywhereLLM diag: subrole=%@ settable(value=%@ selText=%@ selRange=%@) attrs=%@ parents=%@",
              stringAttribute(element, kAXSubroleAttribute as CFString) ?? "-",
              settableStr(kAXValueAttribute as CFString),
              settableStr(kAXSelectedTextAttribute as CFString),
              settableStr(kAXSelectedTextRangeAttribute as CFString),
              extras, chain.joined(separator: ">"))
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
    ///
    /// `requireWebEditorSelectionMetadata`: Chromium 웹 에디터의 클립보드 메타데이터
    /// (web-custom-data 안 vscode-editor-data JSON, UTF-16LE)가 "빈 선택 아님"을
    /// 확정할 때만 결과를 반환. VS Code류는 빈 선택 ⌘C가 현재 줄을 복사하므로
    /// (isFromEmptySelection=true) 이 판별자 없이는 진짜 선택과 구분할 수 없다.
    private static func clipboardCopyFallback(timeout: TimeInterval = 0.3,
                                              requireWebEditorSelectionMetadata: Bool = false) -> String? {
        let pb = NSPasteboard.general
        let backup = backupPasteboard(pb)
        let before = pb.changeCount

        sendKey(0x08, command: true) // 'c'

        var copied = waitForChange(pb, from: before, timeout: timeout) ? pb.string(forType: .string) : nil

        if requireWebEditorSelectionMetadata, copied != nil {
            // 주의: 이 메타데이터는 웹 콘텐츠가 쓰는 값이라 신뢰 수준은 "VS Code류의
            // 자기 신고"다 — 악의적 페이지는 위조 가능하지만, 채택된 텍스트는 패널에
            // 그대로 보이고 자동 적용되지 않으므로 영향은 컨텍스트 오염에 그친다.
            // ponytail: 메타데이터가 없거나 형식이 바뀌면 미탐(폐기) — 오탐(줄 복사를
            // 선택으로 승격)보다 안전한 방향. Docs/CodeMirror류 미지원, 사례 나오면 판별자 추가.
            if !pasteboardHasWebEditorMetadata(pb, needle: "isFromEmptySelection\":false") {
                copied = nil
            }
        }

        // 클립보드가 안 변했으면(⌘C 무반응) 복원도 불필요 — 복원 자체가 changeCount를
        // 올려 클립보드 매니저에 중복 항목을 남기고 promise 데이터를 강제 해소시킨다.
        if pb.changeCount != before {
            restorePasteboard(pb, items: backup)
        }
        // 레이스: 대상 앱이 타임아웃 뒤 늦게 ⌘C를 처리하면(Electron 등 메인 스레드가
        // >150ms 멈추는 앱) 방금 복원했거나 손대지 않은 클립보드를 프로브 결과가
        // 덮어 사용자 원본(패스워드 등)이 영구 유실된다. 프로브 발사 뒤 짧은 창을 두고,
        // 그 사이 클립보드가 바뀌면 한 번 더 복원한다. 핫키 직후 ~0.4s 내 변경은
        // 사실상 이 늦은 복사뿐이라 사용자의 정상 복사를 되돌릴 위험은 낮다.
        // (기존 메타데이터-전용 늦은복원을 모든 프로브 경로로 일반화.)
        let settled = pb.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if pb.changeCount != settled { restorePasteboard(pb, items: backup) }
        }
        return copied
    }

    /// `org.chromium.web-custom-data` blob(UTF-16LE) 안에 needle이 있는지.
    private static func pasteboardHasWebEditorMetadata(_ pb: NSPasteboard, needle: String) -> Bool {
        guard let blob = pb.data(forType: NSPasteboard.PasteboardType("org.chromium.web-custom-data")),
              let bytes = needle.data(using: .utf16LittleEndian) else { return false }
        return blob.range(of: bytes) != nil
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
    ///
    /// `expectedBundleId`: 캡처 시점의 대상 앱. frontmost가 이것과 다르면 사용자가
    /// 도중에 다른 앱으로 전환한 것 — 아무 것도 타이핑하지 않는다. 스트리밍은 매
    /// flush마다 이 검사를 거치므로 전환 즉시 멈춘다. (보안 필드 재확인은 AX가
    /// 침묵하는 앱에선 무력하므로, 이 앱-단위 가드가 오삽입의 1차 방어선이다.)
    static func typeText(_ text: String, expectedBundleId: String? = nil) {
        guard !text.isEmpty else { return }
        // 대상 앱이 여전히 frontmost인지 확인 — 아니면 엉뚱한 앱에 타이핑된다
        // (long 스트림 중 앱 전환, 비활성 패널 위에서 다른 앱 클릭 후 apply 등).
        if let expectedBundleId,
           NSWorkspace.shared.frontmostApplication?.bundleIdentifier != expectedBundleId {
            return
        }
        // 하드 룰: 캡처 이후 포커스가 보안 필드로 옮겨졌을 수 있다 — 타이핑 직전 재확인,
        // 보안 필드면 무조건 드롭 (설정으로 풀 수 없음).
        if let focused = focusedElement(), isSecureField(focused) { return }
        // ponytail: 20 UTF-16 units/event is a safe chunk; CGEventKeyboardSetUnicodeString
        // truncates very long strings. Bump if a target drops characters.
        let units = Array(text.utf16)
        let source = CGEventSource(stateID: .privateState)
        var start = 0
        while start < units.count {
            var end = min(start + 20, units.count)
            // 청크가 상위 서로게이트로 끝나면 짝(하위 서로게이트)이 다음 청크로 밀려
            // 두 이벤트 모두 깨진 UTF-16을 실어 이모지가 U+FFFD로 망가진다 — 경계를
            // 한 칸 당겨 서로게이트 쌍이 한 이벤트 안에 남게 한다.
            if end < units.count, (0xD800...0xDBFF).contains(units[end - 1]) {
                end -= 1
            }
            var slice = Array(units[start..<end])
            start = end
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
