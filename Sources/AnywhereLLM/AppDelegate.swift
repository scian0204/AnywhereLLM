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

        installMainMenu()
        requestAccessibility(prompt: true)
        rebuildMenu()

        let hotkey = HotkeyManager { [weak self] in self?.togglePanel() }
        hotkey.start()
        hotkeyManager = hotkey

        // Re-register the global hotkey immediately when the settings recorder saves a new one.
        SettingsWindowController.shared.onHotkeyChanged = { [weak self] in
            self?.hotkeyManager?.stop()
            self?.hotkeyManager?.start()
        }

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

        // Capture the target BEFORE showing the panel — focus changes once the panel appears.
        let context = TextTargetService.captureContext()

        // Hard rule: never operate on a secure field. Warn lightly, don't show the panel.
        if context.isSecureField {
            warnSecureField()
            return
        }

        panel.present(context: context)
        // Position must be computed against the CURRENT focus, before we show the panel.
        panel.setFrameOrigin(PanelPositioner.origin(for: panel.frame.size))
        // orderFrontRegardless shows without activating the app.
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.focusInput()
    }

    /// Light feedback when the focused field is secure: beep + briefly flash the menu bar icon.
    private func warnSecureField() {
        NSSound.beep()
        let button = statusItem.button
        let original = button?.image
        button?.image = NSImage(systemSymbolName: "lock.slash",
                                accessibilityDescription: "보안 필드 차단됨")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            button?.image = original
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

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    // MARK: - Main menu (Edit menu for text-editing key routing)

    /// Accessory apps get no default main menu, so ⌘A/⌘C/⌘V/⌘Z don't route to the
    /// first responder. Install a minimal App + Edit menu — the menu bar stays hidden
    /// for an accessory app, but the standard-selector key equivalents still work in
    /// our windows (e.g. the settings text fields).
    private func installMainMenu() {
        let mainMenu = NSMenu()

        // App menu slot — required as the first item even if empty.
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "편집")
        edit.addItem(withTitle: "실행 취소", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "다시 실행", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "잘라내기", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "복사", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "전체 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
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

        let settings = NSMenuItem(title: "설정…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        )

        statusItem.menu = menu
    }
}
