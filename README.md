<div align="center">

**English** | [한국어](README.ko.md)

# AnywhereLLM

**Any app, right where your cursor is — that's where the LLM works.**

One global hotkey <kbd>⌘⇧Space</kbd> opens a panel that never steals focus,
then types the LLM response into the focused text box in real time — or replaces the selected text in place.

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white)
![Dependencies](https://img.shields.io/badge/dependencies-0-brightgreen)
![API](https://img.shields.io/badge/API-OpenAI%20compatible-412991?logo=openai&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-blue)

**[🌐 Website](https://scian0204.github.io/AnywhereLLM/)**

<img src="docs/assets/demo-replace.gif" width="760" alt="Selection replace demo — select a Korean draft, hit the hotkey, and it is instantly replaced with the English translation">

*Select the Korean draft you typed in a messenger input, press <kbd>⌘⇧Space</kbd> → <kbd>⏎</kbd> — the translation replaces it in place.*

</div>

---

## Why

No more round trips — switching to the ChatGPT window, copying, switching back, pasting.
AnywhereLLM is a non-activating panel (NSPanel) that works **while the target app stays frontmost**,
so the original app's focus, cursor, and selection stay alive even as you type into the panel.
The result flows into place via synthesized key events, without ever touching your clipboard.

## Demo

### ✍️ Insert — the response is typed into the input field in real time

Put the cursor in an empty input field and type a request into the panel; the response is streamed as keystrokes into the target app as it arrives.

<img src="docs/assets/demo-insert.gif" width="760" alt="Insert mode demo — Korean typed into the panel, English translation typed live into the chat input">

### 🔁 Replace — turn your selection into the result

Invoke with text selected: review the original and the result in the panel, and the selection is replaced automatically on completion.
You can also refine the result over a multi-turn conversation before applying it. *(hero GIF above)*

### 👀 Read — non-editable content stays in the panel

Select text that has nowhere to insert into — someone else's message, a web page body, a PDF — and the result is shown and kept in the panel.

<img src="docs/assets/demo-viewonly.gif" width="760" alt="View-only demo — selecting a received English message and reading the Korean translation in the panel">

## Features

- **Zero-focus-loss panel** — built on `.nonactivatingPanel`. The target app stays frontmost even while the panel receives key input. The whole reason this app exists.
- **Global hotkey** — <kbd>⌘⇧Space</kbd> by default, configurable in Settings. Press again during streaming to cancel.
- **3 UX modes, chosen automatically** — editability × selection state is determined via the Accessibility (AX) API to pick insert / replace / view-only automatically.
- **Clipboard-untouched writes** — AX insertion first, falling back to synthesized Unicode key-event typing. Never dirties your copy buffer.
- **OpenAI-compatible API** — chat completions SSE streaming. Includes local servers like Ollama, LM Studio, and vLLM.
- **Think-mode handling** — turns off reasoning models' `<think>` output at request time, and blocks it once more with an output filter.
- **Prompt profiles** — save per-purpose system prompts (translation, summarization, proofreading, …) and switch instantly with <kbd>⌘P</kbd> right in the panel.
- **Security first** — when a password field (secure text field) is detected, capture, insertion, and the clipboard fallback are all blocked (cannot be disabled). API keys are stored in the Keychain.
- **Zero dependencies** — AppKit + SwiftUI only, no external packages.

## Installation

### Homebrew (recommended)

```bash
brew install --cask scian0204/tap/anywherellm
```

> **Note** — the app ships self-signed without Apple notarization; the cask removes
> the quarantine attribute automatically during install. If macOS still blocks it as "damaged":
> ```bash
> xattr -dr com.apple.quarantine /Applications/AnywhereLLM.app
> ```

Update with `brew upgrade --cask anywherellm`, uninstall with `brew uninstall --cask anywherellm`.

### Build from source

```bash
git clone https://github.com/scian0204/AnywhereLLM.git
cd AnywhereLLM
make            # release build + assemble build/AnywhereLLM.app + sign
make run        # build, then run
```

> **Tip** — create a self-signed certificate once so the Accessibility permission survives rebuilds:
> ```bash
> scripts/make-signing-cert.sh
> ```
> If the permission gets into a bad state: `tccutil reset Accessibility kr.scian0204.AnywhereLLM`

### Requirements

| | |
|---|---|
| OS | macOS 14 (Sonoma) or later |
| Build | Swift 6.0 toolchain (Xcode Command Line Tools) |
| Permission | Accessibility — guided on first launch |
| LLM | An OpenAI-compatible chat completions endpoint (local or remote) |

## Quick Start

*(The app UI is currently Korean — Korean labels below are quoted as shown in the app.)*

<img src="docs/assets/settings.png" width="380" align="right" alt="Settings window — Base URL, model, think mode, prompt profiles">

1. Menu bar icon → **설정** (Settings) — enter the Base URL, model, and API key
   (for Ollama: `http://localhost:11434/v1` + click **모델 가져오기** (Fetch Models))
2. Put the cursor in any app's text box and press <kbd>⌘⇧Space</kbd>
3. Type a request → <kbd>⏎</kbd> — the response is typed right where your cursor is
4. Invoke **with text selected** for replace mode — the profile acts as the instruction, so an empty <kbd>⏎</kbd> is enough to send
5. <kbd>⌘P</kbd> + <kbd>↑</kbd><kbd>↓</kbd> switches profiles inside the panel, <kbd>Esc</kbd> closes it

<br clear="right">

## How it works

```
⌘⇧Space ──▶ HotkeyManager (Carbon)
               │  captures the target context before the panel shows (order is invariant)
               ▼
        TextTargetService ── AX first, clipboard-backed ⌘C fallback
               │  determines editability × selection state
               ▼
         PromptPanel (.nonactivatingPanel — target app stays frontmost)
               │
               ▼
          LLMClient ── OpenAI-compatible SSE streaming
               │
               ▼
     ThinkTagFilter ──▶ AX setSelectedText (with verification) or
                        CGEvent Unicode typing (clipboard untouched)
```

| Component | Responsibility |
|---|---|
| `HotkeyManager` | Carbon global hotkey registration/reloading |
| `AppDelegate` | Menu bar, Accessibility permission flow, hotkey → panel toggle |
| `TextTargetService` | Target-app text I/O — AX detection, reads, verified writes, Chromium special-casing |
| `PromptPanel` | Focus-preserving NSPanel hosting SwiftUI |
| `ConversationController/View` | Insert/replace/view-only UX branching, multi-turn conversation |
| `LLMClient` | SSE streaming client (`URLSession.bytes`) |
| `KeychainStore` | Keychain storage for the API key |
| `LLMCore` (library) | SSE parser and think-tag filter — the unit-tested part |

There are two targets: the `AnywhereLLM` executable, and `LLMCore`, which isolates just the testable pure logic.
Design decisions and their rationale live in [docs/PLAN.md](docs/PLAN.md); step-by-step implementation notes (including real-world measurements) are in [docs/progress/](docs/progress/).

```bash
swift test      # LLMCore unit tests (SSEParser, ThinkTagFilter)
```

## Security

- **Secure text fields are fully blocked** — when a password field is detected, capture, insertion, and the clipboard fallback are all disabled, and no setting can turn them back on.
- **API keys live in the Keychain** — never stored in UserDefaults or plain-text files.
- **Clipboard untouched** — insertion happens via synthesized key events, so your copy buffer is never polluted. (When the read fallback does use the clipboard, the original contents are backed up and restored.)

## License

[MIT](LICENSE)
