# 이중 플랫폼 개발 가이드 (macOS · Windows)

AnywhereLLM은 macOS(Swift/AppKit, 루트 `Sources/`)와 Windows(.NET/WPF, `windows/`)
두 구현을 함께 유지한다. **새 기능·버그 수정은 원칙적으로 두 플랫폼에 동시에 반영한다.**
한쪽만 고치면 회귀로 본다.

## 소스 배치 (mac ↔ win)

| 관심사 | macOS (Swift) | Windows (.NET) |
|---|---|---|
| 순수 로직(SSE/think/Ollama/endpoint) | `Sources/LLMCore/` | `windows/AnywhereLLM.Core/` |
| 순수 로직 테스트 | `Tests/LLMCoreTests/` | `windows/AnywhereLLM.Core.Tests/` |
| 글로벌 핫키 | `Sources/AnywhereLLM/HotkeyManager.swift` | `windows/AnywhereLLM.App/Services/HotkeyManager.cs` |
| 텍스트 I/O | `TextTarget.swift` | `Services/TextTargetService.cs` |
| 패널 위치 | `PanelPositioner.swift` | `Services/PanelPositioner.cs` |
| 자격증명 | `KeychainStore.swift` | `Services/CredentialStore.cs` |
| LLM 클라이언트 | `LLMClient.swift` | `Services/LlmClient.cs` |
| 대화 컨트롤러 | `ConversationController.swift` | `UI/ConversationController.cs` |
| 패널 UI | `PromptPanel.swift` + `ConversationView.swift` | `UI/PromptWindow.xaml(.cs)` |
| 설정 UI | `SettingsView.swift` | `UI/SettingsWindow.xaml(.cs)` |
| 트레이/부트스트랩 | `AppDelegate.swift` + `main.swift` | `App.xaml(.cs)` |
| 로컬라이즈 | `Resources/*.lproj/Localizable.strings` | `Services/Localization.cs` |
| 설정 저장 | UserDefaults | `Services/AppSettings.cs` (settings.json) |
| 테마 | 시스템 자동(SwiftUI) | `Services/ThemeManager.cs` (Fluent + OS 추종) |

전체 매핑·플랫폼 API 대응은 [progress/31-windows-port.md](progress/31-windows-port.md).

## 규칙

1. **순수 로직 먼저.** UI 무관 로직(파싱·필터 등)은 LLMCore(mac)와 Core(win)에 동일
   동작으로 구현하고 **양쪽 테스트를 함께** 추가/갱신한다(현재 각 38 케이스 동수).
2. **동작 동일성.** 프롬프트 조립·UX 분기(편집가능성 × 선택 × applyMode)·보안 필드 차단 등
   사용자 관찰 동작은 두 플랫폼이 같아야 한다.
3. **플랫폼 API는 각자.** AX ↔ UIA, Carbon ↔ RegisterHotKey, CGEvent ↔ SendInput,
   Keychain ↔ Credential Manager, NSPanel ↔ WPF 창. GUI/주입/포커스는 자동 검증 불가 →
   각 플랫폼 수동 테스트 시나리오를 progress 문서에 남긴다.
4. **버전 통일.** 루트 `VERSION` 파일 하나가 유일한 버전 소스 —
   mac(`Makefile`)과 win(`windows/Directory.Build.props`)이 함께 읽는다. 릴리스 시 이 파일만 올린다.
5. **진행 문서.** 기능마다 `docs/progress/NN-*.md`에 두 플랫폼 변경 + 각자 수동 테스트를 함께 기록.
6. **커밋/문서 한국어.** 한 기능의 mac+win 변경은 함께(또는 연속) 커밋.

## 빌드 / 테스트 빠른 참조

| | macOS | Windows |
|---|---|---|
| 로직 테스트 | `swift test` | `dotnet run --project windows/AnywhereLLM.Core.Tests -c Release` |
| 빌드 | `make` | `dotnet build windows/AnywhereLLM.slnx -c Release` |
| 실행 | `make run` | `dotnet run --project windows/AnywhereLLM.App -c Release` |
| 배포 | `make dist` (zip) | `windows/packaging/installer/build-installer.ps1` (msi) |
