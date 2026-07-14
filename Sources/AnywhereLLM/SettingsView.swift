import SwiftUI
import ServiceManagement
import Carbon.HIToolbox

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
                SecureField("API 키", text: $apiKey)
                    .onSubmit { KeychainStore.set(apiKey) }
                    .onChange(of: apiKey) { _, new in KeychainStore.set(new) }

                HStack {
                    TextField("모델", text: $model)
                    Button(fetching ? "가져오는 중…" : "모델 가져오기") { fetchModels() }
                        .disabled(fetching)
                }
                if !fetchedModels.isEmpty {
                    // Text field stays the source of truth; picker just fills it.
                    Picker("가져온 모델", selection: $model) {
                        ForEach(fetchedModels, id: \.self) { Text($0).tag($0) }
                    }
                }
                if let fetchError {
                    Text(fetchError).font(.caption).foregroundStyle(.red)
                }

                Toggle("생각(think) 모드 끄기", isOn: $disableThink)
                if disableThink {
                    Text("Qwen3.5/Gemma 4 등 reasoning 모델의 생각 과정을 요청 단계에서 끕니다. Ollama는 네이티브 API로 자동 전환해 완전 차단합니다. 미지원 서버(OpenAI 등)에서 오류가 나면 끄세요. <think> 출력 필터는 항상 동작합니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("동작") {
                Picker("결과 반영", selection: $applyMode) {
                    Text("미리보기 후 확정").tag("preview")
                    Text("즉시 반영").tag("immediate")
                }
                Picker("패널 위치", selection: $panelPosition) {
                    Text("캐럿 추적").tag("caret")
                    Text("마우스 위치").tag("mouse")
                    Text("화면 중앙").tag("center")
                }
            }

            Section("컨텍스트") {
                Toggle("대상 앱 이름 포함", isOn: $includeAppName)
                Toggle("필드 전체 내용 포함", isOn: $includeFullText)
                if includeFullText {
                    Text("포커스된 필드 전체 내용이 API로 전송됩니다.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("시스템 프롬프트") {
                HStack {
                    Picker("프로필", selection: $activeProfile) {
                        ForEach(profiles) { Text($0.name).tag($0.name) }
                    }
                    .onChange(of: activeProfile) { _, _ in mirrorActivePrompt() }
                    Button("추가") { addProfile() }
                    Button("이름변경") { renameProfile() }
                    Button("삭제") { deleteProfile() }
                        .disabled(profiles.count <= 1)
                }
                TextEditor(text: activePromptBinding)
                    .frame(minHeight: 80)
                    .font(.body)
            }

            Section("핫키") {
                HStack {
                    Text(hotkeyDisplay)
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                    Button(recording ? "키 입력 대기…" : "녹화") {
                        recording ? stopRecording() : startRecording()
                    }
                }
            }

            Section("시스템") {
                Toggle("로그인 시 시작", isOn: $launchAtLogin)
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
                if models.isEmpty { fetchError = "모델 목록이 비어 있습니다." }
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
        let d = UserDefaults.standard
        if let data = d.data(forKey: "promptProfiles"),
           let decoded = try? JSONDecoder().decode([PromptProfile].self, from: data),
           !decoded.isEmpty {
            profiles = decoded
        } else {
            // Migrate legacy single systemPrompt into a "기본" profile.
            profiles = [PromptProfile(name: "기본", prompt: d.string(forKey: "systemPrompt") ?? "")]
        }
        if !profiles.contains(where: { $0.name == d.string(forKey: "activeProfile") }) {
            activeProfile = profiles[0].name
        } else {
            activeProfile = d.string(forKey: "activeProfile")!
        }
        saveProfiles()
    }

    /// Persist profiles + active name, and mirror the active prompt into "systemPrompt"
    /// so ConversationController keeps reading a single key (no change needed there).
    private func saveProfiles() {
        let d = UserDefaults.standard
        d.set(try? JSONEncoder().encode(profiles), forKey: "promptProfiles")
        d.set(activeProfile, forKey: "activeProfile")
        mirrorActivePrompt()
    }

    private func mirrorActivePrompt() {
        let prompt = profiles.first { $0.name == activeProfile }?.prompt ?? ""
        UserDefaults.standard.set(prompt, forKey: "systemPrompt")
        UserDefaults.standard.set(activeProfile, forKey: "activeProfile")
    }

    private func addProfile() {
        let name = uniqueName("새 프로필")
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
        alert.messageText = "프로필 이름"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = current
        alert.accessoryView = field
        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "취소")
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
}

/// A named system-prompt profile. `id` is the name (names are kept unique).
struct PromptProfile: Codable, Identifiable {
    var name: String
    var prompt: String
    var id: String { name }
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
