# AnywhereLLM — 확정 계획

macOS 메뉴바 상주 앱. 어떤 앱에서든 글로벌 핫키(`⌘⇧Space`)를 누르면 캐럿 근처에
포커스를 뺏지 않는 패널(NSPanel, non-activating)이 뜨고, LLM과 대화한 결과를
포커스된 텍스트박스에 삽입하거나 선택 텍스트를 교체한다.

## 확정 결정

| # | 결정 | 내용 |
|---|------|------|
| 1 | 플랫폼 | Mac 먼저. Windows는 UX 검증 후 별도 포팅 |
| 2 | 스택 | Swift 네이티브 (AppKit + SwiftUI), 메뉴바 앱, Dock 아이콘 없음 (`LSUIElement`) |
| 3 | 진입 | 핫키 하나 (`⌘⇧Space`, 설정 변경 가능). 선택 텍스트 유무로 모드 자동 분기 |
| 4 | 텍스트 I/O | 읽기: AX 우선 → 실패 시 클립보드 백업/복원 + ⌘C 이벤트 폴백. 쓰기: AX setSelectedText(반영 검증) → 실패 시 CGEvent 유니코드 타이핑 (클립보드·⌘V 미사용) |
| 5 | LLM | OpenAI 호환 엔드포인트 설정형 (base URL + API 키 + 모델명). 키는 Keychain. SSE 스트리밍 |
| 6 | 결과 반영 | 설정: 미리보기 후 확정(기본) / 즉시 반영. 패널 열린 동안 multi-turn 대화, 닫으면 리셋 |
| 7 | 패널 위치 | 설정: 캐럿 추적(기본, 캐럿→포커스요소 bounds→마우스 3단 폴백) / 마우스 / 화면 중앙 |
| 8 | 컨텍스트 | 설정: 대상 앱 이름 포함 on/off, 전체 필드 내용 포함 on/off(기본 off). 보안 텍스트필드 감지 시 동작 차단 — 하드 룰, 설정 아님 |
| 9 | 시스템 프롬프트 | 이름 있는 다중 프롬프트 프로필 (`promptProfiles` JSON, 활성 이름 `activeProfile`). 활성 프로필을 레거시 `systemPrompt` 키로 미러링해 소비측은 프로필 개념 무지. 패널 ⌘P로 전환 (progress/08, 23). *(초기 계획은 단일 문자열+프리셋 MVP 제외였으나 확장됨)* |
| 10 | 배포 | 로컬 빌드 개인용. hardened runtime 유지해 추후 공증 배포 여지 확보. App Store 불가(샌드박스가 AX 차단) |

## 빌드 방식

- Swift Package Manager executable + `Makefile`로 `.app` 번들 조립 (Info.plist 포함)
- 자가서명 인증서 "AnywhereLLM Dev" 우선 서명(scripts/make-signing-cert.sh), 없으면
  ad-hoc(-) 폴백 — ad-hoc은 cdhash 기반이라 재빌드마다 TCC(접근성 권한)가 초기화되므로
  안정적 identity로 권한 유지 (progress/09)
- 외부 빌드 도구(xcodegen 등) 의존 없음

## 구현 순서

설정은 전부 UserDefaults + 추천 기본값으로 동작 먼저 구현, 설정 UI는 마지막.

1. **scaffold** — SPM 골격, 메뉴바 앱, .app 번들 빌드, 접근성 권한 요청 플로우
2. **hotkey-panel** — 글로벌 핫키 + non-activating 패널 (포커스 안 뺏김 검증 — 최대 리스크 선행)
3. **ax-layer** — AX 읽기/쓰기 + 클립보드 폴백 (Safari, Mail, VSCode, Slack 실측 필요)
4. **llm-client** — OpenAI 호환 SSE 스트리밍 클라이언트 + Keychain 키 저장
5. **integration** — 패널 대화 UI + 삽입/교체 플로우 연결
6. **settings-ui** — 설정 화면

3, 4는 상호 독립 — 병렬 개발.

## 프로세스 규칙

- 기능(위 번호)마다 `docs/progress/NN-<이름>.md`에 진행사항 문서화 후 git 커밋
- 각 기능 = 커밋 1개 이상, 문서 포함

## 리스크

- 앱별 AX 지원 편차는 실측으로만 확인 가능 (자동화 불가 영역)
- non-activating 패널의 포커스 유지가 실패하면 설계 재검토 — 그래서 2단계에 배치
- 접근성 권한, 포커스 동작 등 GUI 실측 검증은 에이전트가 못 함 → 사용자 수동 확인 필요 지점을 progress 문서에 명시
