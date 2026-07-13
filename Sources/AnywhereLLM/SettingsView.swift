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
    @AppStorage("systemPrompt") private var systemPrompt = ""
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

    var body: some View {
        Form {
            Section("LLM") {
                TextField("Base URL", text: $baseURL)
                TextField("모델", text: $model)
                SecureField("API 키", text: $apiKey)
                    .onSubmit { KeychainStore.set(apiKey) }
                    .onChange(of: apiKey) { _, new in KeychainStore.set(new) }
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
                TextEditor(text: $systemPrompt)
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
        .onAppear { apiKey = KeychainStore.get() ?? "" }
        .onDisappear { stopRecording() }
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
