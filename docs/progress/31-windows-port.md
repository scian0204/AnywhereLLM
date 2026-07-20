# 31 — Windows 포팅 (.NET / WPF)

macOS 전용 메뉴바 앱(AppKit + SwiftUI + Carbon + Accessibility)을 Windows 네이티브로
전환. 브랜치 `windows-port`. 산출물은 `windows/` 아래 .NET 솔루션으로 격리 — 기존
Swift/SPM 소스는 그대로 두어(coexist) 참조·회귀 대조가 가능하게 한다.

## 스택 결정

**C# / .NET 10 + WPF** (+ WinForms NotifyIcon, Win32 P/Invoke, UI Automation).

근거: 앱의 90%가 딥 OS 통합(글로벌 핫키, 타 앱 텍스트 주입, 트레이, 비활성 창,
자격증명 저장)이라 스택이 전부를 좌우한다. .NET은 이 전부에 1급 접근을 제공
(RegisterHotKey, UIAutomation, NotifyIcon, Credential Manager, SendInput). 순수
로직(SSE/think필터/Ollama/endpoint)만 C#로 재구현. Swift-on-Windows는 순수 로직 4개
파일만 아끼고 GUI/OS 글루 90%는 어차피 전면 재작성 + 미성숙 툴체인 고통이라 탈락.

## 파일 매핑 (Swift → C#)

