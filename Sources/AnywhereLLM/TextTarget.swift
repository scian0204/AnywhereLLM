import AppKit
import ApplicationServices

/// Snapshot of the focused text element captured at hotkey time.
struct TargetContext {
    let appName: String?        // 대상 앱 localizedName
    let bundleId: String?
    let selectedText: String?   // nil = 선택 없음 (또는 보안 필드)
    let fullText: String?       // 전체 필드 내용 (보안 필드면 nil)
    let isSecureField: Bool     // 하드 차단용
    let axElement: AXUIElement? // 쓰기 시 재사용
}

/// Read/write abstraction for the system-wide focused text element.
///
/// Reads prefer AX attributes and fall back to a clipboard-backed ⌘C when AX
/// returns nothing. Writes prefer AX `kAXSelectedTextAttribute` and fall back
/// to a clipboard-backed ⌘V. Secure fields (password inputs) are hard-blocked:
/// no text is ever captured and no clipboard fallback runs.
enum TextTargetService {

    // MARK: - Capture

    static func captureContext() -> TargetContext {
        let app = NSWorkspace.shared.frontmostApplication
        let appName = app?.localizedName
        let bundleId = app?.bundleIdentifier

        guard let element = focusedElement() else {
            return TargetContext(appName: appName, bundleId: bundleId,
                                 selectedText: nil, fullText: nil,
                                 isSecureField: false, axElement: nil)
        }

        let isSecure = isSecureField(element)
        if isSecure {
            // Hard rule: never read a secure field, never fall back to clipboard.
            return TargetContext(appName: appName, bundleId: bundleId,
                                 selectedText: nil, fullText: nil,
                                 isSecureField: true, axElement: element)
        }

        var selected = stringAttribute(element, kAXSelectedTextAttribute as CFString)
        let full = stringAttribute(element, kAXValueAttribute as CFString)

        // AX gave us nothing usable — try the clipboard ⌘C fallback for selection.
        if (selected == nil || selected?.isEmpty == true) && (full == nil || full?.isEmpty == true) {
            selected = clipboardCopyFallback()
        }

        return TargetContext(appName: appName, bundleId: bundleId,
                             selectedText: (selected?.isEmpty == true) ? nil : selected,
                             fullText: (full?.isEmpty == true) ? nil : full,
                             isSecureField: false, axElement: element)
    }

    // MARK: - Insert

    /// Insert `text` at the caret (replacing any selection) in the captured target.
    static func insert(_ text: String, into context: TargetContext) {
        guard !context.isSecureField else { return } // hard block

        // Try AX first: setting kAXSelectedTextAttribute replaces the selection
        // (or inserts at caret when empty) in apps that support it.
        if let element = context.axElement, setSelectedText(element, text) {
            return
        }

        // Fallback: clipboard-backed ⌘V.
        clipboardPasteFallback(text)
    }

    // MARK: - AX helpers

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value)
        guard err == .success, let value else { return nil }
        // AXUIElement is a CFType; force-cast is the documented pattern here.
        return (value as! AXUIElement)
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

    private static func setSelectedText(_ element: AXUIElement, _ text: String) -> Bool {
        let err = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
        return err == .success
    }

    // MARK: - Clipboard fallbacks

    /// Backs up the pasteboard, injects ⌘C, polls for a changeCount bump, reads
    /// the copied string, then restores the original pasteboard. Returns nil if
    /// nothing was copied within the timeout.
    private static func clipboardCopyFallback() -> String? {
        let pb = NSPasteboard.general
        let backup = backupPasteboard(pb)
        let before = pb.changeCount

        sendKey(0x08, command: true) // 'c'

        let copied = waitForChange(pb, from: before, timeout: 0.3) ? pb.string(forType: .string) : nil

        restorePasteboard(pb, items: backup)
        return copied
    }

    /// Backs up the pasteboard, writes `text`, injects ⌘V, waits briefly for the
    /// paste to land, then restores the original pasteboard.
    private static func clipboardPasteFallback(_ text: String) {
        let pb = NSPasteboard.general
        let backup = backupPasteboard(pb)

        pb.clearContents()
        pb.setString(text, forType: .string)

        sendKey(0x09, command: true) // 'v'

        // Give the target app time to consume the paste before we restore.
        Thread.sleep(forTimeInterval: 0.1)
        restorePasteboard(pb, items: backup)
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
