# 09 — 안정적 코드서명 (접근성 권한 반복 초기화 해결)

## 증상
접근성 권한을 허용해도 재빌드 후 실행하면 다시 "권한 필요"로 뜸.

## 원인
- ad-hoc 서명(`codesign --sign -`)은 안정적 identity가 없어 TCC가 앱을 **cdhash(코드 해시)** 로 식별.
- 빌드할 때마다 cdhash가 바뀜 → TCC 입장에선 매번 다른 앱 → 기존 권한 무효.
- 번들 ID/경로가 같아도 소용없음. (01-scaffold.md에서 예고된 제약이 실측 확인된 것.)

## 해결
자가서명 코드서명 인증서 "AnywhereLLM Dev"로 서명 → designated requirement가
인증서 identity 기준이 되어 재빌드에도 TCC 권한 유지.

### 변경
- `scripts/make-signing-cert.sh` (신규): openssl로 codeSigning EKU 자가서명 인증서 생성
  → 로그인 키체인 import → 신뢰 등록. 멱등 (이미 있으면 skip).
- `Makefile`:
  - `CODESIGN_ID` 자동 감지 — "AnywhereLLM Dev" 인증서 있으면 사용, 없으면 ad-hoc 폴백.
  - 부수 버그 수정: `$(BIN)` 파일 타겟 탓에 소스 변경돼도 재빌드 안 되던 문제
    → phony `build` 타겟으로 교체 (매번 `swift build -c release`).

## 사용자 1회 셋업 절차
```bash
bash scripts/make-signing-cert.sh          # 인증서 생성 (키체인 암호 프롬프트 허용)
tccutil reset Accessibility kr.scian0204.AnywhereLLM   # 꼬인 기존 TCC 항목 정리
make run                                   # 새 identity로 빌드+실행
# → 접근성 권한 한 번만 다시 허용. 이후 재빌드해도 유지됨.
```
- 첫 서명 시 "codesign이 키에 접근하려 함" 프롬프트 → "항상 허용".

## 수동 확인
1. `make` 출력이 `(sign: AnywhereLLM Dev)` 인지
2. 권한 허용 후 `make run` 두세 번 반복 → 권한 유지되는지
3. 코드 수정 → `make run` → 권한 유지되는지

## 한계
- 자가서명이라 다른 Mac에 배포하면 Gatekeeper 경고. 공개 배포(계획 b) 시 정식
  Developer ID 서명 + 공증으로 교체 — Makefile의 CODESIGN_ID만 바꾸면 됨.
