# 앱 내 자체 업데이트 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans (inline). Steps use checkbox (`- [ ]`).

**Goal:** 인스톨러 없이 앱이 GitHub Releases에서 새 버전 바이너리를 받아 제자리 교체 후 재실행.

**Architecture:** 순수 로직(버전 비교·릴리즈 JSON 파싱·에셋 선택·체크섬 파싱)은 공유 코어(`LLMCore`/`AnywhereLLM.Core`)에 동일 동작+동일 테스트. 네트워크·파일·프로세스는 앱 타겟의 `UpdateService`. 실행 중 자기 교체는 헬퍼 스크립트(대기→교체→재실행)로.

**Tech Stack:** Swift/AppKit(mac), .NET 10/WPF(win). 외부 의존성 0. GitHub REST + `System.Text.Json`/`Foundation.JSONSerialization`.

## Global Constraints

- 외부 패키지 의존성 0 (Sparkle/Squirrel/NuGet 금지).
- 버전 소스 = 루트 `VERSION` 파일 하나. 이번 배포 버전 `0.5.0` (feature → minor).
- GitHub repo 상수: `scian0204/AnywhereLLM`.
- 무결성 = SHA256 체크섬 대조. 불일치 시 교체 중단.
- 다운그레이드 방지 = `isNewer` 게이트만.
- 쓰기 불가 설치 위치면 릴리즈 페이지 폴백 (관리자 승격 안 함).
- 문서/커밋 한국어, conventional commit. progress 문서 = `docs/progress/34-self-update.md`.
- 이 머신은 Windows: mac 코드는 작성하되 컴파일/테스트 불가 → Mac에서 검증 필요(문서에 명시).

---

## Task 1: 공유 순수 로직 (Windows Core) + 테스트

**Files:**
- Create: `windows/AnywhereLLM.Core/UpdateCheck.cs`
- Modify: `windows/AnywhereLLM.Core.Tests/Program.cs` (테스트 추가)

**Interfaces (Produces):**
- `static class UpdateCheck`
  - `bool IsNewer(string current, string latest)` — 선행 `v` 제거, `.` 분해 숫자 비교. 파싱 불가/동일 → false.
  - `record ReleaseInfo(string Tag, IReadOnlyList<ReleaseAsset> Assets)`
  - `record ReleaseAsset(string Name, string DownloadUrl, long Size)`
  - `ReleaseInfo? ParseLatestRelease(string json)` — `tag_name` + `assets[].{name,browser_download_url,size}`. 필수 없으면 null.
  - `ReleaseAsset? PickAsset(IReadOnlyList<ReleaseAsset> assets, string suffix)` — `Name.EndsWith(suffix)` 첫 매치. (win 호출 `"-win-x64.zip"`)
  - `IReadOnlyDictionary<string,string> ParseChecksums(string text)` — `<64hex>␣+<name>` 줄 → {name:hash(소문자)}. 형식 불일치 줄 무시.

- [ ] Step 1: `UpdateCheck.cs` 작성 (위 시그니처, `System.Text.Json` 사용).
- [ ] Step 2: `Program.cs`에 테스트 블록 추가 — IsNewer(`0.5.0`>`0.4.1`, `0.4.10`>`0.4.1`, 동일=false, `v`접두, 불량입력=false), ParseLatestRelease(정상/필드누락), PickAsset(win zip 매치·MSI 제외·없음), ParseChecksums(정상 2줄·잡음 줄 무시).
- [ ] Step 3: `dotnet run --project windows/AnywhereLLM.Core.Tests` → 전부 pass.
- [ ] Step 4: 커밋 `feat(core-win): 자체 업데이트 순수 로직(버전비교·릴리즈파싱·체크섬)`.

## Task 2: 공유 순수 로직 (macOS LLMCore) + 테스트

**Files:**
- Create: `Sources/LLMCore/UpdateCheck.swift`
- Create: `Tests/LLMCoreTests/UpdateCheckTests.swift`

**Interfaces (Produces):** Task 1과 동일 동작, Swift 관용:
- `struct ReleaseAsset { let name: String; let downloadURL: String; let size: Int }`
- `struct ReleaseInfo { let tag: String; let assets: [ReleaseAsset] }`
- `func isNewer(current: String, latest: String) -> Bool`
- `func parseLatestRelease(_ json: Data) -> ReleaseInfo?` (JSONSerialization)
- `func pickAsset(_ assets: [ReleaseAsset], suffix: String) -> ReleaseAsset?` (mac 호출 `"-macos.zip"`)
- `func parseChecksums(_ text: String) -> [String: String]`

- [ ] Step 1: `UpdateCheck.swift` 작성.
- [ ] Step 2: `UpdateCheckTests.swift` — Task1과 동일 케이스, swift-testing `@Suite`/`@Test`/`#expect`.
- [ ] Step 3: (Mac에서) `swift test --filter UpdateCheckTests`. **이 머신에선 실행 불가 — 문서에 미검증 명시.**
- [ ] Step 4: 커밋 `feat(core-mac): 자체 업데이트 순수 로직 (win 대응)`.

## Task 3: Windows UpdateService + 트레이/실행 시 연동

**Files:**
- Create: `windows/AnywhereLLM.App/Services/UpdateService.cs`
- Modify: `windows/AnywhereLLM.App/App.xaml.cs` (트레이 메뉴 항목 + OnStartup 자동 확인 + `.old` 정리)
- Modify: `windows/AnywhereLLM.App/Services/Localization.cs` (update.* 키)

