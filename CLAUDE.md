# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 프로젝트

macOS 메뉴바 상주 앱. 어떤 앱에서든 글로벌 핫키(기본 ⌘⇧Space)로 포커스를 뺏지 않는
패널을 띄워 LLM 결과를 포커스된 텍스트박스에 삽입하거나 선택 텍스트를 교체한다.
확정 설계 결정과 그 근거는 `docs/PLAN.md`, 단계별 구현 기록은 `docs/progress/NN-*.md`.

## 명령

```bash
make            # release 빌드 + build/AnywhereLLM.app 조립 + 서명
make run        # 빌드 후 실행
swift build     # 컴파일만 (디버그)
swift test      # LLMCore 테스트 (SSEParser, ThinkTagFilter)
swift test --filter ThinkTagFilterTests   # 단일 스위트
```

- 서명: 키체인에 "AnywhereLLM Dev" 자가서명 인증서 있으면 자동 사용, 없으면 ad-hoc.
  ad-hoc은 재빌드마다 TCC 접근성 권한이 초기화됨 — 인증서 생성은
  `scripts/make-signing-cert.sh` 1회 실행 (상세: docs/progress/09-stable-signing.md).
- 접근성 권한이 꼬이면: `tccutil reset Accessibility kr.scian0204.AnywhereLLM`
- GUI 동작(포커스 유지, AX 삽입, 권한 다이얼로그)은 자동 검증 불가 — 수동 테스트
  시나리오가 각 progress 문서에 있음. 코드 변경 시 사용자 실측 필요 항목을 명시할 것.

## 아키텍처

타겟 2개: `AnywhereLLM`(executable, AppKit 앱)과 `LLMCore`(라이브러리).
executable 타겟은 테스트 import가 불가능해서, 단위 테스트가 필요한 순수 로직
(SSE 파싱, think 태그 필터)만 LLMCore로 분리되어 있다. 새 순수 로직도 같은 기준으로 배치.

핵심 플로우 (파일 = 책임):

1. `HotkeyManager` — Carbon RegisterEventHotKey. UserDefaults의 keyCode/modifiers를
   start()마다 재로딩하므로 핫키 변경 시 stop()/start()만 하면 됨.
2. `AppDelegate` — 메뉴바(NSStatusItem), 접근성 권한 플로우, 핫키 → 패널 토글.
   **captureContext()를 패널 표시 전에 호출** (패널이 뜨면 포커스 정보가 바뀜 — 순서 불변).
3. `TextTarget.swift` (`TextTargetService`) — 대상 앱 텍스트 I/O. 3중 전략:
   AX API 우선 → 클립보드 백업+⌘C/⌘V 시뮬레이션 폴백 → 스트리밍 삽입은
   CGEventKeyboardSetUnicodeString 타이핑(클립보드 무접촉). CGEventSource는
   `.privateState` (자기 핫키 재유입 방지). `TargetContext.isEditable` 휴리스틱이
   보기 전용 흐름을 가른다 — **거부 목록** 방식: settable 아님 + 콘텐츠 표시 전용
   role일 때만 false, 불명/AX 오류/요소 없음은 전부 true (CGEvent 쓰기는 AX 불필요 —
   편집 필드를 보기 전용으로 오판하면 삽입이 회귀하므로 이 방향을 뒤집지 말 것).
4. `PromptPanel` — NSPanel `.nonactivatingPanel`. **이 앱의 존재 이유**: 패널이 키 입력을
   받아도 대상 앱이 frontmost 유지. canBecomeKey=true/canBecomeMain=false +
   orderFrontRegardless() 조합을 깨뜨리는 변경 금지. contentView는 NSHostingView(SwiftUI).
5. `ConversationController`/`ConversationView` — UX 분기 = 편집 가능성 × 선택 유무 × applyMode:
   - **보기 전용** (isEditable=false — 웹페이지 본문/PDF/파인더): 결과를 패널에 표시하고
     남긴다. 적용/자동 닫기 없음 (applyMode 무관) — 삽입할 곳이 없다.
   - **Transcript UX** (편집 가능 + (선택 있음 또는 applyMode=preview)): 패널에 마지막 assistant
     응답만 결과 블록으로 스트리밍 표시 (대화 버블 없음 — multi-turn 히스토리는 내부 유지).
     preview면 확정 버튼(선택=교체/무선택=삽입), immediate+선택은 완료 시 자동 교체.
     선택이 있으면 첫 턴은 빈 입력 ⏎로도 전송 (프롬프트 프로필이 지시 역할).
   - **실시간 타이핑** (편집 가능 + 선택 없음 + applyMode=immediate): 응답을 ThinkTagFilter 통과 후
     ~100ms 버퍼로 대상 텍스트박스에 타이핑. **첫 가시 토큰까지는 패널에 로딩 표시,
     토큰 도착 시 패널을 숨긴 뒤 타이핑** — 합성 키 이벤트는 key window로 라우팅되므로
     패널이 key인 채로 typeText 하면 패널이 이벤트를 먹는다 (상세: progress/10).
     타이핑 전 에러도 같은 이유로 flush 금지. 취소는 핫키 재입력.
6. `LLMClient` — OpenAI 호환 chat completions, URLSession.bytes SSE 스트리밍,
   AsyncThrowingStream. API 키는 `KeychainStore`(service kr.scian0204.AnywhereLLM).
7. `SettingsView` — 모든 UserDefaults 키의 UI. 설정 키 전체 목록은
   docs/progress/05, 08 참조. 프롬프트 프로필은 활성 프로필을 `systemPrompt` 키에
   미러링해서 소비측(ConversationController)이 프로필 개념을 모르게 되어 있음 — 유지할 것.

## 하드 룰

- 보안 텍스트필드(kAXSecureTextFieldSubrole) 감지 시 캡처/삽입/클립보드 폴백 전부 차단.
  설정으로 풀 수 없음. 이 차단을 우회하는 변경 금지.
- 외부 패키지 의존성 0. 추가하려면 사용자 승인 먼저.

## 프로세스

- 기능 단위 작업마다 `docs/progress/NN-<이름>.md` 작성 후 해당 파일들만 명시적으로
  git add하여 커밋 1개 (conventional commit, 한국어 제목 관례).
- 문서/커밋 메시지는 한국어.