| macOS (Swift) | Windows (C#) | 상태 |
|---|---|---|
| `LLMCore/SSEParser` | `Core/SseParser.cs` | ✅ 포팅+테스트 |
| `LLMCore/ThinkTagFilter` | `Core/ThinkTagFilter.cs` (struct→class) | ✅ |
| `LLMCore/OllamaChatParser` | `Core/OllamaChatParser.cs` | ✅ |
| `LLMCore/Endpoint` | `Core/Endpoint.cs` | ✅ |
| (LineResult 통합) | `Core/LineResult.cs` | ✅ |
| `Tests/LLMCoreTests/*` | `Core.Tests/Program.cs` (무의존 러너) | ✅ 38/38 |
| `HotkeyManager` (Carbon) | `App/Services/HotkeyManager.cs` (RegisterHotKey) | ✅ |
| `TextTarget` (AX) | `App/Services/TextTargetService.cs` (UIA+SendInput) | ✅ |
| `PanelPositioner` (AX) | `App/Services/PanelPositioner.cs` (UIA/GUITHREADINFO) | ✅ |
| `KeychainStore` | `App/Services/CredentialStore.cs` (Credential Manager) | ✅ |
| `LLMClient` (URLSession) | `App/Services/LlmClient.cs` (HttpClient) | ✅ |
| `L10n` + .strings | `App/Services/Localization.cs` (en/ko dict) | ✅ |
| UserDefaults/@AppStorage | `App/Services/AppSettings.cs` (JSON dict) | ✅ |
| `ConversationController` | `App/UI/ConversationController.cs` | ✅ |
| `PromptPanel` (NSPanel) | `App/UI/PromptWindow.xaml(.cs)` (WS_EX_NOACTIVATE) | ✅ |
| `ConversationView` (SwiftUI) | `PromptWindow.xaml` 내 인라인 | ✅ |
| `SettingsView`/`SettingsWindowController` | `App/UI/SettingsWindow.xaml(.cs)` | ✅ |
| `AppDelegate` (NSStatusItem) | `App/App.xaml(.cs)` + `TrayIcon` | ✅ |
| `main.swift` | `App/App.xaml.cs` 부트스트랩 | ✅ |
| (Win32 시그니처) | `App/Interop/NativeMethods.cs` | ✅ |

## 플랫폼 동작 매핑

- **글로벌 핫키**: `RegisterHotKey(hwnd, id, MOD_*, vk)` + 메시지 전용 창의 `WM_HOTKEY`.
  기본값 mac `⌘⇧Space` → Windows `Ctrl+Shift+Space`(MOD_CONTROL|MOD_SHIFT, VK_SPACE).
  Win 키는 modifier로 불안정해 제외.
- **비활성 패널 — 상호작용 모델 차이(중요)**: macOS는 `.nonactivatingPanel`로 대상 앱을
  frontmost 유지한 채 패널이 키 입력을 받는다. Windows는 `WS_EX_NOACTIVATE` 창이
  키 포커스를 못 받으므로 같은 방식 불가. 대신:
  1. 핫키 시점에 대상 컨텍스트(HWND, 포커스 UIA 요소, 선택 텍스트, 캐럿 rect,
     isPassword)를 **먼저 캡처**.
  2. 패널을 정상 활성화해 사용자가 프롬프트를 입력(대상은 포커스 잃어도 선택 범위는
     보존 — 편집 컨트롤은 재포커스 시 선택 복원).
  3. 확정/즉시 반영 시 `SetForegroundWindow(대상 HWND)` 재포커스 후 SendInput
     유니코드 타이핑(살아있는 선택을 대체) 또는 UIA ValuePattern.
  → mac의 "타이핑이 선택을 대체" 폴백을 Windows의 1차 경로로 채택.
- **텍스트 읽기(캡처)**: UIA `AutomationElement.FocusedElement` → `TextPattern.GetSelection()`
  으로 선택 문자열/범위, 없으면 `ValuePattern.Current.Value`로 전체. 실패 시 클립보드
  백업 + `Ctrl+C`(SendInput) + `GetClipboardSequenceNumber` 폴링 + 복원 폴백(mac ⌘C 대응).
- **텍스트 쓰기(삽입/교체)**: SendInput `KEYEVENTF_UNICODE` 유니코드 타이핑(클립보드
  무접촉, 서로게이트 경계 처리). 자기 핫키 재유입 방지는 주입 중 등록 해제 또는 스캔코드
  마킹으로.
- **보안 필드 하드 차단**: UIA `IsPasswordProperty` == true면 캡처/삽입/클립보드 전면 차단.
  설정으로 못 푼다(하드 룰 유지).
- **캐럿 위치**: UIA `GetSelection()[0].GetBoundingRectangles()`(스크린 좌표) → 폴백
  `GetGUIThreadInfo().rcCaret` + `ClientToScreen` → 폴백 포커스 요소 rect → 폴백 커서.
  물리 픽셀 → WPF DIP 변환(DPI) 필요.
- **트레이**: WinForms `NotifyIcon` + `ContextMenuStrip`(설정/빌드정보/종료). Windows는
  접근성 권한 개념 없음 → 권한 플로우 전체 삭제(단, 상승된 창엔 UIAccess 없이는 주입
  불가 — 알려진 한계로 문서화).
- **자격증명**: Windows Credential Manager(`CredWrite/CredRead/CredDelete` P/Invoke,
  `CRED_TYPE_GENERIC`). Keychain의 정확한 대응.
- **LLM 스트리밍**: `HttpClient` + `HttpCompletionOption.ResponseHeadersRead` +
  `ReadAsStreamAsync`. 바이트를 직접 `\n` 프레이밍(mac과 동일, `\r` 스트립) — `[DONE]`/
  `done:true` 없이 끊기면 truncated 오류로 승격. Ollama 판별 `GET /api/version`.
- **설정 저장**: `%APPDATA%\AnywhereLLM\settings.json` (문자열 키 dict — UserDefaults
  의미 유지). 프롬프트 프로필 미러링(활성 프로필 → `systemPrompt` 키) 그대로.
- **로그인 시 시작**: `HKCU\...\Run` 레지스트리 값(SMAppService 대응).
- **테마(라이트/다크)**: macOS는 시스템 외관 자동 추종 → Windows도 OS 앱 테마
  (레지스트리 `AppsUseLightTheme`) 추종. WPF Fluent `Application.ThemeMode`로 표준
  컨트롤(TextBox/ComboBox/Button/GroupBox/PasswordBox/스크롤바)·설정창 크롬을
  라이트/다크로 자동 재테마 + 손수 만든 패널 표면은 테마 브러시
  (`Brush.Surface`/`SurfaceAlt`/`Border`/`Text`) 스왑. OS 테마 전환 시
  `SystemEvents.UserPreferenceChanged`로 실시간 갱신 (`Services/ThemeManager.cs`).
- **앱 아이콘**: `Resources/AppIcon.ico`(GDI+로 생성 — mac 아이콘 언어 계승: 인디고
  `#5B5BD6` 라운드 사각형 + 흰 4점 스파클, 16~256 다중 크기). `ApplicationIcon`으로
  exe/작업표시줄/Explorer, 트레이는 `ExtractAssociatedIcon`, 설정창은 `Window.Icon`.

## 빌드 / 실행

```
cd windows
dotnet run --project AnywhereLLM.Core.Tests -c Release   # 순수 로직 테스트 (38개)
dotnet build -c Release                                   # 전체
dotnet run  --project AnywhereLLM.App -c Release          # 앱 실행 (트레이 상주)
```

기본 핫키 `Ctrl+Shift+Space`.

## 수동 검증 필요 (자동 불가 — GUI/주입/포커스)

1. 핫키로 패널 표시/토글, 다른 앱 위에서도 발동.
2. 메모장/워드패드/브라우저 텍스트박스에 삽입(무선택 즉시 반영).
3. 텍스트 선택 후 교체(preview 확정 + immediate).
4. 웹페이지 본문/PDF 선택 = 보기 전용(패널 유지).
5. 비밀번호 필드 포커스 시 차단.
6. 캐럿/마우스/중앙 패널 위치.
7. 설정 저장·모델 가져오기·핫키 녹화·로그인 시 시작.
8. 상승 권한 창(관리자 앱)에서의 주입 한계 확인.

## 미해결 / 위험

- UIA 앱별 편차(Chrome/VS Code/Electron/Slack 대응)는 mac AX와 마찬가지로 실측으로만
  확정 — 첫 릴리스는 SendInput 유니코드 타이핑을 보편 경로로 두어 최대 호환.
- `SetForegroundWindow` 제약(포그라운드 프로세스만 허용) — 패널이 방금 포그라운드였으니
  대상에 되돌리는 건 허용되나, 실패 시 `AttachThreadInput` 폴백 필요.
- 재포커스 시 선택 미복원 앱이 있으면 교체가 삽입처럼 동작 — 실측 대상.
