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
    static func origin(for size: NSSize) -> NSPoint {
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
            anchor = caretAnchorRect() ?? NSRect(origin: NSEvent.mouseLocation, size: .zero)
        }

        // Place the panel just below the anchor's bottom-left.
        var origin = NSPoint(x: anchor.minX, y: anchor.minY - size.height - 4)
        clamp(&origin, size: size)
        return origin
    }

    // MARK: - Caret / focus geometry (AX, converted to Cocoa coords)

    /// Cocoa-coordinate rect for the caret, or the focused element, or nil.
    private static func caretAnchorRect() -> NSRect? {
        guard let element = focusedElement() else { return nil }

        if let caret = caretRect(of: element) {
            return caret
        }
        // Fall back to the focused element's frame.
        // "AXFrame" is not exported as a Swift constant; use the raw attribute name.
        if let frame = axRect(element, "AXFrame" as CFString) {
            return cocoaRect(fromAXTopLeft: frame)
        }
        return nil
    }

    /// The system-wide focused UI element.
    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let value = focused
        else { return nil }
        // AXUIElement is a CFType; this cast is safe when the attribute succeeds.
        return (value as! AXUIElement)
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
        guard rect.width.isFinite, rect.height.isFinite, !rect.isNull else { return nil }
        return cocoaRect(fromAXTopLeft: rect)
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
