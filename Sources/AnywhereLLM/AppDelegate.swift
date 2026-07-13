import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var accessibilityTimer: Timer?
    private var hasAccessibility = false

    private var hotkeyManager: HotkeyManager?
    private var promptPanel: PromptPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "bubble.left.and.text.bubble.right",
            accessibilityDescription: "AnywhereLLM"
        )

        requestAccessibility(prompt: true)
        rebuildMenu()

        let hotkey = HotkeyManager { [weak self] in self?.togglePanel() }
        hotkey.start()
        hotkeyManager = hotkey

        // ponytail: 5s poll instead of AX notification observer; simplest way to refresh grant state
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccessibility() }
        }
    }

    // MARK: - Prompt panel

    /// Toggle the non-activating panel: show + position + focus, or hide if already visible.
    private func togglePanel() {
        let panel = promptPanel ?? {
            let p = PromptPanel()
            promptPanel = p
            return p
        }()

        if panel.isVisible {
            panel.orderOut(nil)
            return
        }

        // Position must be computed against the CURRENT focus, before we show the panel.
        panel.setFrameOrigin(PanelPositioner.origin(for: panel.frame.size))
        // orderFrontRegardless shows without activating the app.
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.focusInput()
    }

    // MARK: - Accessibility

    @discardableResult
    private func requestAccessibility(prompt: Bool) -> Bool {
        // kAXTrustedCheckOptionPrompt is a non-Sendable global under Swift 6; its value is this literal.
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        hasAccessibility = AXIsProcessTrustedWithOptions(options)
        return hasAccessibility
    }

    private func refreshAccessibility() {
        let was = hasAccessibility
        // Poll without prompting to avoid repeated dialogs.
        if requestAccessibility(prompt: false), !was {
            rebuildMenu()
        }
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
        requestAccessibility(prompt: true)
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()

        if !hasAccessibility {
            let warn = NSMenuItem(
                title: "접근성 권한 필요",
                action: #selector(openAccessibilitySettings),
                keyEquivalent: ""
            )
            warn.target = self
            menu.addItem(warn)
            menu.addItem(.separator())
        }

        let settings = NSMenuItem(title: "설정…", action: nil, keyEquivalent: ",")
        settings.isEnabled = false // 자리만 — 동작 없음
        menu.addItem(settings)

        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        )

        statusItem.menu = menu
    }
}
