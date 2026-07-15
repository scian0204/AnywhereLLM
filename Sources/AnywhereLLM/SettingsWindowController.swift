import AppKit
import SwiftUI

/// Singleton settings window. Re-clicking "설정…" brings the existing window forward
/// instead of spawning a new one. Because the app is .accessory, we must explicitly
/// activate — otherwise the window opens behind whatever app is frontmost.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    /// Called when a hotkey change is saved, so AppDelegate can re-register it.
    var onHotkeyChanged: (() -> Void)?

    func show() {
        NSApp.activate(ignoringOtherApps: true)

        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = SettingsView(onHotkeyChanged: { [weak self] in self?.onHotkeyChanged?() })
        let hosting = NSHostingController(rootView: view)

        let win = NSWindow(contentViewController: hosting)
        win.title = L("settings.windowTitle")
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.isReleasedWhenClosed = false
        win.center()
        window = win

        win.makeKeyAndOrderFront(nil)
    }
}
