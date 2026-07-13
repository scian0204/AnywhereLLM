# 06 — settings-ui

메뉴바 "설정…" → SwiftUI 설정 창. 앞 단계에서 UserDefaults/Keychain 기본값으로만
동작하던 설정을 GUI로 노출한다.

## 파일

```
Sources/AnywhereLLM/SettingsView.swift              # SwiftUI Form (신규)
Sources/AnywhereLLM/SettingsWindowController.swift  # 싱글턴 NSWindow 래퍼 (신규)
Sources/AnywhereLLM/AppDelegate.swift               # "설정…" 활성화 + 핫키 재등록 콜백 (수정)
```

## 창 동작

- 일반 `NSWindow` (titled/closable/miniaturizable) — non-activating 패널이 아님.
- 싱글턴: 재클릭 시 기존 창을 `makeKeyAndOrderFront`로 앞으로 (새 창 안 만듦).
- 앱이 `.accessory`라 `NSApp.activate(ignoringOtherApps:)`를 창 표시 전에 호출 —
  안 하면 창이 다른 앱 뒤에 뜸.
- `isReleasedWhenClosed = false` — 닫아도 인스턴스 유지, 재사용.

## 설정 항목 ↔ 키 매핑

| UI 항목 | 저장소 | 키 | 타입 | 기본값 |
|---------|--------|-----|------|--------|
| Base URL (TextField) | @AppStorage | `llm.baseURL` | String | `https://api.openai.com/v1` |
| 모델 (TextField) | @AppStorage | `llm.model` | String | `gpt-4o-mini` |
| API 키 (SecureField) | Keychain | service `kr.scian0204.AnywhereLLM` / account `apiKey` | String | (없음) |
| 결과 반영 (Picker) | @AppStorage | `applyMode` | String | `preview` |
| 패널 위치 (Picker) | @AppStorage | `panelPosition` | String | `caret` |
| 대상 앱 이름 포함 (Toggle) | @AppStorage | `includeAppName` | Bool | `true` |
| 필드 전체 내용 포함 (Toggle) | @AppStorage | `includeFullText` | Bool | `false` |
| 시스템 프롬프트 (TextEditor) | @AppStorage | `systemPrompt` | String | `""` |
| 핫키 (녹화 버튼) | @AppStorage | `hotkeyKeyCode` | Int | `kVK_Space` |
| 핫키 (녹화 버튼) | @AppStorage | `hotkeyModifiers` | Int | `cmdKey\|shiftKey` |
| 로그인 시 시작 (Toggle) | SMAppService.mainApp | (OS 등록) | — | 현재 등록 상태 |

- `includeFullText` on 시 "포커스된 필드 전체 내용이 API로 전송됩니다." 경고 문구 표시.
- API 키: @AppStorage 아님. `onAppear`에 `KeychainStore.get()` 로드,
  `onChange`/`onSubmit`에 `KeychainStore.set()` 저장.

## 핫키 녹화

- 녹화 버튼 → `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` 설치.
- 수정자 1개 이상 있는 키 조합만 캡처 (맨키 방지). 캡처 즉시 모니터 제거.
- NSEvent modifier flags → Carbon 마스크 변환 (`carbonModifiers`) 후 저장 —
  HotkeyManager가 Carbon 마스크로 등록하므로 형식 일치.
- 캡처 후 `onHotkeyChanged` 콜백 → AppDelegate가 `hotkeyManager.stop()`+`start()` 재등록.
  (HotkeyManager.start()가 UserDefaults에서 매번 새로 읽음 → 별도 재등록 메서드 불필요.)
- 현재 핫키는 `⌘⇧Space` 형식 문자열로 표시 (`modifierSymbols` + `keyName`).

## 검증 결과 (자동)

- `swift build` 성공, 경고 0.
- `swift build -c release` 성공, 경고 0 (신규/수정 3파일 강제 재컴파일 확인).
- `swift test` 성공 (LLMCore SSE 5 케이스 유지).
- `make` 성공 — `.app` 번들 재조립 + ad-hoc 서명.

## 수동 확인 항목 (GUI 실측, 에이전트 불가)

전제: `make run` 실행.

1. **창 열림/포커스** — 메뉴바 "설정…" 클릭 → 창이 다른 앱 앞으로 뜨는지
   (`.accessory` 앱 활성화 확인). 다시 클릭 시 새 창 안 뜨고 기존 창 앞으로.
2. **API 키 Keychain 왕복** — SecureField에 키 입력 후 창 닫기 → 재오픈 시 값 유지
   (`security find-generic-password -s kr.scian0204.AnywhereLLM -a apiKey` 로 저장 확인 가능).
3. **핫키 녹화** — "녹화" 클릭 → 예: ⌃⌥K 입력 → 표시가 `⌃⌥K`로 바뀌고 즉시 새 핫키로
   패널이 열리는지 (기존 ⌘⇧Space는 더 이상 안 열림). 맨키(수정자 없이)는 무시되는지.
4. **로그인 시 시작** — Toggle on → 시스템 설정 > 일반 > 로그인 항목에 AnywhereLLM 등장.
   Toggle off → 사라짐. (ad-hoc 서명이라 등록 실패 가능 — 실패 시 Toggle이 원상복귀됨.)
5. **includeFullText 경고** — Toggle on 시 주황색 경고 문구 노출.
6. **각 설정 반영** — applyMode/panelPosition 변경 후 패널 열어 동작 확인
   (05 수동 시나리오와 연계).

## 알려진 제약

- 로그인 시 시작은 `SMAppService.mainApp` (macOS 13+). ad-hoc 서명 개인 빌드에서는
  등록이 거부될 수 있음 — 정식 서명/공증 배포 시 정상 동작. 실패는 로그로만 남고
  Toggle은 실제 상태로 되돌아감.
- 핫키 키 이름은 Space/Return/Tab/Esc/A–Z만 친숙한 이름, 그 외는 `key 0xNN` hex 표시.
