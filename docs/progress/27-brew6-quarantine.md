# 27. Homebrew 6 대응 — --no-quarantine 플래그 제거 대응

## 문제

`brew install --cask --no-quarantine scian0204/tap/anywherellm` 실행 시
`Error: invalid option: --no-quarantine`. Homebrew 6.0.11에서 플래그 자체가
제거됨 (`brew install --cask --help`에 quarantine 항목 없음). 플래그 없이
설치하면 `com.apple.quarantine` 속성은 여전히 부여되어, 공증 없는 자가서명
앱은 Gatekeeper가 "손상된 앱"으로 차단.

## 해법

tap의 cask에 `postflight` 추가 — 설치 직후 격리 속성을 직접 제거:

```ruby
postflight do
  system_command "/usr/bin/xattr",
                 args: ["-dr", "com.apple.quarantine", "#{appdir}/AnywhereLLM.app"]
end
```

- 설치가 다시 한 줄: `brew install --cask scian0204/tap/anywherellm` (플래그 불필요).
- brew 버전 무관 (플래그가 있던 구버전에서도 postflight는 동일 동작).
- 잔여 `com.apple.provenance` 속성은 시스템 관리용 — 실행 차단과 무관.

## 갱신 위치

- tap `Casks/anywherellm.rb` — postflight + caveats 문구 (커밋 ce1ae80).
- tap `README.md`, 앱 리포 `README.md`/`README.ko.md` 설치 섹션,
  `docs/index.html` 설치 명령·주석 — `--no-quarantine` 전부 제거.

## 검증 (실측)

- [x] `brew uninstall` 후 플래그 없이 재설치 — 성공.
- [x] `xattr /Applications/AnywhereLLM.app` — `com.apple.quarantine` 없음.
