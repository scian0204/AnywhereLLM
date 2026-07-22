# 35 — 스크린 영역 캡쳐 → 이미지 LLM 질의

두 번째 글로벌 핫키로 화면 영역을 드래그 캡쳐(맥 ⌘⇧4 / 윈도우 Win+Shift+S식)한 뒤,
기존 패널을 띄워 그 이미지에 대해 LLM에 질의한다. 양 플랫폼 동시 반영.

## 동작

1. 두 번째 핫키(기본 mac `⌘⇧2`, win `Ctrl+Shift+2` — 설정에서 변경 가능) 입력.
2. 화면 영역을 드래그로 선택 (Esc/우클릭 취소).
3. 캡쳐 PNG로 **보기 전용** 컨텍스트를 만들어 기존 패널을 띄운다 — 패널 상단에
   캡쳐 썸네일, 그 아래 입력창. 프로필(systemPrompt) + 입력한 질문으로 질의.
   선택 모드와 동일하게 **이미지가 있으면 첫 턴은 빈 ⏎로도 전송**(프로필이 지시 역할,
   단 프로필이 비어 있지 않을 때).
4. 답변은 패널에 스트리밍 표시되고 그대로 남는다 — 캡쳐엔 삽입할 대상 필드가 없어
   보기 전용이 자연스럽다(비목표: 원래 필드 삽입).

## 설계 결정

- **캡쳐 방식**
  - mac: `/usr/sbin/screencapture -i -x <temp.png>` — ⌘⇧4의 네이티브 드래그 UI를
    그대로 재사용(커스텀 오버레이·추가 프레임워크 불필요). 사용자 드래그 동안 블록하므로
    백그라운드 스레드에서 실행 후 결과만 main에서 처리. (`ScreenCapture.swift`)
  - win: 커스텀 전체화면 반투명 오버레이(`RegionCapture.cs`). `ms-screenclip:`은
    클립보드 비동기라 완료 신호를 못 받아 폐기. **프리즈-프레임 방식** — 오버레이를
    띄우기 전에 가상 데스크톱 전체를 `CopyFromScreen`으로 한 번 캡쳐해 두고, 드래그
    선택 영역을 그 프레임에서 crop. 오버레이가 결과에 안 찍히고 hide-후-캡쳐 리페인트
    레이스도 없다. 캡쳐 좌표는 `GetCursorPos`(물리 픽셀) + `CopyFromScreen`(물리 픽셀)
    이라 DPI 독립 — DIP↔물리 변환이 캡쳐 경로에 없다. 오버레이 커버리지만
    `SetWindowPos`로 가상 스크린 물리 경계에 맞춘다.
    - **calibration 코너**: 혼합 DPI 다중 모니터에서 오버레이 시각 사각형(DIP)이 다른
      DPI 모니터에서 미세하게 어긋날 수 있으나, 캡쳐 픽셀 자체는 물리 좌표라 정확하다.

- **두 번째 핫키(설정 변경 가능)**: 두 플랫폼 다 기존엔 핫키 1개 하드코딩이었다.
  - mac `HotkeyManager`: 단일 핸들러 → `Hotkey` 바인딩 배열(id + UserDefaults 키 쌍 +
    액션)로 일반화. **하나의** Carbon 이벤트 핸들러가 `firedID.id`로 라우팅 — 바인딩마다
    핸들러를 깔면 같은 signature 이벤트 체인에서 서로의 핫키를 먹는 모호성이 생긴다.
    `start()`는 실패한 id 배열 반환. `AppDelegate`가 id별 last-good 조합을 들고 충돌 시
    실패한 핫키만 직전 조합으로 되돌린다(성공한 다른 핫키의 새 조합은 유지).
  - win `HotkeyManager`: `Hotkey` 레코드 리스트 + 하나의 `WndProc`가 `wParam`(id)로
    라우팅. `Start()`는 실패 id 리스트 반환.
  - 신규 설정 키: `captureHotkeyKeyCode` / `captureHotkeyModifiers`
    (기존 `hotkey*` 명명 관례). 설정 창에 두 번째 레코더 행(라벨: 프롬프트 패널 / 화면 캡쳐).

