# 릴리즈 배포 런북

기능 추가/변경을 완료하면 **별도 지시 없이** 이 절차로 배포한다(근거: `CLAUDE.md` 프로세스).
인앱 자체 업데이터(`docs/progress/34-self-update.md`)가 GitHub Releases의 에셋을 받아
자동 교체하므로, **에셋 이름 규칙과 `SHA256SUMS.txt`는 업데이터와의 계약** — 어기면 인앱
업데이트가 실패한다.

## 배포할 때 / 안 할 때

- **배포**: 사용자에게 노출되는 기능 또는 버그 수정이 완료되고 검증(테스트/빌드 green)된 뒤.
- **배포 안 함**: 순수 문서, 동작 무변경 리팩터, 미완성·실험 작업, 사용자가 보류를 지시한 경우.
- 애매하면 배포 대신 사용자에게 한 줄로 확인.

## 0. 사용자 문서 갱신 (적당히 중요한 기능만)

사용자가 체감하는 기능을 추가하면 릴리즈에 앞서/함께 아래를 갱신한다. 자잘한 변경
(버그 수정·리팩터·성능·소소한 UX 폴리시)은 생략 — 코드만 배포.

**"적당히 중요"의 기준(하나라도 해당):** 새 동작 모드·기능, 새 LLM 공급자/통합, 사용자가
조작하는 새 설정, 핫키/UX 변경, 플랫폼 지원 추가.

**갱신 대상:**

- `README.md`(영문) + `README.ko.md`(한글) — 같은 내용을 두 파일에 함께. Windows 전용
  기능이면 `windows/README.md`도.
- 소개 사이트 `docs/index.html`(GitHub Pages, 이중언어 단일 페이지) — 영문은 요소에 인라인,
  한글은 **같은 요소의 `data-ko` 속성**. 기존 "Three modes" 섹션 패턴을 따라 두 언어를 함께
  추가한다. `#lang` 토글이 `data-ko`로 스왑하므로 **`data-ko` 누락 시 토글해도 영문만 나온다**.

문서 커밋은 코드 커밋과 분리하거나 릴리즈 커밋에 앞세운다(방식은 재량). 사이트(`docs/`)는
GitHub Pages라 push 즉시 반영 — 별도 배포 없음.

## 1. 버전 결정 (semver, 루트 `VERSION` 단일 소스)

- 기능 추가 → **minor** (`0.5.0` → `0.6.0`)
- 버그 수정 → **patch** (`0.5.0` → `0.5.1`)
- 호환 깨짐 → **major**

`VERSION`은 mac `Makefile`과 win `windows/Directory.Build.props`가 공유하므로 이 파일만 고치면
양쪽 빌드에 반영된다. **빌드 전에** 먼저 올린다(아티팩트 이름에 버전이 들어감).

## 2. 빌드 + 아티팩트

### Windows (이 개발 머신)

Windows PowerShell 5.1에서 (사전: .NET SDK 10, WiX 7 `wix`):

```bash
./windows/packaging/installer/build-installer.ps1
```

`windows/packaging/installer/`에 산출:

- `AnywhereLLM-<ver>-x64.msi` — 최초 설치용
- `AnywhereLLM-<ver>-win-x64.zip` — 자체 업데이트용(self-contained exe만)
- `SHA256SUMS.txt` — 위 두 파일 해시(`<sha256>␣␣<파일명>`, LF)

### macOS (Mac에서만 — 이 머신 불가)

```bash
make dist
```

`build/`에 `AnywhereLLM-<ver>-macos.zip` + `SHA256SUMS.txt` 산출. 이 저장소 작업은 보통
Windows에서 진행되어 **mac 빌드는 불가** — win만 먼저 배포하고, mac zip은 나중에 Mac에서
빌드해 같은 릴리즈에 추가한다(아래 5절).

## 3. 커밋 + 태그 + push

`VERSION`만 담은 릴리즈 커밋(코드 변경은 이미 별도 커밋됨):

```bash
git add VERSION
git commit -m "chore(release): 버전 <ver> — <한 줄 요약>"
git tag -a v<ver> -m "AnywhereLLM <ver> — <한 줄 요약>"
git push origin main
git push origin v<ver>
```

## 4. GitHub 릴리즈 생성

`gh`는 PATH에 없어 전체 경로로 호출한다(Windows):

