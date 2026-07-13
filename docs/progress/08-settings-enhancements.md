# 08 — settings-enhancements

사용자 실측 피드백 3건 반영. 설정창 텍스트 편집 단축키, 모델 목록 가져오기,
시스템 프롬프트 프로필.

## 파일

```
Sources/AnywhereLLM/AppDelegate.swift   # NSApp.mainMenu에 App+Edit 메뉴 설치 (수정)
Sources/AnywhereLLM/LLMClient.swift     # fetchModels() 추가 (수정)
Sources/AnywhereLLM/SettingsView.swift  # 모델 가져오기 UI + 프롬프트 프로필 (수정)
```

## 1. 설정창 ⌘A/⌘C/⌘V (Edit 메뉴)

accessory 앱은 기본 mainMenu가 없어 표준 편집 셀렉터(cut:/copy:/paste:/selectAll:/
undo:/redo:)가 first responder로 라우팅되지 않음 → 텍스트필드에서 단축키 무동작.

`AppDelegate.installMainMenu()`가 `applicationDidFinishLaunching`에서 최소 메뉴 설치:
- 첫 항목: 빈 App 메뉴 슬롯 (형식상 필요).
- Edit 메뉴: 실행 취소(⌘Z)/다시 실행(⌘⇧Z)/잘라내기(⌘X)/복사(⌘C)/붙여넣기(⌘V)/
  전체 선택(⌘A) — 전부 표준 셀렉터 + 표준 키 이퀴벌런트.

메뉴바에는 안 보이지만(accessory) 키 라우팅은 동작. 기존 로직은 건드리지 않고
`installMainMenu()` 호출 1줄 + 메서드 1개만 추가.

## 2. 모델 가져오기

`LLMClient.fetchModels() async throws -> [String]`:
GET `{baseURL}/models`, `Authorization: Bearer {키}`, 응답 `data[].id`를 정렬해 반환.
키 없으면 `LLMError.missingAPIKey`, 비200이면 `LLMError.http`.

SettingsView LLM 섹션:
- 모델 TextField 옆에 [모델 가져오기] 버튼.
- 성공 시 "가져온 모델" Picker 표시 (선택 시 TextField에 채움 — TextField가 계속
  source of truth). 로컬 서버 등 `/models` 없는 경우 직접 입력 계속 가능.
- 실패 시 빨간 한 줄 에러 (errorDescription).
- 비어있으면 "모델 목록이 비어 있습니다." 표시.

## 3. 프롬프트 프로필

이름 있는 시스템 프롬프트 여러 개 저장/전환.

### 저장 구조

| 키 | 타입 | 내용 |
|----|------|------|
| `promptProfiles` | Data (JSON) | `[{name, prompt}]` — `PromptProfile` 배열 인코딩 |
| `activeProfile` | String | 활성 프로필 이름 |
| `systemPrompt` | String | **미러링** — 활성 프로필 prompt를 계속 여기에 씀 |

`ConversationController`는 기존대로 `systemPrompt` 키만 읽음 (수정 불필요).
프로필 전환/편집 시마다 활성 prompt를 `systemPrompt`에 미러링.

### 마이그레이션 (하위호환)

`promptProfiles`가 없고(또는 빈 배열) 기존 `systemPrompt`만 있으면 → 그 값을 담은
"기본" 프로필 1개 생성. 최초 `loadProfiles()`에서 처리.

### UI

시스템 프롬프트 섹션:
- 프로필 Picker + [추가]/[이름변경]/[삭제] 버튼 (삭제는 2개 이상일 때만 활성).
- TextEditor는 활성 프로필 prompt 편집 (`activePromptBinding` — 매 키 입력 시 저장+미러).
- 이름변경/이름중복은 `NSAlert` 텍스트 입력 + `uniqueName()`(중복 시 " 2", " 3" 접미).

## 검증 결과 (자동)

- `swift build` 성공, 경고 0.
- `swift build -c release` 성공, 경고 0 (수정 3파일 강제 재컴파일).
- `make` 성공 — `.app` 재조립 + ad-hoc 서명.
- 프로필 로직 self-check 통과 (마이그레이션 / uniqueName 충돌 / JSON 왕복).
  (`swift test`는 LLMCore 타깃 전용이고 이번 변경은 GUI/앱 타깃이라 무관 — 기존 5케이스 유지.)

## 수동 확인 항목 (GUI 실측, 에이전트 불가)

전제: `make run`.

1. **Edit 단축키** — 설정창 TextField/TextEditor에서 ⌘A/⌘C/⌘V/⌘X/⌘Z 동작.
2. **모델 가져오기** — 유효한 키/baseURL로 [모델 가져오기] → Picker에 모델 목록,
   선택 시 TextField 반영. 잘못된 키 → 빨간 에러. `/models` 없는 서버 → 에러 뜨지만
   TextField 직접 입력은 계속 가능.
3. **프로필** — [추가]로 새 프로필 → 이름 자동 부여, TextEditor 편집 → 전환 시 내용 보존.
   [이름변경] NSAlert. [삭제]는 1개 남으면 비활성. 앱 재시작 후 활성 프로필/내용 유지.
4. **미러링 확인** — 프로필 전환 후 패널 열어 해당 시스템 프롬프트가 적용되는지
   (`defaults read kr.scian0204.AnywhereLLM systemPrompt`로 활성 prompt 확인 가능).
5. **마이그레이션** — 기존 `systemPrompt`만 있던 사용자: 첫 실행 시 "기본" 프로필로 이관.
