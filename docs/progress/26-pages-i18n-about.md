# 26. GitHub Pages 소개 페이지 + README 영문화 + 리포 About

## 목표

공개 배포 마무리 3건: 데모 GIF를 쓰는 소개 웹페이지를 GitHub Pages로 배포,
README를 다국어(기본 영어)로 전환, 리포지토리 About(설명·홈페이지·토픽) 설정.

## 결정

- **Pages 소스 = main 브랜치 `/docs`**. 별도 gh-pages 브랜치·Actions 워크플로 없이
  `docs/index.html` 하나로 끝. 데모 GIF는 기존 `docs/assets/` 재사용 (경로 `assets/…`).
- **소개 페이지는 완전 자립형 단일 HTML**. 외부 리소스 0 (CDN·웹폰트·분석 없음),
  시스템 폰트 스택, 다크 기본 + `prefers-color-scheme` 라이트 대응.
- **페이지 다국어 = 영문 인라인 + `data-ko` 속성 토글**. 영문이 정적 콘텐츠라
  JS 꺼져도/크롤러도 전문 노출. JS는 최초 로드 시 `dataset.en`을 textContent에서
  캡처하고 토글 시 교체. `localStorage.lang`은 en|ko 화이트리스트
  (같은 `*.github.io` 오리진의 타 프로젝트가 임의 값 써도 undefined 렌더 방지).
- **README 분리**: `README.md`(영어, 기본) + `README.ko.md`(한국어),
  상단 상호 스위처. 앱 UI가 한국어라 영문 Quick Start는 실제 라벨을
  한국어로 인용(설정, 모델 가져오기) + 영어 주석 병기.
- **About**: description 영어 한 줄, homepage = Pages URL, 토픽 7개
  (macos·llm·menubar-app·swift·accessibility·openai-api·productivity).

## 산출물

- `docs/index.html` — 히어로(설치 명령 복사 버튼) / 데모 3종(GIF) / 기능 9카드 /
  빠른 시작 / 푸터. EN/KO 토글.
- `README.md`(영어) · `README.ko.md`(한국어) — 내용 1:1.
- Pages 활성화(main `/docs`), About 설정은 `gh` CLI로 반영 (커밋 대상 아님).

## 수동 테스트

- [x] 로컬 file:// 렌더 — 이미지 전부 로드, EN/KO 토글 왕복, innerText에 'undefined' 없음.
- [ ] 배포 후 https://scian0204.github.io/AnywhereLLM/ 실기기 확인 (GIF 로드·모바일 폭).
