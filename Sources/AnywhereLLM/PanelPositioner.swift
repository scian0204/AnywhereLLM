import AppKit
import ApplicationServices

/// Decides where the prompt panel appears. Setting "panelPosition" in UserDefaults:
///   "caret" (default) — track the text caret, falling back to focused-element bounds,
///                        then the mouse.
///   "mouse"           — at the mouse pointer.
///   "center"          — centered on the screen under the mouse.
///
/// Coordinate note: AX geometry is top-left origin (y grows downward, primary
/// screen's top). NSScreen/NSWindow are bottom-left origin. Everything below
/// converts AX rects into Cocoa coordinates before positioning.
@MainActor
enum PanelPositioner {
    /// Origin (bottom-left, Cocoa coords) to place a panel of `size`.
    /// `element`: captureContext가 얻은 포커스 요소. 여기서 재질의하지 않는 이유 —
    /// systemwide 질의는 Chrome에서 항상 실패해(progress/18) 캡처와 다른 결과가
    /// 나올 수 있다. 캡처된 요소를 그대로 앵커로 쓰면 선택 텍스트(보기 전용 포함)
    /// 위치에 정확히 붙는다.
    static func origin(for size: NSSize, anchor element: AXUIElement?) -> NSPoint {
        let mode = UserDefaults.standard.string(forKey: "panelPosition") ?? "caret"

        let anchor: NSRect
        switch mode {
        case "mouse":
            anchor = NSRect(origin: NSEvent.mouseLocation, size: .zero)
        case "center":
            let screen = screenForMouse()
            return NSPoint(
                x: screen.frame.midX - size.width / 2,
                y: screen.frame.midY - size.height / 2
            )
        default: // "caret"
            anchor = caretAnchorRect(of: element) ?? NSRect(origin: NSEvent.mouseLocation, size: .zero)
        }

        // Place the panel just below the anchor's bottom-left.
        var origin = NSPoint(x: anchor.minX, y: anchor.minY - size.height - 4)
        clamp(&origin, size: size)
        return origin
    }

    // MARK: - Caret / focus geometry (AX, converted to Cocoa coords)

    /// Cocoa-coordinate rect for the caret/selection, or the focused element, or nil.
    private static func caretAnchorRect(of element: AXUIElement?) -> NSRect? {
        guard let element else { return nil }

        if let caret = caretRect(of: element) {
            return caret
        }
        // 웹 영역(Chromium)은 classic BoundsForRange가 제로 rect라 텍스트마커로.
        if let marker = markerSelectionRect(of: element) {
            return marker
        }
        // Fall back to the focused element's frame — 단, 필드 크기일 때만.
        // 보기 전용 컨테이너(AXWebArea 등)의 frame은 뷰포트 전체라 앵커로 부적합 —
        // 그땐 nil을 돌려 마우스(선택 끝 지점 근처) 폴백을 태운다.
        // "AXFrame" is not exported as a Swift constant; use the raw attribute name.
        if let frame = axRect(element, "AXFrame" as CFString), frame.height <= 300 {
            return cocoaRect(fromAXTopLeft: frame)
        }
        return nil
    }

    /// Caret bounds via kAXBoundsForRangeParameterizedAttribute at the selection start.
    private static func caretRect(of element: AXUIElement) -> NSRect? {
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue
        else { return nil }

        var range = CFRange()
        guard AXValueGetValue((rangeValue as! AXValue), .cfRange, &range) else { return nil }
        // Collapse to a 1-char range at the caret so bounds are non-empty.
        var caretRange = CFRange(location: range.location, length: max(range.length, 1))
        guard let caretRangeValue = AXValueCreate(.cfRange, &caretRange) else { return nil }

        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, caretRangeValue, &boundsValue
        ) == .success, let boundsValue else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue((boundsValue as! AXValue), .cgRect, &rect) else { return nil }
        guard validAnchorRect(rect) else { return nil }
        return cocoaRect(fromAXTopLeft: rect)
    }

    /// 선택 텍스트 bounds — WebKit/Chromium 텍스트마커 API (VoiceOver가 쓰는 경로).
    /// Chromium 웹 영역은 classic BoundsForRange에 err 0 + 제로 크기 rect를
    /// 반환하므로(실측: docs/progress/19) 이 폴백이 실제 선택 위치를 준다.
    private static func markerSelectionRect(of element: AXUIElement) -> NSRect? {
        var markerRange: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, "AXSelectedTextMarkerRange" as CFString, &markerRange
        ) == .success, let markerRange else { return nil }

        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, "AXBoundsForTextMarkerRange" as CFString, markerRange, &boundsValue
        ) == .success, let boundsValue, CFGetTypeID(boundsValue) == AXValueGetTypeID() else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue((boundsValue as! AXValue), .cgRect, &rect),
              validAnchorRect(rect) else { return nil }
        return cocoaRect(fromAXTopLeft: rect)
    }

    /// Chromium은 미지원 범위에 성공 코드 + (0,y,0,0) 쓰레기 rect를 반환한다 —
    /// 제로 크기는 앵커로 쓰지 않는다 (순수 캐럿은 width 0이어도 height > 0).
    private static func validAnchorRect(_ rect: CGRect) -> Bool {
        rect.width.isFinite && rect.height.isFinite && !rect.isNull
            && (rect.width > 0 || rect.height > 0)
    }

    private static func axRect(_ element: AXUIElement, _ attribute: CFString) -> CGRect? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success, let value else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue((value as! AXValue), .cgRect, &rect) else { return nil }
        return rect
    }

    // MARK: - Coordinate conversion & clamping

    /// Convert an AX rect (top-left origin, primary-screen top) to Cocoa (bottom-left origin).
    private static func cocoaRect(fromAXTopLeft rect: CGRect) -> NSRect {
        // Primary screen height defines the flip axis for the global AX coordinate space.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let flippedY = primaryHeight - rect.origin.y - rect.height
        return NSRect(x: rect.origin.x, y: flippedY, width: rect.width, height: rect.height)
    }

    private static func screenForMouse() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    /// Keep the panel fully on the screen it lands on (visibleFrame excludes menu bar/Dock).
    private static func clamp(_ origin: inout NSPoint, size: NSSize) {
        let rect = NSRect(origin: origin, size: size)
        let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? screenForMouse()
        let bounds = screen.visibleFrame

        origin.x = min(max(origin.x, bounds.minX), bounds.maxX - size.width)
        origin.y = min(max(origin.y, bounds.minY), bounds.maxY - size.height)
    }
}
