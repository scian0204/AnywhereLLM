# AnywhereLLM 런치 킷 (Launch Kit)

> 각 커뮤니티 규칙에 맞춰 작성 + 적대적 검수(삭제/다운보트 위험, 허위주장 제거)를 거친 **붙여넣기용** 런치 자료.
> 실행 순서·타이밍은 맨 아래 [플레이북](#플레이북-2주-실행안) 참조.
>
> 공통 원칙: 하루 한 채널, 게시 후 48시간 댓글 상주, 논쟁 금지. "회사 캠페인"이 아니라 "만든 사람이 도구를 공유"하는 톤.
>
> **게시는 반드시 본인 실명 계정으로.** 익명/다계정/추천 요청은 astroturf로 감지되어 삭제·shadowban → 역효과.

---

## 1. Hacker News — Show HN  *(removal risk: low)*

**제출 URL:** `https://github.com/scian0204/AnywhereLLM` (사이트 아님, 레포)

**제목 (73자):**
```
Show HN: AnywhereLLM – a macOS menu-bar LLM panel that never steals focus
```

**첫 댓글 (제출 직후 본인이 바로 게시):**
```
I'm the author. AnywhereLLM is a macOS menu-bar app: hit a global hotkey (default Cmd+Shift+Space) in any app and a panel opens to run an LLM on whatever you're working on, then insert or replace text right where your cursor is.

Why I built it: every "AI everywhere" tool I tried popped a window that stole focus. The instant focus moves, your cursor position and text selection in the original app are gone, so the tool can't reliably put its output back where you were. That defeats the point.

The core trick is a non-activating NSPanel (canBecomeKey=true, canBecomeMain=false, ordered front without activating) so the app you were in stays frontmost and its selection stays live while you type into the panel. Output goes back through the Accessibility API when the focused element accepts it, and otherwise via synthesized key events (CGEventKeyboardSetUnicodeString typing into the live selection). Either path means the clipboard is never touched — no clobbering whatever you had copied.

Three modes, chosen automatically from AX editability + selection (GIFs of each in the README):
- cursor in an empty field -> the response is typed in live as it streams
- text selected -> the result replaces the selection in place (you can refine multi-turn first)
- non-editable content (someone's message, a web page, a PDF) -> result is just shown in the panel

Backend is any OpenAI-compatible chat-completions endpoint, so it can run fully local/offline against Ollama, LM Studio, or vLLM — or a remote API if you prefer. API keys live in the macOS Keychain, never plaintext. Password/secure text fields are hard-blocked: capture, insertion, and clipboard fallback are all disabled there, and no setting re-enables it.

Honest caveat: the app is self-signed and NOT Apple-notarized. The Homebrew cask strips the quarantine attribute on install, but if Gatekeeper still blocks it:

    xattr -dr com.apple.quarantine /Applications/AnywhereLLM.app

It's open source (MIT), so you can read it and build it yourself instead of trusting a binary.

Install:

    brew install --cask scian0204/tap/anywherellm

Requires macOS 14+. Native AppKit + SwiftUI, Swift 6, no external dependencies.

Feedback welcome, especially on the AX/insertion edge cases across apps — getting insertion right everywhere (Chromium, Electron, native fields, editors that hide selection from AX) is the hardest part.
```

**대체 제목:**
- `Show HN: AnywhereLLM – LLM in any macOS app without losing your cursor` (68)
- `Show HN: A macOS menu-bar LLM panel that keeps your cursor and selection alive` (78)
- `Show HN: AnywhereLLM – run a local LLM in any macOS field, clipboard untouched` (78)

**게시 노트:**
- 레포 URL 제출(사이트 아님). 첫 댓글 즉시 게시. 화~목 오전 8~10시 ET. 금/주말 회피.
- upvote/star 요청 금지 — HN이 페널티. 첫 1~2시간이 랭킹 결정, 키보드 앞에 상주.
- 미공증 지적 확실히 나옴 → "MIT다, 직접 빌드해라"를 먼저, xattr는 그다음. 논쟁 말고 한계 인정.
- 트래픽 없으면 당일 재게시 금지. hn@ycombinator.com 재노출 요청 가능.

**댓글용 대비 답변:**
- *"왜 Raycast 안 쓰고?"* → 그건 activate돼서 포커스 뺏김. 비활성 패널이 원본 앱을 frontmost로 유지 + 선택 살리는 게 차이점.
- *"진짜 클립보드 안 건드려?"* → 응. AX setSelectedText 또는 합성 유니코드 키. 복붙 왕복 없음.
- *"프라이버시?"* → base URL을 localhost Ollama/LM Studio/vLLM로 = 100% 오프라인. 키는 키체인. 보안필드 하드블록.

---

## 2. Reddit — r/LocalLLaMA  *(removal risk: medium — 가장 중요한 채널)*

**게시 형식:** **텍스트(self) 포스트.** 링크 포스트 금지(광고로 읽힘). Flair: `Resources`(대체 `Other`).

**제목:**
```
Point your local Ollama/LM Studio/vLLM model at any macOS text field — via a hotkey panel that never steals focus (100% offline, MIT)
```

**본문:**
```
I'm a solo dev and I've been building **AnywhereLLM**, a small macOS menu-bar app. It's aimed squarely at people running their own models, so I wanted to share it here and get feedback.

**What it is**

Hit a global hotkey (default `Cmd+Shift+Space`) in *any* app and a panel pops up that **doesn't steal focus** — the app you were in stays frontmost and your cursor + text selection stay alive while you type a prompt. The result goes straight back into whatever you were working in. That "zero focus loss" bit is the whole reason it exists; most tools pop a window that yanks you out of your app.

It talks to **any OpenAI-compatible chat-completions endpoint**, so you point it at Ollama / LM Studio / vLLM and run everything **100% local, offline, no cloud in the loop**. (Remote OpenAI-compatible APIs work too, but that's not why I'm posting here.)

**Why this sub specifically might care**

- Writes results by **synthesizing key events — the clipboard is never touched**, so nothing lands in your pasteboard history.
- API keys (only relevant if you point it at a remote endpoint) live in the **macOS Keychain**, never plaintext.
- Password / secure text fields are **hard-blocked** — capture, insert, and clipboard fallback are all disabled there and can't be re-enabled by any setting.
- **Native AppKit + SwiftUI, zero external dependencies**, Swift 6. Small enough to actually read and build yourself.
- **Free, MIT.**

**Ollama setup (two fields)**

- Base URL: `http://localhost:11434/v1`
- Click **Fetch Models**, pick your model.

That's it. LM Studio / vLLM are the same idea — just their own OpenAI-compatible URL.

**Three modes, auto-chosen** (via the macOS Accessibility API — decided by whether the field is editable and whether you have a selection):

1. **Insert** — cursor in an empty field → the response is typed in live as it streams.
2. **Replace** — text selected → result replaces the selection in place (you can refine multi-turn first).
3. **View-only** — non-editable content (someone's chat message, a web page, a PDF) → result just shows in the panel.

Plus prompt profiles (per-task system prompts — translate / summarize / proofread, switch with `Cmd+P` in the panel), think-mode handling for reasoning models, and a configurable hotkey.

**Honest caveat (not hiding this)**

It's **self-signed and NOT Apple-notarized** — I'm a solo dev and haven't gone through Apple's notarization. The Homebrew cask strips the quarantine attribute on install, so it should just open. If Gatekeeper still blocks it:

```
xattr -dr com.apple.quarantine /Applications/AnywhereLLM.app
```

Or, since it's open source, build it from source and skip the question entirely. I'd rather say this up front.

**Install** (requires macOS 14+)

```
brew install --cask scian0204/tap/anywherellm
```

- Repo: https://github.com/scian0204/AnywhereLLM
- Site with GIFs of all 3 modes: https://scian0204.github.io/AnywhereLLM/

I'm the dev — happy to answer anything. What I'd most like feedback on is which **local models/setups** feel good for the insert/replace flow: streaming latency on smaller models, whether the think-mode handling behaves with your reasoning models, and any OpenAI-compatible endpoint quirks I should handle. Bug reports welcome.
```

**선택 첫 댓글 시드(예상 질문 선점):**
```
A few things people usually ask: (1) yes it streams — Insert mode types tokens into the field live. (2) It never uses the clipboard to write; it synthesizes key events. (3) Secure/password fields are fully blocked and can't be unblocked. (4) Any OpenAI-compatible endpoint works, so LM Studio and vLLM are the same two-field setup as Ollama — just their own local URL. GIFs of all 3 modes are on the site. Roast the model latency for me.
```

**게시 노트:**
- 텍스트 포스트만. star 요청 금지(다운보트). CTA는 "모델/셋업 피드백".
- 로컬-우선 프레이밍이 핵심 — 길이 줄이면 기능부터 자르고 로컬/오프라인/프라이버시는 남길 것.
- 신규/저카르마 계정은 카피 품질과 무관하게 삭제될 수 있음 → 사전에 이 서브에서 진짜 댓글 활동으로 히스토리 쌓기. **첫 몇 시간 상주가 삭제 여부를 좌우.**
- r/ollama, r/macapps와 같은 시간대 동시 게시 금지. 2~3일 간격, 각각 재작성.

---

## 3. Reddit — r/macapps  *(removal risk: medium)*

**게시 형식:** 텍스트 포스트 + 데모 GIF 1개(insert.gif) 첨부. Flair: `Open Source`(1순위) 또는 `Free` — **flair 없으면 자동필터될 수 있음.**

**제목:**
```
AnywhereLLM — translate, rewrite, or summarize in any app from a hotkey panel that never steals focus (native, open source, free)
```

**본문:**
```
I'm a solo dev and this is my side project — saying that up front since it's a self-promo post.

**TL;DR:** A global hotkey (default ⌘⇧Space) opens a small panel that runs an LLM right where you're already typing — translate, rewrite, summarize, or just ask something — without switching apps or copy-pasting into ChatGPT. Point it at a local model (Ollama / LM Studio / vLLM) and it runs fully offline. Native AppKit + SwiftUI, zero dependencies, MIT, free.

---

The loop I got tired of: ⌘-Tab to the browser, paste text into ChatGPT, copy the answer back, fix the formatting. AnywhereLLM removes that round trip. Hit the hotkey in *any* app — Mail, Notes, a code editor, a text field on a webpage — and the panel opens.

**The part I actually care about: it never steals focus.** The panel is a non-activating `NSPanel`, so the app you were in stays frontmost and your cursor + selection stay alive while you type into the panel. Every "AI everywhere" tool I'd tried before popped a window that grabbed focus and killed my selection. This one doesn't — that's the whole reason I built it.

It picks one of three modes automatically (via the Accessibility API, based on whether the field is editable and whether you have a selection):

- **Insert** — cursor in an empty field → the response is *typed* into it live as it streams.
- **Replace** — text selected → the result replaces the selection in place (you can refine it over a few turns first).
- **View-only** — non-editable content (someone's message, an article, a PDF) → the answer just shows in the panel.

**Backend:** any OpenAI-compatible chat-completions endpoint. Local servers — Ollama, LM Studio, vLLM — so it can run 100% offline and private. Or point it at a remote OpenAI-compatible API if you'd rather.

**Privacy / security:**

- Text is written via synthesized key events, so the **clipboard is never touched** — your copy buffer stays yours.
- API keys live in the macOS Keychain, never in plaintext.
- Password / secure text fields are fully blocked — capture, insert, and clipboard fallback are all disabled there, and no setting can turn that off.

**Also in there:** prompt profiles (per-purpose system prompts like translate / summarize / proofread, switch with ⌘P in the panel), think-mode handling for reasoning models, and a configurable hotkey.

**Tech:** 100% native AppKit + SwiftUI, zero external dependencies, Swift 6, macOS 14+. MIT.

**Install (Homebrew):**

```
brew install --cask scian0204/tap/anywherellm
```

Or build from source.

**Honest heads-up:** it's self-signed and *not* Apple-notarized — it's a solo project. The brew cask strips the quarantine attribute on install, so it should open normally. If Gatekeeper still blocks it:

```
xattr -dr com.apple.quarantine /Applications/AnywhereLLM.app
```

It's MIT, so you can read the code and build it yourself instead of trusting my binary.

- Repo: https://github.com/scian0204/AnywhereLLM
- Site + demo GIFs of all three modes: https://scian0204.github.io/AnywhereLLM/

Currently v0.2.3. I'd genuinely like feedback on the focus-preserving approach — especially where it breaks in apps you use.
```

**빠른 답변 스니펫:**
- *"Not notarized?"* → "Correct, it's self-signed — solo project. Brew cask strips quarantine; if Gatekeeper still blocks, `xattr -dr com.apple.quarantine /Applications/AnywhereLLM.app`. It's MIT, build it yourself."
- *"Electron?"* → "No — 100% native AppKit + SwiftUI, zero external dependencies, Swift 6."
- *"Which LLMs work?"* → "Any OpenAI-compatible chat-completions endpoint — local (Ollama/LM Studio/vLLM) or remote."

---

## 4. Reddit — r/MacOS  *(removal risk: medium)*

**게시 형식:** 텍스트 포스트. Flair: `App`(대체 `Discussion`). **게시 전 서브 자기홍보 규칙 확인** — 주간 스레드/최소 카르마 요구 가능.

**제목:**
```
I made a free, open-source menu-bar app that runs any LLM right at your cursor, in any app — without stealing focus
```

**본문:**
```
Hi r/MacOS,

Solo dev here (this is my app, so flagging that up front). I've been building a small menu-bar app called **AnywhereLLM** and wanted to share it.

**TL;DR:** free, open-source, native macOS menu-bar app. A hotkey opens a panel that never steals focus, then types or replaces text right where your cursor already is. Works with local LLMs (Ollama, LM Studio) so it can run fully offline.

The one thing it does differently: you hit a global hotkey (default **Cmd+Shift+Space**) and a small panel appears — but it *never steals focus*. The app you were in stays frontmost, and your cursor and text selection stay exactly where they were. Most tools I tried pop a window that grabs focus and loses your place; avoiding that was the whole reason I built this.

It picks what to do automatically based on where your cursor is:

- **Empty text field** → the response is typed straight into it, live as it streams.
- **Text selected** → the result replaces your selection in place (you can refine it over a couple of turns first).
- **Non-editable content** (someone's message, a web page, a PDF) → the result just shows in the panel.

A few more things:

- Free, open source (MIT), 100% native AppKit + SwiftUI with zero external dependencies. Requires macOS 14+.
- Works with any OpenAI-compatible endpoint — including **local** servers like Ollama or LM Studio, so it can run fully offline and private. Remote APIs work too if you'd rather.
- Privacy details: it writes with synthesized keystrokes, so your clipboard is never touched; API keys live in the macOS Keychain; and password/secure fields are hard-blocked (no setting can turn that off).
- Prompt profiles for translate / summarize / proofread (switch with Cmd+P), plus a configurable hotkey.

**Install (Homebrew):**

```
brew install --cask scian0204/tap/anywherellm
```

**Honest heads-up:** I'm a solo dev, so the app is self-signed and *not* Apple-notarized. The cask removes the quarantine flag on install, but if Gatekeeper still blocks it, run:

```
xattr -dr com.apple.quarantine /Applications/AnywhereLLM.app
```

Since it's open source, you're also welcome to read the code and build it yourself.

- Repo: https://github.com/scian0204/AnywhereLLM
- Site (with demo GIFs): https://scian0204.github.io/AnywhereLLM/

Happy to answer anything — feedback and bug reports welcome.
```

---

## 5. Product Hunt  *(removal risk: low)*

**제출 URL:** `https://scian0204.github.io/AnywhereLLM/`
**이름:** AnywhereLLM
**태그라인 (46자):** `Any LLM in any Mac app — it never steals focus`

**설명 (~260자):**
```
Hit ⌘⇧Space in any Mac app and a panel opens without stealing focus — your cursor and selection stay live. It types the LLM's reply into the field, replaces your selection, or shows it read-only. Point it at local Ollama/LM Studio or any OpenAI-compatible API.
```

**메이커 첫 댓글:**
```
Hey Product Hunt 👋 I'm a solo dev, and AnywhereLLM came out of one small daily annoyance: every LLM tool I tried popped a window that stole focus. The moment it appeared, my cursor was gone and I'd lost my place in whatever I was writing.

So I built the opposite. The panel is a non-activating NSPanel — it takes your keystrokes, but the app you were in stays frontmost with its cursor and selection intact. That "zero focus loss" is the whole reason it exists. Hit ⌘⇧Space anywhere and it picks a mode for you (via the macOS Accessibility API):

- Empty field → the reply is typed straight into the field, live as it streams.
- Text selected → it replaces the selection in place (you can refine multi-turn first).
- Can't edit it (someone's chat message, a web page, a PDF) → it just shows the answer in the panel.

It talks to any OpenAI-compatible chat endpoint, so you can point it at local Ollama / LM Studio / vLLM and keep everything 100% offline and private — or use a remote API.

A few things I cared about under the hood: writes go through synthesized key events, so your clipboard is never touched. API keys live in the macOS Keychain, never plaintext. Password/secure fields are hard-blocked — capture, insert, and clipboard fallback all disabled, and no setting can turn that off. It's native AppKit + SwiftUI, Swift 6, zero external dependencies, MIT-licensed, macOS 14+.

One honest note: I'm a one-person shop, so the app is self-signed, not Apple-notarized yet. The Homebrew cask clears the quarantine flag for you on install; if Gatekeeper still complains, there's a one-line fix — `xattr -dr com.apple.quarantine /Applications/AnywhereLLM.app` — or, since it's open source, you can build it yourself and read every line first.

Install: `brew install --cask scian0204/tap/anywherellm`
Source: https://github.com/scian0204/AnywhereLLM

This is an early release (v0.2.3) and I'd genuinely love your feedback — what feels off, what's missing, and what would make it part of your daily flow. Which app do you switch out of most to talk to an LLM? Thanks for taking a look 🙏
```

**토픽(6):** Mac · Artificial Intelligence · Productivity · Developer Tools · Open Source · Privacy

**갤러리 순서:** ① hero 이미지(썸네일) → ② insert GIF → ③ replace GIF → ④ view-only GIF → ⑤ settings 스크린샷. (움직이는 게 먼저 — PH는 스크롤로 훑음.)

**게시 노트:** 00:01 PT 런치. 첫 댓글 즉시. 하루 종일 응대, 이름 부르며 감사. upvote 요청 금지(피드백 요청만). 태그라인 60자 제한 준수(46자 OK).

---

## 6. X / Twitter 스레드  *(removal risk: low)*

> 전 트윗 ≤280자 검증됨(t.co URL=23자). 스레드로 게시(1번 후 답글로 2~6). 구분선(`——`)은 붙여넣지 말 것 — 트윗 경계 표시일 뿐.

```
1/ 🧵 I built a macOS menu-bar app that puts an LLM in any text field — without ever losing your place.

⌘⇧Space opens a panel that doesn't steal focus: the app you were in stays frontmost, your cursor and selection stay live. Select text, and the result replaces it in place.

[ATTACH GIF: demo-replace.gif]
```
```
2/ Insert

Cursor in an empty field? Type your request in the panel and the reply is typed straight into that field, live as it streams. No copy, no paste, no window-switching.

[ATTACH GIF: demo-insert.gif]
```
```
3/ Replace

Text selected? The result replaces your selection in place — and you can refine it over a few back-and-forth turns before applying.

(that's the clip up top ☝️)
```
```
4/ View-only

Selected something you can't edit — someone's message, a web page, a PDF? The result just stays in the panel to read.

The app picks the mode (insert / replace / view-only) automatically via the macOS Accessibility API.

[ATTACH GIF: demo-viewonly.gif]
```
```
5/ Bring your own model — any OpenAI-compatible endpoint. Point it at local Ollama / LM Studio / vLLM and it runs fully offline.

Writes via synthesized keystrokes, so your clipboard is never touched. API keys stay in the Keychain. Password fields are hard-blocked. #macOS
```
```
6/ Native, zero dependencies, macOS 14+. Free & open source (MIT):
https://github.com/scian0204/AnywhereLLM

brew install --cask scian0204/tap/anywherellm

Self-signed, not notarized — the cask clears quarantine, or build from source yourself. A ⭐ helps a solo dev. #indiedev #opensource
```

**단일 트윗 버전 (275자):**
```
AnywhereLLM: a macOS menu-bar app that puts an LLM in any text field.

⌘⇧Space opens a panel that doesn't steal focus — select text and the result replaces it in place, or it types into an empty field live. Works with local LLMs too.

Free & open source: https://github.com/scian0204/AnywhereLLM
[ATTACH GIF: demo-replace.gif]
```

**게시 노트:** 링크는 마지막 트윗에만(외부 링크 트윗은 도달 억제됨). GIF는 X에 직접 업로드(핫링크 X, 15MB 이하). 각 GIF에 alt-text 추가. 해시태그 트윗당 2~3개만. 몇 시간 뒤 자기 스레드에 사이트 링크 답글로 bump.

---

## 7. lobste.rs  *(removal risk: low — 초대제)*

**제출 URL:** `https://github.com/scian0204/AnywhereLLM`
**제목:** `AnywhereLLM: a macOS menu-bar LLM panel that never steals focus`
**태그:** `show`, `apple`, `privacy` (+ picker에 있으면 `swift`. `macos` 태그는 없음 — 쓰지 말 것.)
**제출 폼에서 "I am the author" 체크 필수.**

**본인 첫 댓글:**
```
Author here.

The app is built around one AppKit detail: the panel is an `NSPanel` created with `.nonactivatingPanel` (`canBecomeKey = true`, `canBecomeMain = false`, shown via `orderFrontRegardless()`), so it takes keystrokes while the app you came from stays frontmost with its cursor and selection still live. It reads the focused field through the Accessibility API and writes back with synthesized key events (`CGEventKeyboardSetUnicodeString`), so insertion never touches the clipboard and replaces the current selection in place.

AX also reports whether the field is editable and whether there's a selection, which picks one of three behaviors automatically: stream tokens into an empty field as they arrive, replace a selection, or just show the result in the panel for read-only content. Secure/password fields are detected and hard-blocked on every path (capture, insert, clipboard fallback), with no setting to turn that off.

It's native AppKit + SwiftUI, Swift 6, zero external dependencies, macOS 14+, MIT. The backend is any OpenAI-compatible chat-completions endpoint, so it runs fully local against Ollama / LM Studio / vLLM, or against a remote API; keys live in the macOS Keychain.

One caveat up front: the build is self-signed and not Apple-notarized. The Homebrew cask (`brew install --cask scian0204/tap/anywherellm`) clears the quarantine bit on install; if Gatekeeper still blocks it, `xattr -dr com.apple.quarantine /Applications/AnywhereLLM.app`, or just build from source. Demo GIFs (insert / replace / view-only) and screenshots are in the README and at https://scian0204.github.io/AnywhereLLM/ — happy to get into the AX / CGEvent details.
```

**주의:** "LLM 도구 피로감" 다운보트 예상 → 비활성 패널 + 클립보드 무접촉 삽입 = 진짜 신규한 부분을 밀 것. 쓰기 클립보드 주장은 "삽입 경로 한정" 유지(읽기는 ⌘C 폴백 있음).

---

## 8. Awesome-list PR  *(removal risk: medium — 슬로우 버닝, 영구 백링크)*

**공통 원칙:**
1. 모든 PR 본문에 `Disclosure: I'm the author.` 명시.
2. **하지 않은 작업을 했다고 쓰지 말 것**(예: "ran the linter clean"). 실제로 `npx awesome-lint` + `markdownlint` 돌리고 통과했을 때만 언급.
3. 섹션명·컬럼·배지 규칙은 **추측** — 실제 README/CONTRIBUTING.md 열어 이웃 항목 포맷 그대로 복사.
4. 0 star라 대형 일반 리스트는 거절 가능 → **주제형 리스트(awesome-ollama, awesome-local-ai) 먼저**, 대형 macOS 리스트는 스타 쌓인 뒤.
5. PR 1개 = 프로젝트 1개, 1줄 diff. 알파벳순 위치("A"). **AnythingLLM(다른 프로젝트)과 혼동 주의.**

**공용 한 줄 설명:**
```
Menu-bar LLM assistant whose global hotkey opens a non-activating panel that never steals focus — insert a reply into the focused field, replace a selection in place, or view results for read-only text, using local (Ollama, LM Studio, vLLM) or any OpenAI-compatible endpoint.
```

**타깃별:**

- **iCHAIT/awesome-macOS** → `Productivity`. 일반 불릿:
  ```markdown
  - [AnywhereLLM](https://github.com/scian0204/AnywhereLLM) - Menu-bar LLM assistant whose global hotkey opens a non-activating panel that never steals focus, letting a local or OpenAI-compatible model insert, replace, or show text in any app.
  ```
- **serhii-londar/open-source-mac-os-apps** → `Productivity`. 불릿 + `Languages:` Swift + `Website:` (아이콘 경로 `./icons/swift-64.png` 확인).
- **EndoTheDev/Awesome-Ollama** → `Assistants` 테이블 행(컬럼 헤더 확인):
  ```markdown
  | [AnywhereLLM](https://github.com/scian0204/AnywhereLLM) | macOS menu-bar assistant; a global hotkey opens a panel that never steals focus, then inserts, replaces, or shows the model's output in whatever app you're in. Open Source :heavy_check_mark: | Homebrew |
  ```
- **janhq/awesome-local-ai** → `User Tools`:
  ```markdown
  - [AnywhereLLM](https://github.com/scian0204/AnywhereLLM) - Native macOS menu-bar app that puts any local OpenAI-compatible model (Ollama, LM Studio, vLLM) behind a global hotkey; its panel never steals focus, so it can insert, replace, or show text in any app.
  ```
- **jaywcjlove/awesome-mac** → `AI Tools`(배지 shorthand `[OSS Icon]`/`[Freeware Icon]` 정식 지원):
  ```markdown
  * [AnywhereLLM](https://github.com/scian0204/AnywhereLLM) - Menu-bar LLM assistant whose global hotkey opens a non-activating panel that never steals focus, letting a local or OpenAI-compatible model insert, replace, or show text in any app. [![Open-Source Software][OSS Icon]](https://github.com/scian0204/AnywhereLLM) ![Freeware][Freeware Icon]
  ```
- **보너스 최고 도달: ollama/ollama README "Community Integrations"** → `Productivity & Apps` 일반 불릿(공식 레포, 커뮤니티 통합 상시 수용):
  ```markdown
  - [AnywhereLLM](https://github.com/scian0204/AnywhereLLM) - macOS menu-bar assistant; a global hotkey opens a non-activating panel that never steals focus and inserts, replaces, or shows model output in any app.
  ```
- **SKIP** `Shubhamsaboo/awesome-llm-apps` — 빌드형 코드/튜토리얼 큐레이션이라 배포 앱 부적합.

---

## 9. GeekNews (news.hada.io) + 한국 커뮤니티  *(removal risk: low)*

**제출 URL:** `https://github.com/scian0204/AnywhereLLM`
**제목:** `AnywhereLLM – 포커스를 뺏지 않는 macOS 메뉴바 LLM 패널 (로컬 LLM 지원)`

**본문:**
```
macOS에서 글 쓰다가 LLM을 부르면 보통 새 창이 뜨면서 포커스를 뺏깁니다. 커서 위치도, 방금 선택해둔 텍스트도 날아가죠. AnywhereLLM은 딱 그 문제 하나를 풀려고 만든 메뉴바 상주 앱입니다.

글로벌 핫키(기본 ⌘⇧Space)를 누르면 포커스를 뺏지 않는 패널이 뜹니다. 방금까지 쓰던 앱이 계속 최상단(frontmost)에 있고, 커서와 선택 영역이 그대로 살아 있는 상태로 패널에 프롬프트를 입력합니다. 이 "포커스 무손실"이 앱을 만든 이유이자 다른 도구와 다른 유일한 점입니다.

## 동작 방식

macOS 접근성(AX) API로 "편집 가능 여부 × 선택 여부"를 보고 3가지 모드를 자동으로 고릅니다.

- 삽입: 빈 입력란에 커서가 있으면 → LLM 응답이 스트리밍되는 대로 그 입력란에 실시간으로 타이핑됩니다.
- 교체: 텍스트를 선택해두면 → 결과가 선택 영역을 제자리에서 대체합니다(여러 턴으로 다듬은 뒤 확정 가능).
- 보기 전용: 편집 불가 콘텐츠(남이 보낸 메시지, 웹 본문, PDF)면 → 결과를 패널에만 표시합니다.

## 기술적으로 흥미로웠던 점

- NSPanel의 `.nonactivatingPanel` + `canBecomeKey=true` / `canBecomeMain=false` 조합으로, 패널이 키 입력을 받으면서도 대상 앱의 frontmost가 유지됩니다.
- 읽기는 AX API로 포커스된 요소에서 하고, 쓰기는 CGEvent 합성 키 입력으로 타이핑합니다. 그래서 쓰기 경로는 클립보드를 전혀 건드리지 않습니다(복사해둔 내용이 안 날아감).
- AX 삽입이 무시되는 앱(Chromium 계열 등)에서도 합성 키 입력으로 폴백해 동작합니다.

## 로컬 LLM / 프라이버시

- OpenAI 호환 chat completions 엔드포인트면 다 붙습니다. Ollama / LM Studio / vLLM 같은 로컬 서버와 동작하므로 100% 로컬·오프라인으로 쓸 수 있고, 원격 OpenAI 호환 API도 됩니다.
- API 키는 macOS 키체인에 저장합니다(평문 저장 안 함).
- 비밀번호·보안 텍스트필드는 캡처/삽입/클립보드 폴백이 전부 차단되며, 어떤 설정으로도 풀 수 없습니다.

## 기타

- 프롬프트 프로필(번역/요약/교정 등 용도별 시스템 프롬프트, 패널에서 ⌘P로 전환)
- 추론 모델용 think 모드 처리, 핫키 변경 가능
- 네이티브 AppKit + SwiftUI, 외부 의존성 0개, Swift 6, macOS 14+

## 설치

brew install --cask scian0204/tap/anywherellm

또는 오픈소스이니 소스에서 직접 빌드해도 됩니다.

## 솔직하게 미리 말씀드리는 부분

이 앱은 자가 서명(self-signed)이고 Apple 공증(notarize)을 받지 않았습니다. brew cask 설치 시 quarantine 속성을 제거하지만, 그래도 Gatekeeper가 막으면 아래 명령으로 풀 수 있습니다.

xattr -dr com.apple.quarantine /Applications/AnywhereLLM.app

숨기지 않고 적어둡니다. 코드가 공개돼 있으니 직접 확인하고 빌드해서 쓰셔도 됩니다. 혼자 만든 도구라 부족한 점이 많을 겁니다. 피드백 환영합니다.

- GitHub (MIT): https://github.com/scian0204/AnywhereLLM
- 소개 페이지 (삽입/교체/보기전용 데모 GIF): https://scian0204.github.io/AnywhereLLM/
```

**타 한국 채널(하루 이틀 간격, 규칙 먼저 확인):**
- **클리앙 「팁과강좌」**: 링크만 던지지 말고 실제 활용 예(선택 텍스트 교정, 로컬 Ollama 연동)를 본문 중심으로. 사용기/튜토리얼 톤.
- **OKKY 「정보/자료」**: GeekNews 본문 거의 재사용 가능. "직접 만든 오픈소스" 첫 줄 명시.
- 공통: "혼자 만든 무료 오픈소스 + 공증 미완료" 먼저 밝히고, star/추천 요청 금지.

---

# 플레이북 (2주 실행안)

## Phase 0 — 사전 준비 (게시 전, 아무것도 올리지 말 것)

- [ ] **소셜 프리뷰 이미지** — GitHub → Settings → General → Social preview. 링크 붙여넣을 때 뜨는 카드. 없으면 회색 Octocat. hero 이미지 1280×640 + 앱명 + 한 줄. *(git으로 못 올림, 이 설정은 웹 UI 업로드.)*
- [ ] README 최상단에 GIF 3개(insert/replace/view-only) 노출.
- [ ] 설치 원라이너 상단 노출: `brew install --cask scian0204/tap/anywherellm`
- [ ] README에 "Is this safe? / Not notarized" 섹션(아래 재사용 답변) 링크.
- [ ] 레포 About + 토픽 설정 *(토픽 16개 이미 설정됨)*.
- [ ] 런치용 깔끔한 릴리스 노트(v0.3.0 고려). `.app` zip을 릴리스 에셋으로 첨부.
- [ ] 이슈 2~3개 생성·고정: ① Roadmap ② "self-signed/not-notarized — why & how to run" (모든 곳에서 링크할 정본 답변) ③ good first issues.

## 재사용 답변 — "공증 안 됐는데 안전한가?" (모든 Mac 채널 최상단 댓글로 나옴)

```
Fair question, and I'd ask it too. Full honesty: the app is self-signed, not Apple-notarized (notarization requires a paid Apple Developer account I haven't bought for a free side project yet).

What that means practically:
- The Homebrew cask strips the quarantine flag on install, so `brew install --cask scian0204/tap/anywherellm` should just work.
- If Gatekeeper still blocks it: `xattr -dr com.apple.quarantine /Applications/AnywhereLLM.app`

Why I think it's still trustworthy: it's fully open source (MIT) — you can read every line and build it yourself in one command. On privacy: it can run 100% local against Ollama/LM Studio/vLLM (no network at all), API keys live in the macOS Keychain (never plaintext), it writes via synthesized key events so it never touches your clipboard, and secure/password fields are hard-blocked — capture, insert, and clipboard fallback are all disabled there and can't be re-enabled by any setting.

If notarization is a dealbreaker for you, building from source sidesteps it entirely. Notarization is on the list once there's enough usage to justify the dev account.
```

## Phase 1 — 게시 순서 (월요일 기준, 상대 순서·시간대 로직 유지)

| 일 | 채널 | 시각 | 비고 |
|---|---|---|---|
| **월** | r/LocalLLaMA (텍스트) | 9~11am ET | 홈 그라운드·시드 청중. 이걸로 톤 설정. |
| **화** | X/Twitter 스레드 | 9~10am ET | GIF 직접 업로드. 링크는 자기 답글로. |
| **수** | lobste.rs | 9~11am ET | 초대 있을 때만. 기술 앵글. |
| **목** | r/macapps | 9~11am ET | 제목·첫 문단 LocalLLaMA와 다르게. |
| **금** | (휴식·댓글 처리) | — | 버그 픽스 → "하루 만에 수정" 사회적 증거. |
| **주말** | GeekNews (선택) | KST 저녁 | 한국어 런치. |
| **월(2주차)** | **Show HN** | 8~10am ET 평일 | 최고 정밀도 샷. 첫 댓글에 미공증 선제 고지. 당일 다른 것 게시 금지. |
| **수(2주차)** | Product Hunt | 00:01 PT | 하루 종일 몰입. |
| **목~금(2주차)** | r/MacOS + Awesome-list PR | 9~11am ET | 슬로우 버닝 백링크. |

**순서 이유:** 관대한 홈 청중(r/LocalLLaMA)으로 시드 → 스타·이슈 쌓인 뒤 고정밀 채널(Show HN, PH). 40스타 레포가 0스타보다 방문자를 훨씬 잘 전환. Reddit 서브는 2~3일 간격(같은 날 2개 서브 금지). Show HN·PH 같은 날 금지.

## 크로스포스트 에티켓 (Reddit shadowban 방지)

- 신규/저카르마 계정은 자동필터됨 → 1~2주 전부터 해당 서브에서 진짜 댓글 활동.
- 각 서브 규칙·자기홍보 정책 먼저 읽기. flair 필수인 곳 있음.
- 서브 간 2~3일 간격. **동일 제목/본문 재사용 금지** — 첫 문단·순서 재작성.
- 링크 단축기 금지(raw github.com). 게시 15분 후 로그아웃/시크릿으로 노출 확인 → 안 보이면 필터됨, 재게시 말고 모드에 정중히 승인 요청.
- 다계정 자추/DM 추천 요청 금지(계정 정지).

## 방문자 → 스타 전환 (정직하게)

- 상단 GIF가 전환 엔진. "원본 앱이 frontmost 유지되며 패널에 타이핑" 순간이 3초 안에 보여야.
- 첫 문단에 가치 명시(뭐하는 건지 + 무료/MIT + 로컬). 하이프워드 금지.
- brew 원라이너로 30초 체험 → 실행한 사람이 스타.
- 각 글 끝에 정직한 스타 한 줄만: *"If it's useful to you, a star helps me know it's worth maintaining."* 이게 상한선.
- 런치 주에 가시적 버그 픽스 → 최고의 전환 레버.
- 금지: 스타 게이팅, 스타 팝업, 스타 구매, star-for-star.

## 게시 후 48시간

- 첫 2~3시간 상주(초기 참여가 랭킹 결정). 잘 시간 직전 게시 금지.
- 모든 댓글·질문에 빠르고 기술적으로 응대. **논쟁 절대 금지** — "왜 X 안 쓰고", "self-signed=악성코드"는 재사용 답변으로 한 번만, 담백하게, 이후 넘어감.
- 기능 요청·버그는 roadmap 이슈에 공개 기록. 48h 내 버그 픽스 가능하면 픽스 + 보고자에게 알림.

## 현실적 기대치

- **대부분의 런치는 느리다 — 그게 기본, 실패 아님.** 중앙값 Show HN은 업보트 몇 개.
- **좋은 결과(2주):** GitHub 스타 ~50~300, 한 채널 프론트페이지 순간, 진짜 버그 리포트 몇 개, 소스 빌드/PR 1~2명, 런치 후에도 스타 소량 지속(이 지속성이 스파이크보다 중요).
- **훌륭한 결과:** 한 채널 진짜 히트(Show HN 프론트 몇 시간 / LocalLLaMA 실제 토론) → 500~2,000 스타 + awesome-list 등재로 몇 달간 트래픽.
- **바이럴은 운, 계획 아님.** 최적화 대상: 앱이 진짜다 + 데모가 명료하다 + 응대가 정직·빠르다. 이게 복리.
- 에너지 관리: 2주 상주는 혼자서 지침. "내일 다시 올게요" 괜찮음. 번아웃이 게시 부진보다 큰 리스크.
