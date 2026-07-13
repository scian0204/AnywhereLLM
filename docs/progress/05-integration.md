# 05 — integration

핫키 → 컨텍스트 캡처 → 패널 대화 UI → 삽입/교체까지 전체 플로우 연결. 앞 단계의
`TextTargetService` / `PromptPanel` / `PanelPositioner` / `LLMClient` 를 하나로 엮는다.

## 파일

```
Sources/AnywhereLLM/ConversationController.swift   # 세션 상태 + 프롬프트 구성 + 스트리밍
Sources/AnywhereLLM/ConversationView.swift         # SwiftUI 대화 UI
Sources/AnywhereLLM/PromptPanel.swift              # NSHostingView로 UI 호스팅 (교체됨)
Sources/AnywhereLLM/AppDelegate.swift              # 캡처-먼저 플로우 + 보안 필드 경고 (수정됨)
```

## 호출 플로우 (텍스트 다이어그램)

```
⌘⇧Space (HotkeyManager)
   │
   ▼
AppDelegate.togglePanel()
   │  패널이 이미 보이면 → orderOut, 종료
   │
   ├─ TextTargetService.captureContext()      ← 패널 표시 "전"에 캡처 (포커스 유지 상태)
   │
   ├─ context.isSecureField == true ?
   │        │yes→ warnSecureField(): NSSound.beep + 메뉴바 아이콘 1초 lock.slash, 패널 미표시, 종료
   │        │no ↓
   │
   ├─ panel.present(context:)                 ← ConversationController 새로 생성, ConversationView를 contentView로
   ├─ panel.setFrameOrigin(PanelPositioner.origin(for:))
   ├─ panel.orderFrontRegardless()            ← 앱 활성화 없이 표시
   ├─ panel.makeKey(); panel.focusInput()
   │
   ▼
[사용자 입력 → ⏎]
   │
   ▼
ConversationController.send(input)
   ├─ transcript에 user + (빈)assistant 추가
   ├─ buildMessages() → LLMClient.streamChat(messages:)
   ├─ 스트림 chunk 들어올 때마다 assistant 엔트리에 append (뷰 자동 스크롤)
   │
   ▼
finishStreaming()
   ├─ applyMode == "immediate" → onApply(result) 즉시
   └─ applyMode == "preview"   → pendingResult 세팅 → [삽입/교체] 버튼 노출
                                    │
                                    ▼ (버튼 클릭 또는 ⌘⏎)
                              controller.applyPending() → onApply(result)
   │
   ▼
PromptPanel.apply(result, into: context)
   ├─ orderOut(nil)                           ← 패널 닫기 (포커스 대상 앱으로 복귀)
   ├─ 0.12s 딜레이 (포커스 복귀 대기)
   └─ TextTargetService.insert(result, into: context)   ← AX 우선, 실패 시 클립보드 ⌘V
```

Esc → `PromptPanel.cancelOperation`: 스트림 취소 + 컨트롤러 해제 + `orderOut`.
패널 인스턴스는 재사용(`isReleasedWhenClosed = false`), 세션(컨트롤러/대화 히스토리)만 매 오픈마다 리셋.

## 프롬프트 구성 규칙

**메시지 배열** = `[system]` + 이전 완료된 턴들 + `[user(최신)]`.

### system 메시지 (`systemContent()`)
아래를 `\n\n` 로 연결(빈 항목은 생략):
1. 전역 `systemPrompt` (UserDefaults, 비어있으면 생략).
2. `includeAppName`(기본 true)이고 앱 이름 있으면: `사용자는 "{appName}" 앱에서 텍스트를 작성 중입니다.`
3. 출력 규율 (모드별 분리):
   - **선택 있음(교체 모드)**: "선택한 텍스트를 지시에 따라 편집… 선택 영역을 대체할 텍스트만 출력, 설명/인사말 금지."
   - **선택 없음(삽입 모드)**: "커서 위치에 삽입될 텍스트만 출력, 설명/인사말 금지."

### user 메시지 (`userContent()`)
- **첫 턴에만** 컨텍스트 폴딩:
  - 선택 텍스트 있으면 `[선택한 텍스트]\n…` 블록.
  - 없고 `includeFullText`(기본 false)면 `[현재 필드 전체 내용]\n…` 블록.
  - 마지막에 `[요청]\n{사용자 입력}`.
- **2번째 턴 이후**: 사용자 입력 원문만 (multi-turn 은 히스토리로 문맥 유지).

## 설정 키 전체 목록 (UserDefaults, 기본값 하드코딩 — 6단계 UI가 노출)

