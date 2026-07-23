# 36 — Windows 스크린 캡쳐 컴파일 수정 + 빌드 스크립트 가드

0.6.0(스크린 영역 캡쳐 → 이미지 LLM 질의, progress/35)은 mac에서만 빌드·검증하고
릴리즈됐다. Windows 포트(`RegionCapture.cs`)는 **컴파일된 적이 없어** 배포가 막혔다 —
전형적인 단일 플랫폼 회귀.

## 증상

`dotnet publish`가 CS0104 3건으로 실패:

```
RegionCapture.cs(81,46): 'Color'은 'System.Drawing.Color' 및 'System.Windows.Media.Color' 사이에 모호
RegionCapture.cs(90,26): 'Brushes'은 'System.Drawing.Brushes' 및 'System.Windows.Media.Brushes' 사이에 모호
RegionCapture.cs(92,44): 'Color' 모호
```

## 원인

`AnywhereLLM.App`는 `Forms.SystemInformation`을 쓰느라 WinForms를 켜고
`ImplicitUsings`가 켜져 있다 → 컴파일러가 `global using System.Drawing`을 주입한다.
`RegionCapture.cs`가 `using System.Windows.Media;`를 추가하면서 `Color`·`Brushes`가
`System.Drawing`과 충돌. mac(Swift)은 별개라 드러나지 않았다.

## 수정

- `RegionCapture.cs`: 충돌하는 3곳만 `System.Windows.Media.Color`/`.Brushes`로 완전 수식.
  `SolidColorBrush`·`Cursors` 등은 `System.Drawing`에 동명이 없어 그대로 둔다.
- `build-installer.ps1`: `dotnet publish`는 네이티브 exe라 non-zero 종료가
  `$ErrorActionPreference`로 throw되지 않는다 — 이번에 컴파일 실패인데도 스크립트가
  이전 exe를 그대로 패키징했다(스테일 배포 직전). `$LASTEXITCODE` 명시 체크 + publish
  출력 디렉터리 사전 삭제를 추가해 재발 차단.

## 검증

- `AnywhereLLM.Core.Tests` 84/84 pass(`ChatImageContent` 포함).
- `dotnet publish` green, MSI 57.2MB / zip 66.1MB 생성.
- publish exe 실행 4초 생존(기동 크래시 없음). 드래그 캡쳐 실동작은 GUI라 수동 확인 필요.

버전 불변(0.6.0) — 이중 플랫폼은 VERSION 하나를 공유하므로, mac이 이미 나간 0.6.0에
Windows 아티팩트만 추가한다(win 범프는 플랫폼 desync + mac 오탐 업데이트 유발).
