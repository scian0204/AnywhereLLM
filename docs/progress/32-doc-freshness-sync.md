# 32 — 문서 최신화 감사

진행사항·소스코드와 어긋난 문서를 찾아 실제 구현에 맞췄다. 각 living 문서
(README.md, README.ko.md, docs/index.html, CLAUDE.md, docs/PLAN.md)를 코드·테스트·
progress 노트와 대조해 사실 불일치만 골라 수정. 동작 코드 변경 없음 — 문서만.

## 확정·수정된 불일치

### 앱이 한국어 전용이라는 잘못된 안내 (README.md, 심각도 높음)
빠른 시작의 `*(앱 UI가 현재 한국어…)*` 주석과 "**설정**(Settings)"·
"**모델 가져오기**(Fetch Models)" 한국어 라벨 인용. 실제로는 progress/28 이후
시스템 언어 따라 영/한 이중 (Package.swift `defaultLocalization: "en"`, en/ko.lproj,
L10n.swift). 영어 시스템 사용자는 영어 라벨을 봄.
- 수정: 주석을 "시스템 언어 따라 영어/한국어"로, 라벨을 영어(Settings, Fetch Models)로.

### LLMCore 구성/테스트 범위 축소 표기 (README ×2, README.ko ×2, CLAUDE.md ×2)
LLMCore가 "SSE 파서·think 태그 필터" 2개로만 기술됨. 실제로는 4개 모듈 —
`Endpoint`(URL 조합/origin 추출), `OllamaChatParser`(Ollama 네이티브 NDJSON) 추가.
테스트도 4개 스위트(SSEParser·ThinkTagFilter·Endpoint·OllamaChatParser, 35 케이스).
- 수정: 컴포넌트 표·`swift test` 주석에 Endpoint·OllamaChatParser 반영.

### LLMClient Ollama 네이티브 전환 미기재 (CLAUDE.md)
think 끄기 + Ollama 감지(/api/version) 시 네이티브 /api/chat + NDJSON 전환
(progress/13)이 아키텍처 6번에 없었음 → 추가.

### PLAN.md 확정 결정이 구현과 어긋남
- 행 9 시스템 프롬프트: "단일 문자열, 프리셋 MVP 제외" → 실제 다중 프롬프트 프로필
  (`promptProfiles`, ⌘P 전환, progress/08·23)로 갱신.
- 행 4 텍스트 I/O: 쓰기 폴백을 "⌘C/⌘V 이벤트 시뮬레이션"으로 적었으나 쓰기는
  AX setSelectedText → CGEvent 유니코드 타이핑(⌘V 미사용). 읽기/쓰기 비대칭 명시.
- 빌드 방식: "ad-hoc codesign"만 기술 → 자가서명 인증서 우선·ad-hoc 폴백(progress/09).

### index.html 빠른 시작 영어 문구에 한국어 라벨 잔존
영어 표시 텍스트가 "설정 (Settings)"·"모델 가져오기 / Fetch Models"를 인용 →
영어 라벨만 남기고 `data-ko`(한국어)는 그대로 유지.

## 방법
5개 문서를 6개 감사 에이전트로 병렬 대조 후 각 발견을 적대적 재검증(코드 근거 확인),
확정 11건만 반영.
