# 앱 내 자체 업데이트 설계

날짜: 2026-07-22
상태: 승인됨 (구현 대기)
대상 플랫폼: macOS(Swift/AppKit) + Windows(.NET/WPF) — 이중 반영

## 목표

인스톨러 없이 앱이 스스로 새 버전 바이너리를 내려받아 제자리 교체 후 재실행한다
(Chrome·VS Code식). GitHub Releases를 배포·확인 소스로 사용. 실행 시 자동 확인 +
수동 메뉴. 다운로드 무결성은 SHA256 체크섬으로 검증.

## 확정 결정 (근거)

- **플랫폼**: 둘 다. 순수 로직은 공유 코어에 동일 동작 + 동일 테스트.
- **자동화 깊이**: 완전 자체 교체(인스톨러 미사용). 명시 요청.
- **확인 시점**: 실행 시 자동 1회 + 수동 메뉴/버튼.
- **무결성**: HTTPS(GitHub) + SHA256 체크섬. 서명 검증은 안 함 — 현재 서명이
  자가서명/ad-hoc이라 가치가 약하고, 무결성은 체크섬으로 충분.
- **배포 소스**: GitHub Releases (`scian0204/AnywhereLLM`). 이 값은 변하지 않으므로
  설정 키로 빼지 않고 상수로 둔다.

## 아키텍처

### 1) 공유 순수 로직 — `Sources/LLMCore` ↔ `windows/AnywhereLLM.Core`

네트워크·파일 무접촉. 양쪽 동일 동작 + 동일 테스트 (기존 SSEParser 등과 같은 기준).
`UpdateCheck`:

- `isNewer(current: String, latest: String) -> Bool`
  - 선행 `v` 제거, `.`로 분해해 숫자 성분 비교. `0.4.1 < 0.4.10 < 0.5.0`.
  - 파싱 불가/동일이면 false (다운그레이드·재설치 방지 — `isNewer`일 때만 적용).
- `parseLatestRelease(json) -> ReleaseInfo?`
  - GitHub `/releases/latest` 응답 → `{ tag: String, assets: [{ name, downloadUrl, size }] }`.
  - 필수 필드 없으면 nil.
- `pickAsset(assets, platform) -> Asset?`
  - 이름 패턴 매칭. mac: `*-macos.zip`, win: `*-win-x64.zip`. MSI는 무시.
- `parseChecksums(text) -> [name: hash]`
  - 표준 `<sha256(64hex)>␣␣<filename>` 줄 파싱. 빈 줄/형식 불일치 줄 무시.

### 2) 앱측 오케스트레이션 — `UpdateService` (mac Swift / win C#)

플랫폼 API·프로세스 제어라 앱 타겟에 둔다 (테스트 불가 영역).

1. **check**
   - `GET https://api.github.com/repos/scian0204/AnywhereLLM/releases/latest`
   - `User-Agent` 헤더 필수 (GitHub API가 없으면 403).
   - 현재 버전: mac `CFBundleShortVersionString`, win 어셈블리 버전.
   - `parseLatestRelease` → `isNewer` → 새 버전이면 UI 알림.
   - 자동 확인 시 네트워크/파싱 실패는 조용히 무시(사용자 방해 금지). 수동 확인 시엔
     "확인 실패" 메시지.
2. **download + verify**
   - `pickAsset`로 플랫폼 zip 선택, `SHA256SUMS.txt` 에셋 다운로드.
   - zip을 temp에 저장 → SHA256 계산 → `parseChecksums`의 해당 항목과 대조.
   - **불일치면 즉시 중단**(교체 안 함, 에러 표시). 일치할 때만 unzip.