**Interfaces (Consumes):** `UpdateCheck` (Task 1).
**Produces:** `UpdateService` — `Task<ReleaseInfo?> CheckAsync()`, `Task DownloadAndApplyAsync(ReleaseInfo, IProgress<string>?)`, `static void CleanupOldExe()`.

동작:
- `CheckAsync`: `HttpClient` + `User-Agent: AnywhereLLM-Updater`, GET `releases/latest`, `ParseLatestRelease`, 현재 버전(`Assembly...Version`, `M.m.p`) vs `tag` → `IsNewer`면 반환 else null.
- `DownloadAndApplyAsync`: `PickAsset(...,"-win-x64.zip")` + `SHA256SUMS.txt` 다운로드 → zip을 temp 저장 → `SHA256` 계산 대조(`ParseChecksums`) → 불일치 throw. `ZipFile.ExtractToDirectory`로 새 exe 추출. `Environment.ProcessPath` 쓰기 가능하면 temp `.cmd` 작성(pid 대기→`move` old→`.old`→`move` new→제자리→`start`→자기삭제) 분리 실행 후 `Shutdown`. 쓰기 불가면 릴리즈 페이지 `Process.Start(UseShellExecute)`.
- 트레이: "업데이트 확인" 항목 추가. 클릭→`CheckAsync`, 새 버전이면 확인 `MessageBox`([지금][나중에])→`DownloadAndApplyAsync`. 최신이면 "최신 버전입니다". 확인 중/다운로드 중 항목 비활성.
- OnStartup: `CleanupOldExe()` + 백그라운드 `CheckAsync` → 새 버전이면 프롬프트(자동, 실패 조용).

- [ ] Step 1: `UpdateService.cs` 작성.
- [ ] Step 2: Loc `update.*` 키(en/ko) 추가.
- [ ] Step 3: `App.xaml.cs` 연동(메뉴·startup·cleanup).
- [ ] Step 4: `dotnet build -c Release windows/AnywhereLLM.App` → 0 error/warn.
- [ ] Step 5: 커밋 `feat(win): 자체 업데이트 서비스(확인·다운로드·검증·교체·재실행)`.

## Task 4: macOS UpdateService + 메뉴/실행 시 연동

**Files:**
- Create: `Sources/AnywhereLLM/UpdateService.swift`
- Modify: `Sources/AnywhereLLM/AppDelegate.swift` (메뉴 항목 + 실행 시 확인)
- Modify: mac Localizable.strings (en/ko) — 경로 확인 후.

**Interfaces (Consumes):** `UpdateCheck` (Task 2). **Produces:** `UpdateService`(class) — `check() async -> ReleaseInfo?`, `downloadAndApply(_:) async throws`.

동작: win과 대칭. `URLSession`으로 릴리즈 JSON + zip + SHA256SUMS 다운로드, `SHA256`(CryptoKit) 대조. `Bundle.main.bundlePath` 부모 쓰기 가능하면 셸 스크립트(pid 대기→`rm -rf`→`ditto`→`xattr -dr`→`open`) 분리 실행 후 `NSApp.terminate`. 불가면 `NSWorkspace.open(releaseURL)`. 메뉴 항목 `rebuildMenu`에 추가. `applicationDidFinishLaunching`에서 백그라운드 확인.

- [ ] Step 1: `UpdateService.swift` 작성.
- [ ] Step 2: mac Localizable.strings에 update.* 추가.
- [ ] Step 3: `AppDelegate` 연동.
- [ ] Step 4: (Mac) `swift build -c release`. **이 머신 불가 — 미검증 명시.**
- [ ] Step 5: 커밋 `feat(mac): 자체 업데이트 서비스 (win 대응)`.

## Task 5: 릴리즈 프로세스 + 버전 + progress 문서

**Files:**
- Modify: `windows/packaging/installer/build-installer.ps1` (exe-zip + SHA256SUMS 생성)
- Modify: `Makefile` (dist zip 이름 규칙 `-macos` + 해시) — mac용, 이 머신 미검증
- Modify: `VERSION` → `0.5.0`
- Create: `docs/progress/34-self-update.md`

- [ ] Step 1: `build-installer.ps1` — MSI 후 `AnywhereLLM-<ver>-win-x64.zip`(exe만) 생성 + `SHA256SUMS.txt`(zip+msi 해시) 작성.
- [ ] Step 2: `Makefile dist` — zip을 `-macos.zip`로, 해시 출력.
- [ ] Step 3: `VERSION` `0.5.0`.
- [ ] Step 4: `docs/progress/34-self-update.md` (설계 요약·수동 테스트 시나리오·mac 미검증 명시).
- [ ] Step 5: 커밋 `chore(release): 자체 업데이트 배포 스크립트 + progress 34` / VERSION은 릴리즈 커밋에서.

## Task 6: 빌드 · 릴리즈 배포 (v0.5.0)

- [ ] Step 1: `build-installer.ps1` 실행 → MSI + exe-zip + SHA256SUMS 산출, 해시 확인.
- [ ] Step 2: `VERSION` 커밋 `chore(release): 버전 0.5.0 — 앱 내 자체 업데이트`.
- [ ] Step 3: annotated 태그 `v0.5.0` + push (main + tag).
- [ ] Step 4: `gh release create v0.5.0` — MSI + exe-zip + SHA256SUMS 첨부, 릴리즈 노트.
- [ ] Step 5: `gh release view v0.5.0` 에셋 확인. mac zip은 Mac 빌드 후 별도 첨부 필요 — 사용자 안내.
