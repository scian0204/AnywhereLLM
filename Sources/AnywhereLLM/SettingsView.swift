import SwiftUI
import ServiceManagement
import Carbon.HIToolbox
import LLMCore

/// Settings form. All UserDefaults-backed keys use @AppStorage (auto-persist + auto-refresh).
/// The API key lives in the Keychain, not UserDefaults, so it's loaded on appear and written
/// on change. Hotkey is captured via a local NSEvent monitor and stored as Carbon codes,
/// matching what HotkeyManager reads.
struct SettingsView: View {
    let onHotkeyChanged: () -> Void

    @AppStorage("llm.baseURL") private var baseURL = "https://api.openai.com/v1"
    @AppStorage("llm.model") private var model = "gpt-4o-mini"
    @AppStorage("llm.disableThink") private var disableThink = false
    @AppStorage("applyMode") private var applyMode = "preview"
    @AppStorage("panelPosition") private var panelPosition = "caret"
    @AppStorage("includeAppName") private var includeAppName = true
    @AppStorage("includeFullText") private var includeFullText = false
    @AppStorage("hotkeyKeyCode") private var hotkeyKeyCode = kVK_Space
    @AppStorage("hotkeyModifiers") private var hotkeyModifiers = Int(cmdKey | shiftKey)

    // Keychain is not @AppStorage — load on appear, write on commit.
    @State private var apiKey = ""
    @State private var recording = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    // Hotkey recorder monitor handle; removed when recording stops or view disappears.
    @State private var monitor: Any?

    // Model fetching.
    @State private var fetchedModels: [String] = []
    @State private var fetching = false
    @State private var fetchError: String?

    // Prompt profiles (loaded/migrated on appear; mirrors active prompt into "systemPrompt").
    @State private var profiles: [PromptProfile] = []
    @State private var activeProfile = ""