3. **swap + relaunch** (헬퍼 스크립트 방식 — 실행 중 자기 자신 교체)

   **macOS**
   - 실행 번들 = `Bundle.main.bundlePath`. 부모 디렉터리 쓰기 가능성 확인.
   - 쓰기 가능: temp에 셸 스크립트 작성 →
     `현재 pid가 죽을 때까지 대기` → `rm -rf <구 번들>` → `ditto <신 번들> <구 번들>`
     → `xattr -dr com.apple.quarantine <구 번들>` → `open <구 번들>`.
     스크립트를 분리 실행(`Process`, 대기 안 함) 후 `NSApp.terminate`.
   - 쓰기 불가(`/Applications` 등 root 소유, 또는 translocated RO 경로):
     **폴백** — 릴리즈 페이지를 브라우저로 열고 Finder에 다운로드 표시, 수동 교체 안내.
   - 참고: URLSession으로 받은 파일엔 `com.apple.quarantine`가 안 붙어 Gatekeeper
     재프롬프트 없음. 그래도 스크립트에서 방어적으로 제거.

   **Windows**
   - 실행 exe = `Environment.ProcessPath`. 쓰기 가능성 확인.
   - 쓰기 가능: temp에 `.cmd` 작성 →
     `tasklist`로 현재 pid 종료 대기 → `move /y <구 exe> <구 exe>.old` →
     `move /y <신 exe> <구 exe>` → `start "" <구 exe>` → 자기 삭제(`del`).
     분리 실행 후 `Application.Current.Shutdown()`.
   - 다음 실행 시 남은 `<exe>.old` 정리(best-effort, 실패 무시).
   - 경로 쓰기 불가: 폴백 — 릴리즈 페이지 열기.
   - 실행 중 exe 리네임은 Windows에서 허용됨(매핑된 이미지).

### 3) UX

- **실행 시 자동**: 앱 시작 직후 백그라운드 check. 새 버전이면 네이티브 프롬프트
  (mac `NSAlert` / win `MessageBox`): "새 버전 vX.Y.Z 있음. 지금 설치?" [지금][나중에].
- **수동**: 앱 메뉴(mac 상태바 `NSStatusItem` 메뉴 / win 트레이 메뉴) + 설정창에
  "업데이트 확인" 항목/버튼. 최신이면 "최신 버전입니다".
- **다운로드 중**: 최소 피드백(메뉴/버튼 텍스트 "다운로드 중…" + 비활성화). ~57MB.
  실패 시 에러 표시, 앱은 그대로 유지.

## 릴리즈 프로세스 변경

기존: MSI(win), 유니버설 zip(mac)만 발행. 자체 교체용으로 추가 필요:

- **에셋 추가**
  - mac: `AnywhereLLM-<ver>-macos.zip` — 기존 `make dist` 산출 zip을 이 이름 규칙으로.
  - win: `AnywhereLLM-<ver>-win-x64.zip` — self-contained 단일 exe만 압축.
  - 공통: `SHA256SUMS.txt` — 두 zip(및 MSI)의 해시.
- **빌드 스크립트**
  - `windows/packaging/installer/build-installer.ps1`: MSI 빌드 후 exe를
    `AnywhereLLM-<ver>-win-x64.zip`으로 압축 + 해시 출력.
  - mac `Makefile dist`: zip 이름 규칙 정리 + 해시 출력.
  - 릴리즈 시 `SHA256SUMS.txt`에 두 해시 취합해 `gh release create`에 함께 첨부.
- MSI는 **최초 설치 전용**으로 유지. 설치 후 업데이트는 앱이 exe만 교체.

## 테스트

- **순수 로직 (자동)**: `isNewer`(경계·자릿수·동일·불량 입력), `parseLatestRelease`,
  `pickAsset`(플랫폼별·MSI 제외), `parseChecksums`(정상·잡음 줄) — LLMCoreTests(Swift) +
  xUnit(win) 동일 케이스.
- **다운로드·교체·재실행 (수동)**: GUI/프로세스라 자동 불가. `docs/progress/NN-*.md`에
  플랫폼별 수동 시나리오:
  1. 낮은 버전으로 빌드 → 실행 시 프롬프트 뜨는지.
  2. 설치 → 새 릴리즈 발행 → 수동 확인 → 다운로드 → 재실행 후 버전 올라갔는지.
  3. 체크섬 불일치 주입 → 교체 안 되고 에러 나는지.
  4. 쓰기 불가 위치(mac `/Applications`, win Program Files 강제) → 폴백 동작.

## 마크할 천장 (의도적 단순화)

- 제자리 교체는 **쓰기 가능 설치 위치** 전제. 아니면 릴리즈 페이지 폴백. 관리자 승격 안 함.
- 무결성 = SHA256. 코드 서명 검증 아님(자가서명/ad-hoc이라 가치 약함).
- 다운그레이드/재설치 방지 = `isNewer` 게이트만.
- win `.old` 정리는 best-effort.
- 외부 패키지 의존성 0 유지 (Sparkle·Squirrel 미사용 — 하드 룰).
