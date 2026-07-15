import AppKit
import ApplicationServices
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var accessibilityTimer: Timer?
    private var hasAccessibility = false
    /// 정상(비-경고) 메뉴바 아이콘. 경고 표시 후 이 고정 이미지로 되돌린다 —
    /// 호출 시점의 현재 아이콘을 캡처해 복원하면 연속 경고 시 경고 아이콘이 고착된다.
    private var normalStatusIcon: NSImage?
    /// 마지막으로 등록에 성공한 핫키(keyCode, modifiers). 새 조합 등록 실패 시 복구용.
    private var lastGoodHotkey: (Int, Int)?

    private var hotkeyManager: HotkeyManager?
    private var promptPanel: PromptPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let icon = NSImage(
            systemSymbolName: "bubble.left.and.text.bubble.right",
            accessibilityDescription: "AnywhereLLM"
        )
        statusItem.button?.image = icon
        normalStatusIcon = icon

        installMainMenu()
        requestAccessibility(prompt: true)
        rebuildMenu()

        // 키체인 재소유 마이그레이션: 예전 서명(ad-hoc 시절) 소유 항목은 읽을 때마다
        // 암호 프롬프트가 뜬다. 시작 시 한 번 읽어 현 바이너리 소유로 재저장
        // (빈 값이면 삭제). 이때 프롬프트가 떠도 마지막 — 이후 조용히 읽힌다.
        if let key = KeychainStore.get() { KeychainStore.set(key) }

        let hotkey = HotkeyManager { [weak self] in self?.togglePanel() }
        hotkeyManager = hotkey
        if hotkey.start() {
            lastGoodHotkey = Self.currentHotkeyDefaults()
        } else {
            warnHotkeyConflict() // 기본 조합이 이미 다른 앱에 잡혀 있음
        }

        // Re-register the global hotkey immediately when the settings recorder saves a new one.
        SettingsWindowController.shared.onHotkeyChanged = { [weak self] in
            self?.reapplyHotkey()
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
            panel.dismiss() // 진행 중 스트림 취소 포함 — 숨긴 뒤 몰래 완주/삽입 방지
            return
        }

        // 접근성 권한이 런타임에 취소됐으면(TCC 리셋 등) 캡처·삽입·타이핑이 전부
        // 조용히 실패한다 — 특히 immediate 모드는 응답을 통째로 날린다. 권한을
        // 다시 확인해 없으면 무반응 대신 명확히 안내하고 중단.
        guard requestAccessibility(prompt: false) else {
            NSSound.beep()
            refreshAccessibility()          // 메뉴에 '접근성 권한 필요' 항목 노출
            openAccessibilitySettings()     // 설정 창 + 권한 프롬프트로 유도
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
        // 캡처된 요소를 앵커로 전달 — 재질의는 Chrome에서 실패한다 (progress/18).
        panel.setFrameOrigin(PanelPositioner.origin(for: panel.frame.size, anchor: context.axElement))
        // 이후 콘텐츠가 자라도 상단 고정 + 아래로 성장하도록 좌상단을 앵커.
        panel.anchorTopLeft()
        // orderFrontRegardless shows without activating the app.
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.focusInput()
    }

    /// Light feedback when the focused field is secure: beep + briefly flash the menu bar icon.
    private func warnSecureField() {
        NSSound.beep()
        let button = statusItem.button
        button?.image = NSImage(systemSymbolName: "lock.slash",
                                accessibilityDescription: L("app.secureFieldBlocked"))
        // 고정된 정상 아이콘으로 복원 — 현재 아이콘을 캡처해 복원하면 1초 내 두 번
        // 경고 시 두 번째가 경고 아이콘을 '원본'으로 잡아 lock.slash가 영구 고착된다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.statusItem.button?.image = self?.normalStatusIcon
        }
    }

    /// 핫키 재등록 실패(다른 앱이 조합 선점)를 알리고 직전 조합으로 복구 — 메뉴바
    /// 전용 앱의 유일한 진입점이 조용히 죽지 않게 한다.
    private func reapplyHotkey() {
        hotkeyManager?.stop()
        if hotkeyManager?.start() == true {
            lastGoodHotkey = Self.currentHotkeyDefaults()
            return
        }
        warnHotkeyConflict()
        if let (keyCode, modifiers) = lastGoodHotkey {
            UserDefaults.standard.set(keyCode, forKey: "hotkeyKeyCode")
            UserDefaults.standard.set(modifiers, forKey: "hotkeyModifiers")
            hotkeyManager?.start() // 직전 조합 재등록 — 앱은 계속 열 수 있다
        }
    }

    private func warnHotkeyConflict() {
        let alert = NSAlert()
        alert.messageText = L("hotkey.conflictTitle")
        alert.informativeText = L("hotkey.conflictMessage")
        alert.addButton(withTitle: L("common.ok"))
        alert.runModal()
    }

    private static func currentHotkeyDefaults() -> (Int, Int) {
        let d = UserDefaults.standard
        let keyCode = d.object(forKey: "hotkeyKeyCode") as? Int ?? Int(kVK_Space)
        let modifiers = d.object(forKey: "hotkeyModifiers") as? Int ?? Int(cmdKey | shiftKey)
        return (keyCode, modifiers)
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
        requestAccessibility(prompt: false)
        // 어느 방향 전환이든 메뉴를 다시 그린다 — 권한을 런타임에 취소당하면(TCC 리셋)
        // 유일한 복구 수단인 '접근성 권한 필요' 항목이 다시 나타나야 한다.
        if hasAccessibility != was { rebuildMenu() }
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
        let edit = NSMenu(title: L("menu.edit"))
        edit.addItem(withTitle: L("menu.undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: L("menu.redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: L("menu.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("menu.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("menu.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("menu.selectAll"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()

        if !hasAccessibility {
            let warn = NSMenuItem(
                title: L("menu.accessibilityNeeded"),
                action: #selector(openAccessibilitySettings),
                keyEquivalent: ""
            )
            warn.target = self
            menu.addItem(warn)
            menu.addItem(.separator())
        }

        let settings = NSMenuItem(title: L("menu.settings"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        // 실행 중인 바이너리가 어느 빌드인지 즉시 식별 (Makefile이 빌드 시각 스탬프).
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let buildItem = NSMenuItem(title: L("menu.build", build), action: nil, keyEquivalent: "")
        buildItem.isEnabled = false
        menu.addItem(buildItem)
        menu.addItem(
            NSMenuItem(title: L("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        )

        statusItem.menu = menu
    }
}
