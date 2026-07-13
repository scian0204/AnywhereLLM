import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var accessibilityTimer: Timer?
    private var hasAccessibility = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "bubble.left.and.text.bubble.right",
            accessibilityDescription: "AnywhereLLM"
        )

        requestAccessibility(prompt: true)
        rebuildMenu()

        // ponytail: 5s poll instead of AX notification observer; simplest way to refresh grant state
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccessibility() }
        }
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