- **이미지 → LLM (3경로)**: `ChatMessage`에 옵션 이미지 필드 추가
  (mac `imageBase64: String?`, win `ImagePngBase64`). 첫 user 메시지에만 부착하며,
  매 턴 조립된 메시지 배열의 첫 user 턴에 재부착 — multi-turn에서도 이미지 유지
  (prior는 텍스트만 복원되므로). 프로바이더별 content 조립은 **순수 로직**으로 분리:
  `ChatImageContent`(mac `Sources/LLMCore`, win `AnywhereLLM.Core`) — 앱 타겟은 단위
  테스트가 불가해 여기 두고 동일 동작 + 동일 테스트.
  - OpenAI 호환: `content` = `[{type:text},{type:image_url,image_url:{url:"data:image/png;base64,…"}}]`
  - Anthropic: content 블록 `[{type:text},{type:image,source:{type:base64,media_type:"image/png",data:…}}]`
  - Ollama 네이티브: 메시지에 형제 키 `images:[b64]`(raw base64, `data:` 접두 없음), content는 문자열 유지.
  - 응답 파서/스트리밍 무변경(출력은 여전히 텍스트). **비전 미지원 모델 게이팅 없음** —
    서버 에러가 그대로 패널에 노출된다(v1).

- **보기 전용 재사용**: 이미지 컨텍스트는 `isEditable=false`로 만들어 기존 보기 전용
  transcript UX(스트리밍 표시 + 적용/타이핑 없음)를 그대로 탄다. 새 UX 분기 없음.

## 권한 (mac, 새 리스크)

`screencapture -i` 캡쳐 내용을 얻으려면 **화면 기록(Screen Recording, TCC)** 권한이
필요하다(접근성과 별개). `CGPreflightScreenCaptureAccess()`로 확인하고, 없으면
`CGRequestScreenCaptureAccess()`로 요청 + 안내 다이얼로그를 띄운 뒤 이번 캡쳐는 중단
(권한은 앱 재시작 후 적용). Windows는 화면 캡쳐에 별도 권한 불필요.

## 변경 파일

mac: `LLMCore/ChatImageContent.swift`(신규) + `Tests/LLMCoreTests/ChatImageContentTests.swift`(신규),
`ScreenCapture.swift`(신규), `HotkeyManager.swift`(다중 핫키 리팩터),
`AppDelegate.swift`(두 번째 핫키·`captureScreenRegion`·권한 안내),
`TextTarget.swift`(`TargetContext.image`), `LLMClient.swift`(`ChatMessage.imageBase64` + 3경로 분기),
`ConversationController.swift`(이미지 첨부·빈⏎ 게이트), `ConversationView.swift`(썸네일·placeholder),
`SettingsView.swift`(두 번째 레코더), `Resources/*/Localizable.strings`.

win: `AnywhereLLM.Core/ChatImageContent.cs`(신규) + `Core.Tests/Program.cs`(테스트 추가),
`Services/RegionCapture.cs`(신규 오버레이), `Services/HotkeyManager.cs`(다중 핫키),
`Interop/NativeMethods.cs`(`SetWindowPos`), `App.xaml.cs`(두 번째 핫키·`CaptureRegionAndPrompt`),
`Services/TextTargetService.cs`(`TargetContext.Image`), `Services/LlmClient.cs`(`ChatMessage.ImagePngBase64` + 3경로),
`UI/ConversationController.cs`(이미지 첨부·게이트), `UI/PromptWindow.xaml{,.cs}`(썸네일·placeholder),
`UI/SettingsWindow.xaml{,.cs}`(두 번째 레코더), `Services/Localization.cs`(문자열).

## 검증

- mac: `swift build` green, `swift test` 63 pass(ChatImageContent 7 포함).
- win Core: `dotnet run`(Core.Tests) 84 pass(ChatImageContent 10 포함).
- win App(WPF)은 macOS에서 빌드 불가 — Windows 머신에서 빌드·검증 필요.

## 수동 테스트 시나리오 (GUI — 자동 검증 불가)

mac:
1. `⌘⇧2` → 크로스헤어 → 영역 드래그 → 패널에 썸네일 + 입력창. 빈 ⏎(프로필 있음) 또는
   "이 화면 설명해줘" 입력 → 답변 스트리밍.
2. 첫 실행 시 화면 기록 권한 다이얼로그 → 켠 뒤 앱 재시작 → 재시도 시 정상 캡쳐.
   (subprocess 권한 귀속 실측 필요 — 권한 부여 후에도 빈 이미지면 오버레이/ScreenCaptureKit
   방식으로 전환 검토.)
3. 설정에서 화면 캡쳐 핫키를 다른 조합으로 변경 → 즉시 반영. 충돌 조합이면 경고 +
   프롬프트 패널 핫키는 영향 없음.
4. Ollama(비전 모델 llava 등)·OpenAI(gpt-4o)·Anthropic 셋업 토큰 각각으로 이미지 질의 확인.

win:
1. `Ctrl+Shift+2` → 반투명 오버레이 → 드래그 → 패널에 썸네일. Esc/우클릭 취소.
2. 혼합 DPI 다중 모니터에서 crop 영역이 선택과 일치하는지(물리 좌표 정확성) 실측.
3. 설정 두 번째 레코더로 캡쳐 핫키 변경.
