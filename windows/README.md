# AnywhereLLM — Windows (.NET / WPF)

Windows port of the macOS menu-bar app. Tray-resident; a global hotkey
(default **Ctrl+Shift+Space**) opens a floating panel that sends the focused
text / selection to an OpenAI-compatible LLM and types the result back into
whatever app you were in. A second hotkey (default **Ctrl+Shift+2**, configurable
in Settings) starts a drag-to-select screen capture (Win+Shift+S style) and opens
the same panel to ask a vision-capable model about the captured image.

Design rationale and the full macOS→Windows mapping: [`../docs/progress/31-windows-port.md`](../docs/progress/31-windows-port.md).

## Install

Download `AnywhereLLM-<version>-x64.msi` from
[Releases](https://github.com/scian0204/AnywhereLLM/releases) and double-click —
per-user (no admin), Start-Menu shortcut + uninstall entry. Or build the MSI:

```powershell
cd windows
.\packaging\installer\build-installer.ps1
```

## Requirements (build from source)

- Windows 10/11
- .NET SDK 10 (`dotnet --version` ≥ 10)

## Build & run

```bash
cd windows
dotnet run --project AnywhereLLM.Core.Tests -c Release   # pure-logic tests (38)
dotnet build AnywhereLLM.slnx -c Release                 # build everything
dotnet run  --project AnywhereLLM.App -c Release          # launch (lives in the tray)
```

The app has no main window: left-click the tray icon (or press the hotkey) to
toggle the panel; right-click for Settings / Quit.

## Projects

| Project | What |
|---|---|
| `AnywhereLLM.Core` | Pure logic — SSE parser, `<think>` filter, Ollama NDJSON parser, endpoint joining. Ported 1:1 from the Swift `LLMCore` target. |
| `AnywhereLLM.Core.Tests` | Dependency-free console test runner (exit 0 = pass) covering all four Core modules. |
| `AnywhereLLM.App` | WPF tray app. Win32 interop (hotkey, SendInput, caret, Credential Manager), UI Automation text capture, the panel + settings UI. |

## Platform notes

- **Text I/O** uses UI Automation to read the focused selection/value and
  `SendInput` Unicode typing to write (replacing the live selection). A
  clipboard Ctrl+C fallback covers apps with no automation.
- **Secure (password) fields** are hard-blocked — never captured, never written.
- **No accessibility permission** is needed on Windows (unlike macOS). Injecting
  into an elevated (admin) window requires the app itself to be elevated.
- App settings live in `%APPDATA%\AnywhereLLM\settings.json`; the API key lives
  in Windows Credential Manager.

GUI behavior (hotkey, injection, caret positioning, per-app UIA quirks) can only
be verified by hand — see the manual-test checklist in the progress doc.
