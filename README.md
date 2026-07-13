# AnywhereLLM

macOS 메뉴바 상주 앱. 어떤 앱에서든 글로벌 핫키(기본 `⌘⇧Space`)로 포커스를 뺏지 않는
패널을 띄워, LLM 응답을 현재 포커스된 텍스트박스에 삽입하거나 선택한 텍스트를 교체한다.

## 주요 기능

- **글로벌 핫키** — 어떤 앱 위에서든 `⌘⇧Space`로 패널 호출 (설정에서 변경 가능)
- **포커스 유지 패널** — 패널이 키 입력을 받아도 대상 앱이 frontmost 유지
- **삽입 모드** — 선택 텍스트가 없으면 LLM 응답을 대상 텍스트박스에 실시간 스트리밍 타이핑
- **선택 모드** — 텍스트를 선택한 상태면 미리보기 + multi-turn 대화 후 교체
- **OpenAI 호환 API** — chat completions SSE 스트리밍, `<think>` 태그 자동 필터
- **프롬프트 프로필** — 용도별 시스템 프롬프트 저장/전환
- **보안** — 비밀번호 필드(보안 텍스트필드) 감지 시 캡처/삽입 전면 차단, API 키는 키체인 저장
- **의존성 0** — 외부 패키지 없이 AppKit/SwiftUI만 사용

## 요구 사항

- macOS (Apple Silicon/Intel)
- Swift 툴체인 (Xcode Command Line Tools)
- 손쉬운 사용(Accessibility) 권한 — 첫 실행 시 안내

## 빌드 및 실행

```bash
make            # release 빌드 + build/AnywhereLLM.app 조립 + 서명
make run        # 빌드 후 실행
swift build     # 컴파일만 (디버그)
swift test      # LLMCore 단위 테스트
```

재빌드 시 접근성 권한이 초기화되지 않으려면 자가서명 인증서를 1회 생성:

```bash
scripts/make-signing-cert.sh
```

권한이 꼬였을 때 초기화:

```bash
tccutil reset Accessibility kr.scian0204.AnywhereLLM
```

## 사용법

1. 메뉴바 아이콘에서 설정을 열어 API 엔드포인트/모델/API 키 입력 (OpenAI 호환 서버 지원)
2. 아무 앱의 텍스트박스에 커서를 두고 `⌘⇧Space`
3. 프롬프트 입력 → 응답이 그 자리에 타이핑됨
4. 텍스트를 선택한 상태로 호출하면 교체 모드 (미리보기 후 적용)

## 아키텍처

타겟 2개: `AnywhereLLM`(executable, AppKit) + `LLMCore`(테스트 가능한 순수 로직 라이브러리).

| 파일 | 책임 |
|---|---|
| `HotkeyManager` | Carbon 글로벌 핫키 등록 |
| `AppDelegate` | 메뉴바, 접근성 권한, 핫키 → 패널 토글 |
| `TextTarget` | 대상 앱 텍스트 I/O (AX API → 클립보드 폴백 → 키 타이핑 스트리밍) |
| `PromptPanel` | 포커스를 뺏지 않는 NSPanel (`.nonactivatingPanel`) |
| `ConversationController/View` | 삽입/선택 모드 분기, transcript |
| `LLMClient` | OpenAI 호환 SSE 스트리밍 클라이언트 |
| `SettingsView` | 설정 UI, 프롬프트 프로필 |

설계 결정과 근거는 [docs/PLAN.md](docs/PLAN.md), 단계별 구현 기록은 [docs/progress/](docs/progress/) 참조.

## 라이선스

미정.
