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
    /// 마지막으로 등록에 성공한 핫키(id → (keyCode, modifiers)). 새 조합 등록 실패 시 복구용.
    private var lastGoodHotkeys: [UInt32: (Int, Int)] = [:]

    /// 등록 핫키 정의(id + UserDefaults 키 + 기본값). 매니저 구성과 충돌 복구가 공유.
    private struct HotkeyDef {
        let id: UInt32
        let keyCodeKey: String
        let modifiersKey: String
        let defaultKeyCode: Int
        let defaultModifiers: Int
    }
    private static let panelHotkey = HotkeyDef(
        id: 1, keyCodeKey: "hotkeyKeyCode", modifiersKey: "hotkeyModifiers",
        defaultKeyCode: kVK_Space, defaultModifiers: Int(cmdKey | shiftKey))
    private static let captureHotkey = HotkeyDef(
        id: 2, keyCodeKey: "captureHotkeyKeyCode", modifiersKey: "captureHotkeyModifiers",
        defaultKeyCode: kVK_ANSI_2, defaultModifiers: Int(cmdKey | shiftKey))
    private static var hotkeyDefs: [HotkeyDef] { [panelHotkey, captureHotkey] }

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

        let manager = HotkeyManager(hotkeys: [
            HotkeyManager.Hotkey(
                id: Self.panelHotkey.id,
                keyCodeDefaultsKey: Self.panelHotkey.keyCodeKey,
                modifiersDefaultsKey: Self.panelHotkey.modifiersKey,
                defaultKeyCode: UInt32(Self.panelHotkey.defaultKeyCode),
                defaultModifiers: UInt32(Self.panelHotkey.defaultModifiers),
                action: { [weak self] in self?.togglePanel() }),
            HotkeyManager.Hotkey(
                id: Self.captureHotkey.id,
                keyCodeDefaultsKey: Self.captureHotkey.keyCodeKey,
                modifiersDefaultsKey: Self.captureHotkey.modifiersKey,
                defaultKeyCode: UInt32(Self.captureHotkey.defaultKeyCode),
                defaultModifiers: UInt32(Self.captureHotkey.defaultModifiers),
                action: { [weak self] in self?.captureScreenRegion() }),
        ])
        hotkeyManager = manager
        let failed = manager.start()
        recordGoodHotkeys(excluding: failed)
        if !failed.isEmpty { warnHotkeyConflict() } // 기본/저장 조합이 다른 앱에 잡혀 있음

        // Re-register the global hotkey immediately when the settings recorder saves a new one.
        SettingsWindowController.shared.onHotkeyChanged = { [weak self] in
            self?.reapplyHotkey()
        }

        // ponytail: 5s poll instead of AX notification observer; simplest way to refresh grant state
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccessibility() }
        }

        // 실행 시 조용히 업데이트 확인 — 새 버전이면 프롬프트 (실패는 무시).
        Task { await runUpdateCheck(auto: true) }
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
        guard let manager = hotkeyManager else { return }
        manager.stop()
        let failed = manager.start()
        if failed.isEmpty {
            recordGoodHotkeys(excluding: [])
            return
        }
        warnHotkeyConflict()
        // 실패한 핫키만 직전 조합으로 되돌린다 — 성공한 다른 핫키의 새 조합은 유지.
        for id in failed {
            if let (keyCode, modifiers) = lastGoodHotkeys[id],
               let def = Self.hotkeyDefs.first(where: { $0.id == id }) {
                UserDefaults.standard.set(keyCode, forKey: def.keyCodeKey)
                UserDefaults.standard.set(modifiers, forKey: def.modifiersKey)
            }
        }
        manager.stop()
        let stillFailed = manager.start() // 되돌린 조합으로 재등록 — 앱은 계속 열 수 있다
        recordGoodHotkeys(excluding: stillFailed)
    }

    private func warnHotkeyConflict() {
        let alert = NSAlert()
        alert.messageText = L("hotkey.conflictTitle")
        alert.informativeText = L("hotkey.conflictMessage")
        alert.addButton(withTitle: L("common.ok"))
        alert.runModal()
    }

    /// 방금 (재)등록에 성공한 핫키들의 현재 조합을 직전-정상 값으로 기록.
    private func recordGoodHotkeys(excluding failed: [UInt32]) {
        let d = UserDefaults.standard
        for def in Self.hotkeyDefs where !failed.contains(def.id) {
            let keyCode = d.object(forKey: def.keyCodeKey) as? Int ?? def.defaultKeyCode
            let modifiers = d.object(forKey: def.modifiersKey) as? Int ?? def.defaultModifiers
            lastGoodHotkeys[def.id] = (keyCode, modifiers)
        }
    }

    // MARK: - Screen capture (image query)

    /// 두 번째 핫키: 화면 영역을 드래그로 캡쳐(⌘⇧4식)해 이미지 질의 패널을 띄운다.
    /// 접근성 권한은 불필요(보기 전용, 삽입 없음) — 화면 기록 권한만 필요.
    private func captureScreenRegion() {
        // 화면 기록 권한이 없으면 캡쳐가 빈/데스크톱 이미지가 된다 — 요청 + 안내 후
        // 이번 캡쳐는 중단(권한은 앱 재시작 후 적용된다).
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            warnScreenRecordingNeeded()
            return
        }
        // 진행 중이던 세션은 무조건 정리 — immediate 타이핑 중엔 패널이 숨겨져(orderOut)
        // isVisible이 false라, 조건부 dismiss면 스트림이 캡쳐 드래그 동안에도 계속
        // 대상 앱에 타이핑된다. dismiss()는 숨겨진/미표시 패널에도 안전.
        promptPanel?.dismiss()
        // screencapture -i는 사용자 드래그 동안 블록 — 백그라운드에서 실행, 결과만 main에서.
        Task.detached {
            let png = ScreenCapture.captureRegion()
            await MainActor.run { self.presentImagePanel(png) }
        }
    }

    /// 캡쳐 PNG로 보기 전용 이미지 컨텍스트를 만들어 기존 패널을 띄운다.
    private func presentImagePanel(_ png: Data?) {
        guard let png, !png.isEmpty else { return } // 취소/실패 — 패널 안 띄움
        let panel = promptPanel ?? {
            let p = PromptPanel()
            promptPanel = p
            return p
        }()
        let app = NSWorkspace.shared.frontmostApplication
        let context = TargetContext(
            appName: app?.localizedName, bundleId: app?.bundleIdentifier,
            selectedText: nil, fullText: nil,
            isSecureField: false, isEditable: false, axElement: nil, image: png)
        panel.present(context: context)
        // 이미지 컨텍스트엔 앵커 요소가 없다 — 마우스(=선택 직후 위치) 폴백으로 위치.
        panel.setFrameOrigin(PanelPositioner.origin(for: panel.frame.size, anchor: nil))
        panel.anchorTopLeft()
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.focusInput()
    }

    private func warnScreenRecordingNeeded() {
        let alert = NSAlert()
        alert.messageText = L("screenRecording.neededTitle")
        alert.informativeText = L("screenRecording.neededMessage")
        alert.addButton(withTitle: L("screenRecording.openSettings"))
        alert.addButton(withTitle: L("common.cancel"))
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
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

    // MARK: - Self-update

    private var updateBusy = false

    @objc private func checkForUpdates() {
        Task { await runUpdateCheck(auto: false) }
    }

    /// auto=true는 실행 시 조용한 확인(최신이면 무반응), auto=false는 메뉴 동작.
    /// 확인+적용되면 앱을 종료 — 헬퍼가 우리 종료를 기다렸다 번들을 교체·재실행한다.
    private func runUpdateCheck(auto: Bool) async {
        if updateBusy { return }
        updateBusy = true
        defer { updateBusy = false }

        guard let rel = await UpdateService.check() else {
            if !auto { infoAlert(L("update.upToDate")) }
            return
        }

        let confirm = NSAlert()
        confirm.messageText = L("update.availableTitle")
        confirm.informativeText = L("update.availableMessage", rel.tag)
        confirm.addButton(withTitle: L("update.installNow"))
        confirm.addButton(withTitle: L("common.cancel"))
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        do {
            if try await UpdateService.downloadAndApply(rel) {
                NSApp.terminate(nil)
            } else {
                infoAlert(L("update.notWritable"))
            }
        } catch {
            infoAlert(L("update.failed", error.localizedDescription))
        }
    }

    private func infoAlert(_ text: String) {
        let a = NSAlert()
        a.messageText = "AnywhereLLM"
        a.informativeText = text
        a.addButton(withTitle: L("common.ok"))
        a.runModal()
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

        let update = NSMenuItem(title: L("update.check"), action: #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        menu.addItem(update)

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