| 키 | 타입 | 기본값 | 의미 | 소유 |
|----|------|--------|------|------|
| `applyMode` | String | `"preview"` | `"preview"`=버튼 확정 / `"immediate"`=스트림 완료 즉시 삽입 | ConversationController |
| `includeAppName` | Bool | `true` | system 프롬프트에 대상 앱 이름 포함 | ConversationController |
| `includeFullText` | Bool | `false` | 선택 없을 때 필드 전체 내용을 첫 user 메시지에 포함 | ConversationController |
| `systemPrompt` | String | `""` | 사용자 전역 지시 (system 롤 맨 앞) | ConversationController |
| `panelPosition` | String | `"caret"` | `caret`/`mouse`/`center` — 패널 위치 | PanelPositioner (2단계) |
| `hotkeyKeyCode` | Int | `kVK_Space` | 핫키 virtual key code | HotkeyManager (2단계) |
| `hotkeyModifiers` | Int | `cmdKey\|shiftKey` | 핫키 Carbon modifier 마스크 | HotkeyManager (2단계) |
| `llm.baseURL` | String | `https://api.openai.com/v1` | OpenAI 호환 base URL | LLMClient (4단계) |
| `llm.model` | String | `gpt-4o-mini` | 모델명 | LLMClient (4단계) |

**Keychain** (설정 UI가 쓰기): service `kr.scian0204.AnywhereLLM` / account `apiKey` — API 키 (`KeychainStore`).

에러 표시: `LLMError.missingAPIKey` → "API 키가 설정되지 않았습니다. 설정에서 키를 입력하세요." (LLMError.errorDescription 그대로 뷰의 빨간 텍스트로 노출).

## UI 동작 요약

- 상단: 선택 텍스트 있으면 2줄 클램프 미리보기 (회색 배경).
- 중앙: transcript 스크롤 (max 280pt), user 우측/assistant 좌측 버블, 스트리밍 중 빈 응답은 "…", 최신 항목으로 자동 스크롤.
- 하단: 입력창(1~6줄 자동 확장, ⏎ 전송, ⇧⏎ 줄바꿈), 스트리밍 중 스피너.
- pendingResult 있으면 `[삽입 (⌘⏎)]` / `[교체 (⌘⏎)]` 버튼 (선택 유무로 라벨 분기).
- 에러는 입력창 위 빨간 텍스트.

## 검증 결과 (자동)

- `swift build` 성공, 경고 0.
- `swift test` 성공 (LLMCore 5 케이스 유지).
- `make` 성공 — `.app` 번들 재조립 + ad-hoc 서명.
- 프롬프트 구성 로직(첫 턴 폴딩 / 2턴 이후 원문 / includeFullText 분기 / hasSelection) 독립 self-check 통과.

## 수동 테스트 시나리오 (GUI 실측, 에이전트 불가)

전제: `make run` 실행 + 접근성 권한 허용 + Keychain에 유효한 API 키 저장
(`KeychainStore.set("sk-...")` 또는 6단계 설정 UI).

1. **선택 없음 삽입** — TextEdit 새 문서에 캐럿만 두고 ⌘⇧Space → 패널이 캐럿 아래 표시,
   "이메일 인사말 써줘" 입력 ⏎ → 응답 스트리밍 → [삽입] (또는 ⌘⏎) → 패널 닫히고 캐럿 위치에 결과 삽입.
2. **선택 교체** — TextEdit에서 문장 선택 후 ⌘⇧Space → 패널 상단에 선택 미리보기(2줄),
   "더 정중하게" 입력 → 응답 → [교체] → 선택이 결과로 대체.
3. **multi-turn** — 위 상태에서 삽입 안 하고 "더 짧게" 다시 입력 → 이전 대화 문맥 유지한 채 새 응답.
   Esc로 닫았다 다시 열면 대화 초기화(히스토리 없음) 확인.
4. **보안 필드 차단** — Safari 로그인 폼 비밀번호 칸 포커스 후 ⌘⇧Space →
   패널 안 뜨고 비프음 + 메뉴바 아이콘이 1초간 lock.slash 로 바뀜. 아무 텍스트도 캡처/삽입 안 됨.
5. **immediate 모드** — `defaults write kr.scian0204.AnywhereLLM applyMode immediate` 후 재실행.
   응답 스트리밍 완료 즉시 패널 닫히고 자동 삽입(버튼 없음).
6. **포커스 유지** — 패널에 타이핑하는 동안 대상 앱이 frontmost 유지, 메뉴바가 우리 앱으로 안 바뀌는지 (2단계 리스크 재확인).
7. **에러 표시** — Keychain에 키 없이 전송 → "API 키가 설정되지 않았습니다…" 빨간 텍스트.
8. **AX 폴백 앱** — VSCode/Slack(Electron)에서 삽입 → AX 실패 시 클립보드 ⌘V 폴백, 클립보드 원상복구 확인 (3단계 참조).

## 6단계 settings-ui 가 노출해야 할 설정 키

위 "설정 키 전체 목록" 표 전체 + Keychain API 키 입력.
UI 우선순위: API 키(Keychain), `llm.baseURL`, `llm.model`, `systemPrompt`, `applyMode`,
`includeAppName`, `includeFullText`, `panelPosition`, `hotkeyKeyCode`/`hotkeyModifiers`(핫키 레코더).
AppDelegate의 "설정…" 메뉴 항목은 현재 `isEnabled = false` — 6단계에서 활성화 + 창 오픈 액션 연결.
