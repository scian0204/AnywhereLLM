# 01 — scaffold

메뉴바 상주 앱의 골격. SPM executable → `.app` 번들 조립 → 접근성 권한 플로우.

## 구현 내용

- **SPM executable 패키지** (`Package.swift`, swift-tools-version 6.0, 외부 의존성 0, macOS 14+).
- **메뉴바 앱** — AppKit 수동 부트스트랩(`main.swift`), 스토리보드/xib 없음.
  - `NSStatusItem` + SF Symbol 아이콘(`bubble.left.and.text.bubble.right`).
  - 메뉴: "설정…"(disabled, 자리만), "종료"(⌘Q).
  - Dock 아이콘 없음: 런타임 `setActivationPolicy(.accessory)` + 번들 `LSUIElement=true`.
- **접근성 권한 플로우** (`AppDelegate.swift`)
  - 시작 시 `AXIsProcessTrustedWithOptions(prompt: true)`로 확인/요청.
  - 미허용 시 메뉴에 "접근성 권한 필요" 항목 표시 → 클릭 시 `x-apple.systempreferences:...Privacy_Accessibility` 열고 재프롬프트.
  - `Timer` 5초 폴링(`prompt: false`)으로 허용되면 메뉴 갱신.
- **.app 번들 빌드** (`Makefile`)
  - `swift build -c release` → `build/AnywhereLLM.app/Contents/{MacOS,Resources}` 조립.
  - `Resources/Info.plist` 복사(파일로 관리), `codesign --force --sign - --options runtime` ad-hoc 서명.
  - `make run` = 빌드 후 `open`.

## 파일 구조

```
Package.swift
Makefile
Resources/Info.plist               # CFBundleIdentifier=kr.scian0204.AnywhereLLM, LSUIElement=true
Sources/AnywhereLLM/
  main.swift                       # NSApplication 부트스트랩
  AppDelegate.swift                # 메뉴바 + 접근성 권한
docs/progress/01-scaffold.md
```

## 빌드 / 실행

```bash
swift build              # 개발 빌드
make                     # release 빌드 + .app 번들 조립 + ad-hoc 서명
make run                 # 위 + open
make clean               # 산출물 정리
```

## 검증 결과 (자동)

- `swift build` 성공 (경고 0).
- `make` 성공 — 번들 구조/서명 확인:
  - `Contents/MacOS/AnywhereLLM`, `Contents/Info.plist`, `Contents/_CodeSignature/` 생성.
  - `codesign -dv`: `Identifier=kr.scian0204.AnywhereLLM`, `flags=0x10002(adhoc,runtime)`.
  - `Info.plist`: `LSUIElement=true`, `CFBundleIdentifier=kr.scian0204.AnywhereLLM`.

## 사용자 수동 확인 필요 (GUI 실측, 에이전트 불가)

1. `make run` 후 메뉴바에 아이콘 표시 + Dock 아이콘 없음 확인.
2. 첫 실행 시 접근성 권한 다이얼로그 표시 확인.
3. "접근성 권한 필요" 클릭 → 시스템 설정의 개인정보 보호 > 손쉬운 사용 창이 열리는지 확인.
4. 권한 허용 후 5초 이내 메뉴에서 "접근성 권한 필요" 항목이 사라지는지 확인.
   - 참고: ad-hoc 서명은 재빌드 시 서명 해시가 바뀌어 TCC 권한이 초기화될 수 있음. 개발 중엔 재허용 필요할 수 있음.

## 다음 단계 인터페이스 (이어받는 지점)

- 진입점: `Sources/AnywhereLLM/AppDelegate.swift` — `applicationDidFinishLaunching`.
- `hasAccessibility: Bool` 및 `requestAccessibility(prompt:)` / `refreshAccessibility()`에 권한 상태가 모임.
  글로벌 핫키(단계 2)는 권한 확보 후 등록하는 흐름으로 `AppDelegate`에서 훅.
- `rebuildMenu()`에 메뉴 항목 추가. "설정…"은 현재 disabled — 단계 6(settings-ui)에서 활성화.
- 패널/핫키/AX/LLM 매니저는 별도 파일로 추가하고 `AppDelegate`가 소유하는 구조 권장.
