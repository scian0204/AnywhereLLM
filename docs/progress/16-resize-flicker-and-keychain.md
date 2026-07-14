# 16 — resize-flicker-and-keychain

15의 layout()+fittingSize 리사이즈 도입 후 사용자 보고 2건:
1. 높이가 틱 단위로 미세하게 바뀌며 깜빡임.
2. 쓸 때마다 맥 비밀번호 요구.

## 1. 리사이즈 진동 (깜빡임)

1차 가설(소수점 반올림, ceil+허용오차)은 **오진** — 헤드리스 재현으로 반증:
오프스크린 패널 + 실제 구성 복제 시 **120↔140 정수 진동, 3.5초에 16,168회
리사이즈**. 반올림과 무관.

실측으로 규명한 진짜 매커니즘:
- NSHostingView **기본** sizingOptions(.standardBounds)는 autolayout 제약으로
  창을 SwiftUI 콘텐츠 크기에 자동 추종시킨다 — 단, 루트 뷰가
  `.fixedSize(vertical)`로 intrinsic 높이를 노출할 때만.
- 원래 코드의 `sizingOptions = [.preferredContentSize]`가 이 기본 제약을
  **제거**해서 창이 안 자랐던 것 (14에서 보고된 최초 증상의 뿌리).
- 15의 layout() 훅 + 수동 `setFrame`은 기본 옵션을 복원하면서 **autolayout과
  수동 리사이즈가 서로 싸우는** 구조를 만듦 → 무한 진동 = 깜빡임.

최종 구조 (실측: 콘텐츠 변경당 리사이즈 정확 1회, 진동 0):
- `ConversationView`에 `.fixedSize(horizontal: false, vertical: true)` 추가.
- `PromptPanel`: PanelHostingView/onLayout/resizeToFit **전부 삭제** — 플레인
  NSHostingView + 기본 sizingOptions. **수동 리사이즈 금지** (autolayout과 싸움).
- 성장 방향도 네이티브가 이미 상단 고정·아래 성장 (실측: maxY 불변,
  92→140→…→332). didResize 옵저버(keepAnchoredOnScreen)는 화면 클램프
  안전망으로만 유지 — origin만 만지므로 제약과 충돌 없음.

## 2. 키체인 암호 프롬프트

원인 조합:
- 키체인 항목(service `kr.scian0204.AnywhereLLM`, account `apiKey`)이
  예전 서명(ad-hoc 시절) 바이너리 소유로 생성됨 — 레거시 키체인 ACL은
  소유 앱 서명 불일치 시 읽기마다 암호를 요구.
- `LLMClient.streamChat`이 요청마다 `KeychainStore.get()` 호출 → 매 전송마다 프롬프트.
- 기존 `set()`은 `SecItemUpdate` — **기존 항목의 ACL을 그대로 보존**하므로
  설정에서 키를 다시 저장해도 안 고쳐졌다.

수정 (`KeychainStore.set`):
- 빈 값 → `delete()` — 로컬 서버(Ollama)는 키가 없으니 항목 자체를 없애
  프롬프트를 원천 차단.
- 비어있지 않으면 삭제 후 `SecItemAdd` — 현재 바이너리 소유의 새 ACL.

추가 (사용자 조치 불필요화): `AppDelegate` 시작 시 재소유 마이그레이션 —
`get()` 한 번 읽어 `set()`으로 재저장 (빈 값이면 삭제). 키체인 항목 실측:
cdat 2026-07-13(ad-hoc 시절 생성), 이후 SecItemUpdate만 돼서 ACL이 계속
낡아 있었음. 첫 실행에서 암호 프롬프트가 한 번 뜰 수 있고(허용하면) 그걸로 끝.

## 빌드 스탬프

"수정했는데 그대로"가 반복될 때 옛 바이너리 실행 여부를 배제할 수단이 없었다.
Makefile이 번들 Info.plist의 CFBundleVersion을 빌드 시각(`yymmdd.HHMMSS`)으로
스탬프하고, 메뉴바 메뉴 하단에 "빌드 NNNNNN.NNNNNN" 비활성 항목으로 표시.

## 검증

- 헤드리스 실측 (오프스크린 NSPanel + 동일 구성): 기존 구조 16,168회 진동 재현
  → 최종 구조 리사이즈 5/5회(틱당 1회) 수렴, 상단 고정 확인.
- `swift build` 경고 0, `make` 성공, 스탬프 확인(260714.132723). LLMCore 무변경.
- GUI/키체인 실측 필요: (1) 메뉴바에서 빌드 스탬프가 최신인지 먼저 확인,
  (2) 미리보기 스트리밍 중 패널이 깜빡임 없이 자라는지, (3) 첫 실행 키체인
  프롬프트 허용 후 전송 시 프롬프트 재발 없는지.
