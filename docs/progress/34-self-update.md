# 34 — 앱 내 자체 업데이트 (인스톨러 없이)

설계·근거: `docs/superpowers/specs/2026-07-22-self-update-design.md`,
계획: `docs/superpowers/plans/2026-07-22-self-update.md`.

## 개요

앱이 GitHub Releases에서 새 버전을 스스로 받아 **인스톨러 없이 제자리 교체 후
재실행**한다. 실행 시 조용히 1회 확인 + 메뉴에서 수동 확인. 다운로드 무결성은
SHA256 체크섬 대조.

## 소스 매핑 (mac ↔ win)

| 책임 | macOS | Windows |
|------|-------|---------|
| 순수 로직 | `Sources/LLMCore/UpdateCheck.swift` | `windows/AnywhereLLM.Core/UpdateCheck.cs` |
| 테스트 | `Tests/LLMCoreTests/UpdateCheckTests.swift` | `windows/AnywhereLLM.Core.Tests/Program.cs` |
| 서비스 | `Sources/AnywhereLLM/UpdateService.swift` | `windows/AnywhereLLM.App/Services/UpdateService.cs` |
| 연동 | `AppDelegate.swift`(상태바 메뉴+실행 시) | `App.xaml.cs`(트레이 메뉴+실행 시) |
| 문자열 | `Resources/*.lproj/Localizable.strings` | `Services/Localization.cs` |

순수 로직 4함수(동일 동작·동일 테스트): `isNewer`(semver 비교, 선행 v 제거, 다운그레이드
방지 게이트), `parseLatestRelease`(GitHub JSON), `pickAsset`(플랫폼 접미사 매치 —
mac `-macos.zip`, win `-win-x64.zip`, MSI 무시), `parseChecksums`(sha256sum 형식).

## 동작

1. **확인**: `api.github.com/repos/scian0204/AnywhereLLM/releases/latest` (User-Agent 필수).
   현재 버전(mac `CFBundleShortVersionString`, win 어셈블리 버전) vs tag → `isNewer`.
2. **다운로드+검증**: 플랫폼 zip + `SHA256SUMS.txt` 다운로드 → zip SHA256 == 체크섬
   확인. **불일치면 중단**(교체 안 함). 통과 시 해제(mac `ditto`, win `ZipFile`).
3. **교체+재실행** (헬퍼 스크립트, 우리 PID 종료 대기 후):
   - mac: `rm -rf` 구 번들 → `ditto` 신 번들 → `xattr -dr com.apple.quarantine` → `open`.
   - win: `move` 구 exe→`.old` → `move` 신 exe→제자리 → `start` → 자기 삭제. 다음 실행 때
     `.old` 정리.
4. **쓰기 불가 위치**(mac `/Applications` root 소유, win Program Files) → 릴리즈 페이지
   폴백. 관리자 승격 안 함.

## 릴리즈 프로세스 변경

- win `build-installer.ps1`: MSI + `AnywhereLLM-<ver>-win-x64.zip`(exe만) + `SHA256SUMS.txt`.
- mac `Makefile dist`: zip 이름 `-macos.zip` + `SHA256SUMS.txt`.
- 릴리즈에 두 플랫폼 zip + 취합한 `SHA256SUMS.txt` 첨부. MSI는 최초 설치 전용.

## 수동 테스트 (사용자 실측 필요 — GUI/프로세스, 자동 불가)

1. 낮은 버전으로 빌드·설치 → 실행 → 자동 확인으로 "업데이트 있음" 프롬프트가 뜨는지.
2. 메뉴 "업데이트 확인" → 최신이면 "최신 버전입니다", 새 버전이면 프롬프트.
3. [설치] → 다운로드 → 앱 종료 → 헬퍼가 교체 후 재실행 → 버전이 올라갔는지.
4. 체크섬 불일치 주입(SHA256SUMS 변조) → 교체 안 되고 "업데이트 실패" 나는지.
5. 쓰기 불가 위치(mac `/Applications`, win Program Files)에 설치 → [설치] 시 릴리즈
   페이지가 열리고 앱은 그대로인지.

## 검증 상태

- **Windows**: `AnywhereLLM.Core.Tests` 통과(75), `AnywhereLLM.App` Release 빌드 0 경고/오류.
- **macOS**: 이 작업은 Windows에서 진행 — swift 툴체인 없음. **mac 빌드/테스트/GUI 미검증**.
  Mac에서 `swift test --filter UpdateCheckTests` + `make` 후 위 수동 시나리오 실측 필요.
