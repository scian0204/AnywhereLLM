# 23 — 패널 프로필 드롭다운 (⌘P 키보드 전용 전환)

## 목표

패널 상단에 프롬프트 프로필 드롭다운을 추가해, 설정 창을 열지 않고 패널에서
실시간으로 프로필을 전환한다. 마우스 없이 ⌘P → ↑↓ → ⏎만으로 조작 가능해야 한다.

## 설계

### 프로필 저장소 공용화 (SettingsView.swift)

프로필 load/활성 판정/미러 로직이 SettingsView의 private 메서드에 갇혀 있었다.
`PromptProfile` extension의 static 헬퍼로 추출:

- `loadAll()` — `promptProfiles` 디코드, 없으면 레거시 `systemPrompt`를 "기본" 프로필로.
- `activeName(in:)` — 저장된 `activeProfile`이 목록에 있으면 그것, 아니면 첫 프로필.
- `setActive(_:in:)` — `activeProfile` 저장 + 해당 프롬프트를 `systemPrompt`로 미러.

SettingsView는 기존 메서드가 이 헬퍼들에 위임하도록 변경 (동작 동일).
`mirrorKey = "systemPrompt"`는 `ConversationController.systemPromptKey`와 값이 같지만
그쪽은 @MainActor 격리 static이라 비격리 컨텍스트에서 참조 불가 — 리터럴 유지.

### 패널 UI (ConversationView.swift)

- body 최상단에 `profileRow` 추가 (insert/select 모드 공통): 드롭다운 + "⌘P" 힌트.
- 패널 present마다 `onAppear`에서 프로필 목록/활성 이름을 새로 로드 — 설정 창에서
  프로필을 바꿔도 다음 패널부터 반영.
- 선택 변경 → `onChange`에서 `setActive` 즉시 미러. ConversationController가
  send마다 `systemPrompt`를 읽으므로 **다음 전송부터** 새 프로필 적용 (컨트롤러 무변경 —
  프로필 개념을 모르는 구조 유지).

### 상단 여백 재사용 (PromptPanel.swift)

패널의 "상단 여백"은 숨긴 타이틀바(.titled + .fullSizeContentView)가 만드는
safe area(~28px)였다 — NSHostingView가 기본으로 이를 피해 배치해서, 프로필 행을
그냥 추가하면 여백 아래로 붙어 패널만 높아진다. `hosting.safeAreaRegions = []`로
safe area를 제거해 콘텐츠가 창 최상단부터 시작하게 했다 — 드롭다운 행이 원래
비어 있던 그 자리를 차지하고 전체 높이는 이전과 거의 같다.

### 키보드 전용 조작 — NSPopUpButton 채택 이유

SwiftUI `Picker(.menu)`는 프로그램적으로 열 수 없다. AppKit `NSPopUpButton`을
NSViewRepresentable로 감싸고:

- 투명 SwiftUI Button의 `.keyboardShortcut("p", modifiers: .command)`가
  `performClick()`을 호출해 메뉴를 연다 (PopUpProxy가 약한 참조로 연결).
  NSButton `keyEquivalent`는 NSPopUpButtonCell에서 동작이 불확실해 쓰지 않았다.
- 열린 NSMenu는 first responder와 무관하게 ↑↓·⏎·타이핑 검색을 네이티브 지원.
- `refusesFirstResponder = true` — 패널 표시 시 입력 필드 포커스 유지, Tab 순환 제외.
- 투명 버튼은 `allowsHitTesting(false)` — 팝업 클릭을 가로채지 않는다.

## 수동 테스트 (사용자 실측 필요)

1. 핫키로 패널 표시 → 상단에 드롭다운 + ⌘P 힌트 보이고, 입력 필드에 포커스 유지 확인.
2. **⌘P → ↑↓ → ⏎** 로 프로필 전환 (마우스 금지). 특히 **앱이 비활성(nonactivating
   패널)인 상태에서 열린 메뉴가 화살표 키를 받는지** — 이 조합이 유일한 불확실 지점.
3. 프로필 전환 후 전송 → 새 프로필의 시스템 프롬프트가 적용되는지 (프로필별 응답 차이).
4. 메뉴 열고 Esc → 메뉴만 닫히고 패널은 유지되는지.
5. 마우스 클릭으로도 드롭다운 동작 확인.
6. 설정 창 프로필 피커와 상호 반영: 패널에서 바꾼 활성 프로필이 설정 창(재오픈)에
   반영되는지, 그 반대도.
7. insert 모드(선택 없음 + 즉시 반영)에서도 드롭다운 표시·동작 확인.

## 한계

- 드롭다운 폭은 intrinsic size(`.fixedSize()`) — 아주 긴 프로필 이름은 패널 폭(460)을
  밀어낼 수 있다. 문제 되면 maxWidth + truncation 추가.
- 패널이 열려 있는 동안 설정 창에서 프로필을 추가/삭제해도 열린 패널 목록엔 미반영
  (다음 present에 반영). 실사용상 무해해 갱신 옵저버는 생략.
