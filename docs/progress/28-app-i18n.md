# 28 — 앱 UI 다국어 처리 (영어/한국어)

## 목표

시스템 언어에 따라 앱 UI가 영어/한국어로 표시되도록 한다. 지원 외 언어는 영어 폴백.

## 방식

네이티브 `.lproj` + `Localizable.strings` — 언어 매칭·폴백·앱별 언어 설정(시스템 설정 >
일반 > 언어 및 지역 > 응용 프로그램)을 전부 OS가 처리한다. 커스텀 언어 감지 코드 없음.

- `Package.swift`: `defaultLocalization: "en"` — SPM이 `Sources/AnywhereLLM/Resources/`의
  `en.lproj`/`ko.lproj`를 자동 감지해 리소스 번들(`AnywhereLLM_AnywhereLLM.bundle`)로 빌드.
- `L10n.swift`: `L(_ key:)` / `L(_ key:, _ args...)` — `NSLocalizedString(bundle: .module)`
  래퍼 2개. SwiftUI `Text(String)` 오버로드로 들어가므로 이중 조회 없음.
- 소스 6개 파일의 사용자 노출 리터럴 65키 치환: SettingsView, ConversationView,
  ConversationController(LLM 프롬프트 구성 문자열 포함 — 시스템 언어로 LLM에 지시),
  LLMClient(오류 메시지), AppDelegate(메뉴바/편집 메뉴), SettingsWindowController(창 제목).
- 의도적 비대상: "Base URL", "LLM", "⌘P", 키 이름(Space/Return 등) — 언어 중립 기술 용어.
- `Makefile` bundle 타깃: `cp -R $(dir $(BIN))AnywhereLLM_AnywhereLLM.bundle` →
  `Contents/Resources/`. `$(dir $(BIN))` 기준이라 `make app`(release)과
  `make dist`(universal, `.build/apple/Products/Release/`) 모두 동일하게 동작.
  **복사 실패 시 빌드가 죽어야 한다** — 번들 없이 실행되면 `Bundle.module`이
  fatalError로 앱이 즉사하므로 `|| true` 금지.
- `Resources/Info.plist`: `CFBundleDevelopmentRegion`(en) + `CFBundleLocalizations`(en, ko)
  — 앱별 언어 오버라이드 UI 노출용.

## 검증 (자동)

- `swift build` / `make` / `make dist`(리뷰 에이전트 실측) / `swift test` 25개 통과.
- en/ko 키 집합 diff 일치 (65키), 두 .strings 모두 plist 파싱 정상.
- 빌드된 .app 번들에서 언어별 조회 실측: en→"Quit", ko→"종료",
  `preferredLocalizations` ko 사용자→ko, ja 사용자→en 폴백.
- 포맷 지정자(%@/%d) 순서·타입 en/ko 동일 — 콜사이트 타입과 대조 완료.

## 수동 테스트 필요 (GUI — 자동 검증 불가)

1. 시스템 언어 한국어 상태에서 `make run` → 메뉴바 메뉴·설정 창·패널 전부 한국어.
2. 시스템 설정 > 일반 > 언어 및 지역 > 응용 프로그램 > AnywhereLLM = English 지정 후
   재실행 → 전부 영어.
3. 영어 상태에서 선택 없는 편집 필드 → 패널 placeholder 영어, 응답 프롬프트 지시가
   영어로 나가는지 (LLM 응답 언어 확인).

## 알려진 제약

- 기존 설치 사용자가 이미 저장한 "기본" 프로필 이름은 업그레이드 후에도 유지된다
  (프로필은 UserDefaults JSON으로 영속 — 마이그레이션 시점 언어로 1회 생성). 코스메틱,
  이름변경으로 해결 가능.
- LLM 프롬프트 구성 문자열도 로컬라이즈 대상에 포함 — 다국어 추가 시 `.strings`에
  `prompt.*` 키 번역 필수 (빠지면 en 폴백이라 동작엔 문제 없음).