```bash
"/c/Program Files/GitHub CLI/gh.exe" release create v<ver> \
  --title "AnywhereLLM <ver>" \
  --notes "<릴리즈 노트: 새 기능/수정, 다운로드 안내>" \
  windows/packaging/installer/AnywhereLLM-<ver>-x64.msi \
  windows/packaging/installer/AnywhereLLM-<ver>-win-x64.zip \
  windows/packaging/installer/SHA256SUMS.txt
```

- 노트가 여러 줄이면 `--notes-file` 대신 셸 here-string으로 인라인 전달(스크래치 파일 게이트 회피).
- 확인:

```bash
"/c/Program Files/GitHub CLI/gh.exe" release view v<ver> --json name,tagName,assets
```

## 5. macOS zip 나중에 추가할 때

Mac에서 `make dist` 후, mac zip을 같은 릴리즈에 올리고 `SHA256SUMS.txt`에 mac 항목을 합친다
(업데이터가 파일별로 조회하므로 항목만 있으면 됨):

```bash
gh release upload v<ver> build/AnywhereLLM-<ver>-macos.zip
# SHA256SUMS.txt에 mac 줄을 합쳐 재업로드 (--clobber)
gh release upload v<ver> SHA256SUMS.txt --clobber
```

## 6. Homebrew cask 갱신 (macOS — zip이 릴리즈에 올라간 뒤)

macOS는 `brew install --cask scian0204/tap/anywherellm`로도 배포한다. cask는 별도 탭
저장소 [`scian0204/homebrew-tap`](https://github.com/scian0204/homebrew-tap)의
`Casks/anywherellm.rb`에 있고, **릴리즈의 `-macos.zip` 에셋을 받는다** — 그래서 mac zip이
릴리즈에 올라간 뒤(4절 또는 5절) 갱신한다. `url`은 `#{version}` 템플릿이라 **`version`과
`sha256` 두 줄만** 바꾸면 된다(`sha256` = mac zip 해시, `build/SHA256SUMS.txt`).

```bash
gh repo clone scian0204/homebrew-tap /tmp/homebrew-tap   # 기존 클론이면 git pull
# Casks/anywherellm.rb 에서 version "x.y.z" 와 sha256 "<mac zip 해시>" 두 줄 갱신
git -C /tmp/homebrew-tap commit -am "anywherellm <ver>"
git -C /tmp/homebrew-tap push origin main
# 검증(설치 아님 — 릴리즈 zip을 받아 sha256 대조):
brew update && brew fetch --cask scian0204/tap/anywherellm
```

`brew fetch`가 `✔︎ Cask anywherellm (<ver>)`를 찍으면 sha가 맞고 사용자가
`brew upgrade --cask anywherellm`로 받을 수 있다. sha 불일치면 `SHA256SUMS.txt` 값과
릴리즈에 실제로 올라간 zip이 다른 것 — 재확인. (Windows는 brew 대상 아님.)

## 에셋 이름 규칙 (업데이터 계약 — 바꾸지 말 것)

`UpdateService`의 `pickAsset`가 접미사로 선택하고 `parseChecksums`가 `SHA256SUMS.txt`로 검증:

| 플랫폼 | 접미사 | 예 |
|--------|--------|----|
| Windows | `-win-x64.zip` | `AnywhereLLM-0.5.0-win-x64.zip` |
| macOS | `-macos.zip` | `AnywhereLLM-0.5.0-macos.zip` |
| 공통 | `SHA256SUMS.txt` | — |

이름·형식을 바꾸려면 mac `Sources/LLMCore/UpdateCheck.swift` +
`Sources/AnywhereLLM/UpdateService.swift`, win `windows/AnywhereLLM.Core/UpdateCheck.cs` +
`windows/AnywhereLLM.App/Services/UpdateService.cs`를 함께 고친다.

## 롤백 (잘못 배포한 경우)

```bash
"/c/Program Files/GitHub CLI/gh.exe" release delete v<ver> --yes
git push origin :refs/tags/v<ver>   # 원격 태그 삭제
git tag -d v<ver>                    # 로컬 태그 삭제
# VERSION 되돌리고 다시 진행
```

자체 업데이터는 `isNewer`가 엄격히 높은 버전에서만 동작하므로, 잘못된 상위 버전을 지웠으면
그보다 낮은 새 버전으로 다시 올려야 구버전 클라이언트가 재감지한다.