    var body: some View {
        Form {
            Section("LLM") {
                TextField("Base URL", text: $baseURL)
                SecureField(L("settings.apiKey"), text: $apiKey)
                    .onSubmit { KeychainStore.set(AnthropicOAuth.sanitize(apiKey)) }
                    .onChange(of: apiKey) { _, new in KeychainStore.set(AnthropicOAuth.sanitize(new)) }
                if AnthropicOAuth.isSetupToken(apiKey) {
                    // 셋업 토큰 인식됨 — Anthropic 구독으로 라우팅. Base URL/모델 필드는 무시된다.
                    Text(L("settings.setupTokenActive"))
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Text(L("settings.apiKeyHint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if showCleartextKeyWarning {
                    Text(L("settings.cleartextKeyWarning"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack {
                    TextField(L("settings.model"), text: $model)
                    Button(fetching ? L("settings.fetching") : L("settings.fetchModels")) { fetchModels() }
                        .disabled(fetching)
                }
                if !fetchedModels.isEmpty {
                    // Text field stays the source of truth; picker just fills it.
                    Picker(L("settings.fetchedModels"), selection: $model) {
                        ForEach(fetchedModels, id: \.self) { Text($0).tag($0) }
                    }
                }
                if let fetchError {
                    Text(fetchError).font(.caption).foregroundStyle(.red)
                }

                Toggle(L("settings.disableThink"), isOn: $disableThink)
                if disableThink {
                    Text(L("settings.disableThinkHelp"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(L("settings.behavior")) {
                Picker(L("settings.applyMode"), selection: $applyMode) {
                    Text(L("settings.applyPreview")).tag("preview")
                    Text(L("settings.applyImmediate")).tag("immediate")
                }
                Picker(L("settings.panelPosition"), selection: $panelPosition) {
                    Text(L("settings.positionCaret")).tag("caret")
                    Text(L("settings.positionMouse")).tag("mouse")
                    Text(L("settings.positionCenter")).tag("center")
                }
            }

            Section(L("settings.context")) {
                Toggle(L("settings.includeAppName"), isOn: $includeAppName)
                Toggle(L("settings.includeFullText"), isOn: $includeFullText)
                if includeFullText {
                    Text(L("settings.fullTextWarning"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section(L("settings.systemPrompt")) {
                HStack {
                    Picker(L("settings.profile"), selection: $activeProfile) {
                        ForEach(profiles) { Text($0.name).tag($0.name) }
                    }
                    .onChange(of: activeProfile) { _, _ in mirrorActivePrompt() }
                    Button(L("settings.add")) { addProfile() }
                    Button(L("settings.rename")) { renameProfile() }
                    Button(L("settings.delete")) { deleteProfile() }
                        .disabled(profiles.count <= 1)
                }
                TextEditor(text: activePromptBinding)
                    .frame(minHeight: 80)
                    .font(.body)
            }

            Section(L("settings.hotkey")) {
                HStack {
                    Text(hotkeyDisplay)
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                    Button(recording ? L("settings.recordingKeys") : L("settings.record")) {
                        recording ? stopRecording() : startRecording()
                    }
                }
            }

            Section(L("settings.system")) {
                Toggle(L("settings.launchAtLogin"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 620)
        .onAppear {
            apiKey = KeychainStore.get() ?? ""
            loadProfiles()
        }
        .onDisappear { stopRecording() }
    }

    // MARK: - Model fetching

    private func fetchModels() {
        fetching = true
        fetchError = nil
        // Reads baseURL/API key from defaults+Keychain, which SettingsView already persisted.
        Task {
            do {
                let models = try await LLMClient().fetchModels()
                fetchedModels = models
                if models.isEmpty { fetchError = L("settings.emptyModelList") }
            } catch {
                fetchError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            fetching = false
        }
    }

    // MARK: - Prompt profiles

    /// TextEditor binding into the active profile; every keystroke persists + mirrors.
    private var activePromptBinding: Binding<String> {
        Binding(
            get: { profiles.first { $0.name == activeProfile }?.prompt ?? "" },
            set: { new in
                guard let i = profiles.firstIndex(where: { $0.name == activeProfile }) else { return }
                profiles[i].prompt = new
                saveProfiles()
            }
        )
    }

    private func loadProfiles() {
        profiles = PromptProfile.loadAll()
        activeProfile = PromptProfile.activeName(in: profiles)
        saveProfiles()
    }

    /// Persist profiles + active name, and mirror the active prompt into "systemPrompt"
    /// so ConversationController keeps reading a single key (no change needed there).
    private func saveProfiles() {
        UserDefaults.standard.set(try? JSONEncoder().encode(profiles),
                                  forKey: PromptProfile.profilesKey)
        mirrorActivePrompt()
    }

    private func mirrorActivePrompt() {
        PromptProfile.setActive(activeProfile, in: profiles)
    }

    private func addProfile() {
        let name = uniqueName(L("settings.newProfile"))
        profiles.append(PromptProfile(name: name, prompt: ""))
        activeProfile = name
        saveProfiles()
    }

    private func renameProfile() {
        guard let i = profiles.firstIndex(where: { $0.name == activeProfile }) else { return }
        let new = promptForName(current: profiles[i].name)
        guard let new, new != profiles[i].name else { return }
        profiles[i].name = uniqueName(new)
        activeProfile = profiles[i].name
        saveProfiles()
    }

    private func deleteProfile() {
        guard profiles.count > 1,
              let i = profiles.firstIndex(where: { $0.name == activeProfile }) else { return }
        profiles.remove(at: i)
        activeProfile = profiles[0].name
        saveProfiles()
    }

    private func uniqueName(_ base: String) -> String {
        var name = base
        var n = 2
        while profiles.contains(where: { $0.name == name }) { name = "\(base) \(n)"; n += 1 }
        return name
    }

    /// Simple modal text prompt — no custom sheet needed for a rename.
    private func promptForName(current: String) -> String? {
        let alert = NSAlert()
        alert.messageText = L("settings.profileName")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = current
        alert.accessoryView = field
        alert.addButton(withTitle: L("common.ok"))
        alert.addButton(withTitle: L("common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Hotkey recording

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let carbon = carbonModifiers(from: event.modifierFlags)
            // Require at least one modifier so we don't grab a bare key.
            guard carbon != 0 else { return nil }
            hotkeyKeyCode = Int(event.keyCode)
            hotkeyModifiers = Int(carbon)
            stopRecording()
            onHotkeyChanged()
            return nil // swallow — don't let the combo type into the field
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }

    // MARK: - Launch at login

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("AnywhereLLM: launch-at-login toggle failed: \(error)")
            launchAtLogin = SMAppService.mainApp.status == .enabled // revert to truth
        }
    }

    // MARK: - Display

    private var hotkeyDisplay: String {
        modifierSymbols(hotkeyModifiers) + keyName(hotkeyKeyCode)
    }

    /// 평문 http로 loopback이 아닌 호스트(LAN LiteLLM/프록시 등)에 API 키를 보내면
    /// 같은 네트워크의 누구나 스니핑할 수 있다. ATS는 IP 리터럴/.local을 예외 처리하므로
    /// OS가 막지 않는다 — 키가 있고 위험 구성일 때만 경고를 띄운다.
    private var showCleartextKeyWarning: Bool {
        guard !apiKey.isEmpty,
              let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased() else { return false }
        return !["127.0.0.1", "localhost", "::1"].contains(host)
    }
}

/// A named system-prompt profile. `id` is the name (names are kept unique).
struct PromptProfile: Codable, Identifiable {
    var name: String
    var prompt: String
    var id: String { name }
}

/// 프로필 저장소 헬퍼 — SettingsView와 패널(ConversationView 드롭다운)이 공유.
extension PromptProfile {
    static let profilesKey = "promptProfiles"
    static let activeKey = "activeProfile"
    /// ConversationController가 읽는 단일 키 (값은 ConversationController.systemPromptKey와 동일 —
    /// 그쪽은 @MainActor 격리라 비격리 컨텍스트에서 참조 불가, 리터럴 유지).
    static let mirrorKey = "systemPrompt"

    /// 저장된 프로필 로드. 없으면 레거시 단일 systemPrompt를 "기본" 프로필로 취급.
    static func loadAll(_ d: UserDefaults = .standard) -> [PromptProfile] {
        if let data = d.data(forKey: profilesKey),
           let decoded = try? JSONDecoder().decode([PromptProfile].self, from: data),
           !decoded.isEmpty {
            return decoded
        }
        return [PromptProfile(name: L("settings.defaultProfile"), prompt: d.string(forKey: mirrorKey) ?? "")]
    }

    /// 저장된 활성 이름이 목록에 있으면 그것, 아니면 첫 프로필.
    static func activeName(in profiles: [PromptProfile], _ d: UserDefaults = .standard) -> String {
        guard let stored = d.string(forKey: activeKey),
              profiles.contains(where: { $0.name == stored }) else { return profiles[0].name }
        return stored
    }

    /// 활성 이름 저장 + 해당 프롬프트를 systemPrompt로 미러 — 소비측은 프로필 개념을 모른다.
    static func setActive(_ name: String, in profiles: [PromptProfile], _ d: UserDefaults = .standard) {
        d.set(name, forKey: activeKey)
        d.set(profiles.first { $0.name == name }?.prompt ?? "", forKey: mirrorKey)
    }
}

// MARK: - Carbon / NSEvent modifier bridging + key names (free functions, no self capture)

/// NSEvent modifier flags → Carbon modifier mask (what HotkeyManager registers with).
func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
    var mask: UInt32 = 0
    if flags.contains(.command) { mask |= UInt32(cmdKey) }
    if flags.contains(.shift) { mask |= UInt32(shiftKey) }
    if flags.contains(.option) { mask |= UInt32(optionKey) }
    if flags.contains(.control) { mask |= UInt32(controlKey) }
    return mask
}

func modifierSymbols(_ carbon: Int) -> String {
    var s = ""
    if carbon & controlKey != 0 { s += "⌃" }
    if carbon & optionKey != 0 { s += "⌥" }
    if carbon & shiftKey != 0 { s += "⇧" }
    if carbon & cmdKey != 0 { s += "⌘" }
    return s
}

/// A few common keys get friendly names; everything else falls back to a hex code.
func keyName(_ keyCode: Int) -> String {
    switch keyCode {
    case kVK_Space: return "Space"
    case kVK_Return: return "Return"
    case kVK_Tab: return "Tab"
    case kVK_Escape: return "Esc"
    case kVK_ANSI_A: return "A"
    case kVK_ANSI_B: return "B"; case kVK_ANSI_C: return "C"; case kVK_ANSI_D: return "D"
    case kVK_ANSI_E: return "E"; case kVK_ANSI_F: return "F"; case kVK_ANSI_G: return "G"
    case kVK_ANSI_H: return "H"; case kVK_ANSI_I: return "I"; case kVK_ANSI_J: return "J"
    case kVK_ANSI_K: return "K"; case kVK_ANSI_L: return "L"; case kVK_ANSI_M: return "M"
    case kVK_ANSI_N: return "N"; case kVK_ANSI_O: return "O"; case kVK_ANSI_P: return "P"
    case kVK_ANSI_Q: return "Q"; case kVK_ANSI_R: return "R"; case kVK_ANSI_S: return "S"
    case kVK_ANSI_T: return "T"; case kVK_ANSI_U: return "U"; case kVK_ANSI_V: return "V"
    case kVK_ANSI_W: return "W"; case kVK_ANSI_X: return "X"; case kVK_ANSI_Y: return "Y"
    case kVK_ANSI_Z: return "Z"
    default: return String(format: "key 0x%02X", keyCode)
    }
}
