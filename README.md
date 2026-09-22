# MicType 🎤 — Speak to Type. Hold to Command.

**Voice input for macOS that doubles as your AI entry point.** One key, two gestures: **tap** the hotkey and your speech becomes clean, punctuated text at the cursor. **Hold** the same key and your voice becomes an instruction to AI: rewrite the selection, draft a reply, compose an email, translate, ask anything — right where you're working, in any app.

See a live draft while you are still speaking, and dictate for up to ten minutes without losing a word. Setup is one decision: which AI provider transcribes and polishes your speech — OpenAI or Alibaba Cloud.

> **⬇️ Just want to use the app? [Download it from Releases](https://github.com/genli-ai/MicType/releases/latest) — no Xcode, no build step.**
> The green "Code" button downloads the *source code*; building from source is for developers and requires full Xcode.

**中文说明在下方。**

## Two Gestures

**Tap Right Option (⌥) = dictation.**

```
Tap ⌥ → speak (a live grey draft shows what your provider is hearing) → tap ⌥ again
   ↓
Realtime cloud transcription (your chosen provider — see Recognition & Providers)
   ↓
Optional adaptive AI polish (remove fillers, fix homophone errors,
restructure long rambling speech into ready-to-use text)
   ↓
Clean text appears at your cursor
```

**Hold Right Option (⌥) = voice command.** Speak while holding, release to run. With text selected, AI infers what you want from what you say — no fixed magic words:

- *"make it more formal"* / *"translate to English"* → the **selection is rewritten** in place
- *"reply to him: agree, but push it to next week"* → a ready-to-send **reply draft** lands on your clipboard, press ⌘V
- *"based on this, write a congratulations message"* → **new text** is typed at your cursor, selection used as reference
- Nothing selected → free-form AI at your cursor: draft an email, translate, or just ask a question

Tap is always pure dictation (what you say is what gets typed), hold is always a command — that part is decided by gesture, never by guessing. Recording starts the moment you press the key, and audio starts streaming to your provider right away. Esc cancels at any point — while recording, and while MicType is transcribing, polishing or running a command — but audio already sent to the provider can't be recalled.

## Why MicType

- **See what it hears, as you say it** — a grey draft appears in the floating indicator while you are still talking, built from your provider's own streaming results. It never goes into your document: the inserted text is always the finished transcription.
- **Cloud speech recognition, streamed live** — every take is a realtime connection to your provider: audio goes up while you're still talking, so releasing the key returns a transcript almost instantly no matter how long you spoke. There is no on-device option in this version; your audio always leaves your Mac.
- **Two providers, and that's the whole choice** — OpenAI (`gpt-live-transcribe` recognition, `gpt-5.6-luna` polish and commands) or Alibaba Cloud Bailian (`qwen3-asr-flash-realtime` recognition, `qwen3.8-flash` polish and commands). Pick one, paste one key, and MicType is fully set up.
- **Never lose a word** — dictate for up to **ten minutes**, with a warning before the limit. Your clipboard (images, files, formatted text) is captured and restored around every insertion, and changing microphone mid-recording doesn't lose the take.
- **Cancel at any point** — Esc, the menu bar, or a click on the indicator stops recording, transcription, polish or a running command; nothing already sent is inserted afterwards, and unsent audio simply never goes anywhere.
- **Voice commands in any app** — the hold gesture works wherever your cursor is: chat, mail, docs, browser.
- **Adaptive AI polish, with a safety net** — short phrases get light cleanup; long rambling speech is restructured into ready-to-use text. If the polished version drifts from what you said (numbers, negations), MicType inserts the raw transcript and tells you — and for a minute afterwards the menu bar can swap a polished insertion back to the raw transcript.
- **Custom vocabulary as hotwords** — names, brands, and jargon are fed into AI polish (and into recognition itself on OpenAI); the #1 lever for proper-noun accuracy. Add `wrong=right` (or `wrong1|wrong2=right`) for homophones that no model gets right. Lives in the menu bar under **Writing Preferences…**, alongside a free-text box for your standing instructions to the AI (*sign as Gen*, *keep English jargon untranslated*).
- **Searchable history** — the last 200 dictations stay on your Mac (⌘Y): search raw and polished text, re-insert an old result at the cursor, or send a mis-heard word to your vocabulary. Turn it off or clear it any time.
- **One key, named in full** — the hotkey is **Right Option (⌥)**. There is no picker to get wrong: every place MicType asks you to press a key names that one.
- **Setup is one decision** — pick **OpenAI** or **Alibaba Cloud**, paste a key, and it's verified on the spot; keys live in the macOS Keychain. An API key is required for MicType to work at all — recognition itself now runs on your chosen provider.
- **Settings you can read in one glance** — Settings is a single page: provider, API key, and (for Alibaba Cloud) an optional API host. A permissions banner appears only when something's missing; a status line shows exactly what's connected and what it costs. Everything else — writing preferences, about, check for updates, review the guide — is one click away in the footer.
- **A first run that finishes the job** — a five-screen guide: welcome (the two gestures, on Right Option), permissions, choose your AI (both providers side by side, with step-by-step instructions for getting a key and paste-to-verify), a dictation you try on the spot, and where to find MicType afterward. It is not over until dictation actually works: permissions granted and a verified provider. You can walk through it again any time from the Settings footer.
- **Bilingual UI** — English / 中文, switch instantly from the menu bar.

## Quick Start (5 minutes)

Everything downloads from one page: **[Releases · latest](https://github.com/genli-ai/MicType/releases/latest)**

| | 🍎 macOS (Apple Silicon, macOS 15+) | 🪟 Windows (Win10 22H2+ / 11, x64 — beta, still on-device) |
|---|---|---|
| **1. Download & run** | `MicType-{version}-arm64.zip` → unzip → drag `MicType.app` to Applications. If blocked: System Settings → Privacy & Security → **Open Anyway** | `MicType-{version}-win-x64.zip` → unzip → run `MicType.exe`. SmartScreen: **More info → Run anyway** |
| **2. One-time setup** | A five-screen first-run guide does all of it: learn the two gestures on **Right Option (⌥)**, allow **Microphone** (with a live level meter) and enable **Accessibility** (System Settings → Privacy & Security), choose OpenAI or Alibaba Cloud and paste a key (verified there and then), and try a dictation on the spot — the text lands in the box on the page. The guide only finishes once dictation actually works | Right-click the tray icon → Settings → download the speech model (~250 MB) |
| **3. Speak** | **Tap Right Option (⌥)** → talk → tap again. Text appears at your cursor | **Tap Right Ctrl** → talk → tap again. Text appears at your cursor |

Speech recognition streams to the provider you set up — there's no local recognition in this version, so audio always leaves your Mac. Settings → About → **Check for Updates** — on macOS it verifies the new build, installs it in place and relaunches.

## Install

Requirements: **Apple Silicon + macOS 15+**. (Building from source additionally needs full Xcode.)

**Prebuilt (recommended):** download `MicType-{version}-arm64.dmg` from [GitHub Releases](https://github.com/genli-ai/MicType/releases/latest), open it, and drag `MicType.app` to Applications. The DMG is **notarized by Apple — it opens with zero security warnings**. (A `.zip` is also attached — Developer ID signed but not notarized, so the first launch may need System Settings → Privacy & Security → **Open Anyway**.)

**From source, two steps:**

1. Double-click `Install MicType.command`. There are no third-party dependencies to build, so the first compile takes under a minute.
2. Open the app and follow the first-run guide, or paste an API key for OpenAI or Alibaba Cloud in Settings.

## First Launch Permissions

| Permission | Why It Is Needed | How to Enable |
|------------|------------------|---------------|
| Microphone | Record your speech | Click Allow in the macOS prompt |
| Accessibility | Global hotkey, reading the selection, inserting text | System Settings → Privacy & Security → Accessibility → enable MicType |

If the hotkey still does not work after Accessibility appears enabled, remove MicType from the Accessibility list, add `/Applications/MicType.app` again, then quit and reopen MicType.

## Recognition & Providers

MicType has no on-device speech model. Every dictation and voice command runs through the AI provider you set up in Settings — pick **OpenAI** or **Alibaba Cloud (Model Studio / Bailian)**, paste one key, and that key covers recognition, polish and voice commands alike.

- **The connection opens the moment you press the key.** Audio streams up in small frames while you're still talking, so releasing the key sends only a short "finish" signal — the final transcript comes back in well under a second, independent of how long you spoke. The grey live draft comes from the provider's own interim results, arriving roughly every couple of seconds.
- **Two providers, genuinely different.** Alibaba Cloud (`qwen3-asr-flash-realtime`) is the faster, cheaper choice — but it does not honor your custom vocabulary during recognition, so proper nouns there are fixed afterward by AI polish (which always gets your vocabulary) and by `wrong=right` replacements. OpenAI (`gpt-live-transcribe`) costs more but does honor your vocabulary during recognition itself, which is the more reliable path for names, brands and jargon.
- **Alibaba Cloud has an optional API Host field** (OpenAI does not) — leave it blank and MicType finds and remembers the fastest working endpoint for your key on its own, rechecking quietly about once a week; fill it in to pin MicType to exactly that host (from the address shown on the Model Studio API Key page) with no auto-switching.
- **Falling back is silent.** If a connection has no realtime support or a request fails, MicType retries and, if needed, falls back to a whole-take upload instead of interrupting what you're saying.
- **Verified in one action.** Pasting a key runs a real check against the provider; a key that doesn't verify is never saved, and the status line always reflects what's actually working.

**Arabic** is supported: Modern Standard Arabic works well; other dialects are not promised. English brand and product names spoken inside Arabic can come back written in Arabic letters — add them to your custom vocabulary under **Writing Preferences…** in the menu bar to fix this.

## Long Dictation

A single take can run up to **ten minutes**, with a warning before you reach the limit. Because audio streams to your provider continuously while you speak, releasing the key returns a transcript almost immediately regardless of length — there's no separate "long recording" processing step. Esc stops the recording at once, but audio already sent to the provider can't be recalled, so whatever was transcribed up to that point is what you get.

## AI: Polish, Commands, and Your Provider

Menu bar 🎤 → Settings. The whole page is: **provider** (OpenAI or Alibaba Cloud), **API key** (verified as you paste it — Checking… / Connected ✓ / Failed, with the reason and what to do), and for Alibaba Cloud one more optional row, **API Host**. A status line under it names what's live and what it costs. There is nothing else to configure — model, polish behavior, and web search are fixed choices, not settings:

- **One model per provider, already balanced for speed**: `gpt-5.6-luna` on OpenAI, `qwen3.8-flash` on Alibaba Cloud — both chosen because polish and commands run on every single utterance, and a model that thinks for several seconds is a worse experience than one that answers in two.
- **Web search is always on** where the provider supports it, for hold-to-command only (tap-to-dictate polish never searches) — about $0.01 per search on OpenAI, billed at Alibaba Cloud's own rates there.
- **OpenAI always runs on its Fast tier** — lower, steadier latency at roughly twice the per-token price, stated once under About → Privacy.

**Writing Preferences…**, reached from the menu bar (or the Settings footer), is where you manage what's actually yours to configure:

- **Custom vocabulary**: hotwords for names, brands and jargon — used by recognition on OpenAI, and always by AI polish on both providers, since polish is what fixes proper nouns on Alibaba Cloud.
- **Custom rules**: a free-text box of standing instructions to the AI (*sign as Gen*, *keep English jargon untranslated*), applied to every polish and every voice command.

Polish modes: transcribe only (fastest, no AI) or AI polish (adaptive: light cleanup for short phrases, full restructuring for long spoken paragraphs) — selected automatically per utterance, not a setting you pick.

## Privacy

- **Your audio streams to your chosen provider live, the moment you speak.** There is no local recognition in this version — this is a deliberate trade for the speed and quality of realtime cloud transcription, and it's stated plainly here rather than as a switch you have to find.
- The recognized **text** is then sent to the same provider for AI polish or a voice command. On OpenAI, MicType sends `store: false` on every request, so your text is not retained for the 30 days the API otherwise keeps it.
- API keys are stored in the macOS Keychain, not in plain-text files, and are never included in a settings export.
- Transcript history is kept on your Mac only; you can switch it off or clear it at any time.
- Web search is on by default where your provider offers it, billed per search by that provider — the price is stated next to it in Settings, and only hold-to-command ever searches.
- You pay your provider directly at their rates, roughly **$0.2/hour** on Alibaba Cloud or **$1.1/hour** on OpenAI for recognition plus polish combined, billed by how much you actually spoke. MicType never proxies your requests and never adds a fee.

## Upgrading from an earlier version

If you're updating from a 4.x release, MicType removes the old on-device speech model files on first launch and tells you how much disk space that freed. If you were using DeepSeek or a local model, you'll land on the "choose your AI" screen of the first-run guide to pick OpenAI or Alibaba Cloud — everything else about your setup (hotkey, vocabulary, history) carries over unchanged.

## FAQ

**Hotkey does not respond?** Check System Settings → Privacy & Security → Accessibility. If you build from source (ad-hoc signing), macOS usually requires removing the old permission entry and adding the app again after each rebuild; official notarized releases keep a stable identity, so upgrades don't need this.

**Custom names or terms are wrong?** Add names, brands, products, and technical terms to Writing Preferences… → Custom vocabulary (menu bar). It's used by recognition on OpenAI, and always by AI polish (Alibaba Cloud's recognizer doesn't take hotwords, so polish does the correcting there). This is also the fix for English brand names spoken inside Arabic.

**AI polish failed, or MicType can't recognize speech at all?** Settings shows the connection state next to your key — enough to tell a bad key from a wrong region, rate limiting or exhausted credit. Since recognition itself now depends on your provider, a failed connection means dictation won't work either until the key is fixed.

**Text was not inserted into the target app?** If you switch windows during processing, MicType tries to bring the original app back before pasting. If insertion still fails, click the latest item in Menu bar → Recent Transcripts to copy it. Some fields, such as password fields, block paste.

**Build fails with `Invalid manifest` or `PackageDescription` link errors?** Your Xcode command line tools may be broken, often after a system upgrade. Double-click `scripts/Fix Build Tools.command`.

## Uninstall

Double-click `Uninstall MicType.command`.

## Tech Stack

Native Swift menu bar app with SwiftUI settings · realtime cloud speech recognition (OpenAI `gpt-live-transcribe` / Alibaba Cloud `qwen3-asr-flash-realtime`, audio streamed as you speak, endpoint auto-detected for Alibaba Cloud) · OpenAI Responses API and Alibaba Cloud Chat Completions for polish & commands · macOS Keychain · bilingual in-line L10n.

```
MicType/
├── Package.swift                  # Swift Package definition (no third-party dependencies)
├── Sources/MicType/
│   ├── main.swift                 # Entry point
│   ├── AppDelegate.swift          # App wiring, menu bar icon, Dock/menu-bar behavior
│   ├── AppMenu.swift               # App/Edit menu (so ⌘C/⌘V/⌘Z work in MicType's own windows)
│   ├── DictationController.swift  # Recording → transcription → polish/skills → insertion
│   ├── HotkeyManager.swift        # Global hotkey: tap = dictate, hold = command, Esc cancel
│   ├── AudioRecorder.swift        # 16 kHz recording and level monitoring
│   ├── SpeechEngine.swift         # Recognition protocol implemented by the cloud engines
│   ├── CloudASR/                  # OpenAI + Alibaba Cloud realtime clients, endpoint detection, WAV encoding
│   ├── LLMCatalog.swift           # Model ids, pricing and per-provider capabilities in one place
│   ├── PolishService.swift        # Adaptive AI polish
│   ├── AgentService.swift         # LLM client + voice-command skills (intent-inferred selection commands / reply / free-form)
│   ├── SkillRouter.swift          # Explicit reply-trigger fast path
│   ├── SelectionReader.swift      # Read selected text via Accessibility (⌘C fallback)
│   ├── TextInserter.swift         # Clipboard + ⌘V insertion, full clipboard snapshot/restore
│   ├── OwnWindowInserter.swift    # Direct text insertion into MicType's own windows
│   ├── Overlay.swift              # Floating indicator (live draft, elapsed time, cancel)
│   ├── HistoryStore.swift         # Last 200 transcripts, raw + polished, on disk
│   ├── HistoryWindow.swift        # History window: search, compare, re-insert, add to vocabulary
│   ├── OnboardingWindow.swift     # First-run guide (five screens: welcome, permissions, choose your AI, try it, where to find it)
│   ├── FirstRunEssentials.swift   # What the first run must finish: permissions, a working provider
│   ├── LocalModelCleanup.swift    # One-time cleanup of pre-5.0 on-device model files
│   ├── UpdateChecker.swift        # Update check + verify, install and relaunch
│   ├── SettingsBackup.swift       # Settings export / import (shared JSON with Windows)
│   ├── Localization.swift         # In-line bilingual L10n (instant switch, from the menu bar)
│   ├── SettingsView.swift         # Settings window sizing and routing
│   ├── SettingsEditors.swift      # The single settings page + Writing Preferences + About
│   ├── CloudAIFields.swift        # Provider/key/host controls shared by Settings and onboarding
│   └── SettingsCopy.swift         # Every caption and ⓘ in Settings, under a budget a test enforces
├── Resources/                      # Info.plist, app icon, notification sounds
└── Package.resolved                # Locked dependency versions

scripts/                       # Repair tools
MicTypeWindows/                # Windows port (C# / .NET, public beta — still on-device SenseVoice, not yet on 5.0)
Install MicType.command       # One-click installer (build from source)
Uninstall MicType.command     # Uninstaller
```

> 🪟 **Windows (public beta):** download `MicType-{version}-win-x64.zip` from [Releases](https://github.com/genli-ai/MicType/releases/latest) — local SenseVoice recognition, tap Right Ctrl to dictate. This build has not yet moved to the cloud-only architecture described above. Windows 10 22H2+ / 11 x64; first run downloads a ~250 MB speech model in Settings; SmartScreen will warn (unsigned beta) — More info → Run anyway. Upgrades are one click via Settings → About → Check for Updates. Details: [MicTypeWindows/](MicTypeWindows/)
> **Windows 版（公开测试）**：从 [Releases](https://github.com/genli-ai/MicType/releases/latest) 下载 `MicType-{版本}-win-x64.zip`——本地 SenseVoice 识别，轻点右 Ctrl 听写。这一版尚未跟进上面说的云端化架构。Win10 22H2+/11 x64；首次在设置里下载约 250MB 识别模型；SmartScreen 拦截时点「更多信息 → 仍要运行」。之后升级在 设置 → 关于 → 检查更新 一键完成。

## Author

Built by **Gen** — [genli-ai.github.io/portfolio](https://genli-ai.github.io/portfolio/) · [ligen.thu@gmail.com](mailto:ligen.thu@gmail.com)

## Credits and License

This project was designed, implemented, debugged, and refined with AI collaboration. MIT License.

---

# MicType 🎤 — 轻点听写，按住说指令

**Mac 语音输入法，也是你的 AI 入口。** 一个键，两种手势：**轻点**快捷键，说话变成干净、带标点的文字出现在光标处；**按住**同一个键，说出的话就是给 AI 的指令——改写选中文字、草拟回复、写邮件、翻译、随口提问，在任何应用里、就在你正在打字的地方。

说话过程中就看得见草稿，一口气说十分钟也不丢字，配置只有一个决定：识别与润色交给哪家 AI 服务商——OpenAI 还是阿里云。

> **⬇️ 只是想用？[去 Releases 下载现成的 App](https://github.com/genli-ai/MicType/releases/latest)——不需要 Xcode、不需要编译。**
> 绿色 "Code" 按钮下载的是*源代码*；从源码安装只面向开发者，需要完整 Xcode。

## 两种手势

**轻点 右 Option (⌥) = 听写**

```
按 右⌥ → 说话（悬浮窗里灰字实时草稿，来自服务商自己的中间结果）→ 再按 右⌥
   ↓
实时云端识别（你选定的服务商——见「识别与服务商」）
   ↓
可选自适应 AI 润色（去口头禅、修同音错字，
长段混乱口述自动重构成可直接使用的成品文字）
   ↓
干净的文字出现在光标处
```

**按住 右 Option (⌥) = 语音指令**——按住说话，松手执行。选中文字后随便怎么说，AI 自动听懂你要什么，不需要固定句式：

- 「改得正式一点」「翻译成英文」→ **选区原地被改写**
- 「回复他：同意，但推到下周」→ 可直接发送的**回复草稿**进剪贴板，按 ⌘V 即贴
- 「根据这段写一条祝贺消息」→ **新内容**打在光标处，选中文字只作参考
- 什么都没选 → 光标处的自由 AI：草拟邮件、翻译、或者直接问问题

轻点永远是纯听写（说什么打什么），按住永远是指令——这一层靠手势区分，永不猜测。按下那一刻就开始录音，音频也当场开始往服务商那边传。Esc 随时取消——录音中可以，识别中 / 润色中 / 执行指令中同样可以——但已经传出去的那部分音频收不回来。

## 为什么选 MicType

- **边说边看**——说话过程中悬浮窗就显示灰字草稿，来自服务商自己的实时中间结果。草稿绝不进入你的文档：真正插入的永远是完整识别的结果
- **云端识别，边说边传**——每一次听写都是一条实时连接：你还在说的时候音频就在往上传，所以松手后几乎立刻拿到结果，与说了多久无关。这一版没有本地识别可选，录音一定会离开这台 Mac
- **两家服务商，就这两家**——OpenAI（识别用 `gpt-live-transcribe`，润色与指令用 `gpt-5.6-luna`）或阿里云百炼（识别用 `qwen3-asr-flash-realtime`，润色与指令用 `qwen3.8-flash`）。选一家、贴一把 Key，MicType 就配好了
- **一个字都不丢**——单次可以说到**十分钟**，到点前会提前提醒。每次插入前后完整快照并还原剪贴板（图片、文件、富文本都不会被吃掉）；录音中途换麦克风也不丢这一段
- **任何阶段都能取消**——Esc、菜单栏、或者直接点悬浮窗：录音中、识别中、润色中、执行指令中都能停，已经传出去的不会再插进来，没传出去的干脆就没送到任何地方
- **任何应用里都能下指令**——光标在哪，按住就在哪用：聊天、邮件、文档、浏览器
- **自适应 AI 润色，带安全网**——短句轻清理；长段混乱口述重构成可直接使用的成品文字。润色结果若与原话出入过大（数字、否定词被改动）会自动改输出识别原文并明说；插入后一分钟内还能在菜单栏一键「换回识别原文」
- **专有词汇表 = 热词**——人名、品牌、术语送进 AI 润色（在 OpenAI 上还会直接参与识别），是专有名词准确率的第一杠杆。完全同音的词可以写 `错写=正写`（一个正写挂多个错写：`错1|错2=正写`）。这两样都收在菜单栏的**「写作偏好…」**里，旁边还有一个自由文本框，写给 AI 的长期偏好（「署名用 Gen」「英文术语保留原文」）
- **可搜索的历史**——最近 200 条听写留在本机（⌘Y）：按识别原文和润色结果一起搜，重新插入到光标处，或把听错的词一键送进词汇表。随时可关、可清
- **快捷键就一颗：右 Option (⌥)**——没有选择器可选错，凡是让你按键的地方写的都是它且写全名
- **配置只有一个决定**——选 **OpenAI** 还是 **阿里云**，粘贴一把 Key 当场验证，Key 存 macOS 钥匙串。这把 Key 是必须的：识别本身现在就跑在你选的服务商上
- **设置一眼看完**——设置就是一页：服务商、API Key、（阿里云的）可选接入地址。有事要办才出现权限横幅；一行状态文字写清此刻连的是谁、多少钱。写作偏好、关于、检查更新、重看引导都在页底一键可达
- **引导不走到能听写不算完**——首次启动五屏：欢迎（两种手势，就在右 Option 上）→ 权限 → 选你的 AI（两家并排的卡片，带申请 Key 的步骤说明，粘贴即验证）→ 就地试一句 → 它在哪。两项权限都给了、一家服务商验证通过，这两件事办完才算走完，设置页底部随时能重走一遍
- **中英双语界面**——菜单栏里即时切换

## 快速上手（5 分钟）

所有下载都在一个页面：**[Releases · latest](https://github.com/genli-ai/MicType/releases/latest)**

| | 🍎 macOS（Apple Silicon，macOS 15+） | 🪟 Windows（Win10 22H2+/11，x64，公测，仍是本地识别） |
|---|---|---|
| **1. 下载运行** | `MicType-{版本}-arm64.zip` → 解压 → 把 `MicType.app` 拖进应用程序。被拦时：系统设置 → 隐私与安全性 → **「仍要打开」** | `MicType-{版本}-win-x64.zip` → 解压 → 运行 `MicType.exe`。SmartScreen 拦截点 **「更多信息 → 仍要运行」** |
| **2. 一次性设置** | 首次启动的五屏引导会带着走完：先在**右 Option（⌥）**上学会两种手势，允许**麦克风**（当场看电平条）、开启**辅助功能**（系统设置 → 隐私与安全性），选 OpenAI 或阿里云并粘贴 Key（当场验证），最后就地试说一句，文字直接落进那一屏的框里。引导要到**真的能听写**才算走完 | 右键托盘图标 → 设置 → 下载识别模型（约 250MB） |
| **3. 开口说话** | **轻点右 Option（⌥）**→ 说话 → 再点一下，文字出现在光标处 | **轻点右 Ctrl** → 说话 → 再点一下，文字出现在光标处 |

语音识别跑在你配好的服务商那边——这一版没有本地识别，录音一定会离开这台 Mac。升级：设置 → 关于 → **检查更新**——Mac 端会验签后就地安装并自动重启。

## 安装

要求：**Apple Silicon + macOS 15+**（从源码编译另需完整 Xcode）。

**预编译包（推荐）**：从 [GitHub Releases](https://github.com/genli-ai/MicType/releases/latest) 下载 `MicType-{版本}-arm64.dmg`，打开后把 `MicType.app` 拖进应用程序。DMG **已通过 Apple 公证，打开零拦截、零警告**。（同时附有 `.zip`：Developer ID 签名但未公证，首次打开可能需要到 系统设置 → 隐私与安全性 → **「仍要打开」**。）

**源码安装两步**：

1. 双击 `Install MicType.command`。没有第三方依赖要编译，首次编译不到一分钟。
2. 打开 App，跟着首次启动引导走，或者直接在设置里为 OpenAI / 阿里云粘贴一把 Key。

## 首次启动授权

| 权限 | 用途 | 怎么开 |
|------|------|--------|
| 麦克风 | 录音 | 弹窗点「允许」 |
| 辅助功能 | 全局快捷键、读取选中文本、自动输入文字 | 系统设置 → 隐私与安全性 → 辅助功能 → 打开 MicType |

如果系统设置里显示已开启但快捷键仍失效：在辅助功能列表中删除 MicType，重新添加 `/Applications/MicType.app`，然后退出并重新打开 MicType。

## 识别与服务商

MicType 没有本机识别模型。听写和语音指令全都跑在你在设置里配好的那家 AI 服务商上——选 **OpenAI** 或 **阿里云百炼（Model Studio）**，贴一把 Key，识别、润色、语音指令共用这一把。

- **按下热键那一刻连接就建好了。** 你还在说话时音频就以小帧持续往上传，松手只再发一条简短的 *finish* 信号——终稿在一秒以内回来，与你说了多久无关。悬浮窗里的灰字草稿来自服务商自己的中间结果，大约每隔几秒来一次。
- **两家真的不一样。** 阿里云（`qwen3-asr-flash-realtime`）更快也更便宜，但识别阶段不认你的词汇表，专有名词要靠 AI 润色（永远带着你的词汇表）和「错写=正写」事后纠正。OpenAI（`gpt-live-transcribe`）更贵，但识别本身就认你的词汇表，人名、品牌、术语更稳。
- **只有阿里云多一个可选的「接入地址」输入框**（OpenAI 没有）——留空，MicType 会自己找到并记住这把 Key 能用的最快那台，大约每周悄悄复查一次；填了，就只用你填的那一台，不再自动换。
- **回落是静默的。** 某条连接不支持实时，或者请求失败，MicType 会重试，需要时回退成整段上传，而不是打断你正在说的话。
- **只有一个验证动作。** 粘贴 Key 就会对服务商发一次真实请求做验证；验证不过的 Key 不会被存下来，状态行永远如实反映当下能不能用。

**阿拉伯语**可用：标准阿语（MSA）表现不错，其他方言不做承诺。阿语口述里夹的英文品牌 / 产品名可能被写成阿拉伯字母——把它们加进菜单栏 **「写作偏好…」** 里的专有词汇表即可解决。

## 长录音

单次录音最长 **10 分钟**，到点前会提前提醒。因为音频在你说话的同时就持续传给服务商，松手后几乎立刻拿到结果，不管说了多久——不存在一段单独的「长录音处理」。按 Esc 会立刻停止录音，但已经传出去的音频收不回来，所以拿到的就是截至那一刻已经识别出来的部分。

## AI：润色、指令与服务商

菜单栏 🎤 → 设置。整页就是：**服务商**（OpenAI 或阿里云）、**API Key**（粘贴当下就验证：正在验证… / 已连通 ✓ / 连不上 + 原因与下一步），阿里云再多一行可选的 **API Host**。下面一行状态文字写清此刻连的是谁、大约多少钱。没有别的要配了——模型、润色行为、联网搜索都是写死的选择，不是设置项：

- **每家一个模型，均衡偏快**：OpenAI 用 `gpt-5.6-luna`，阿里云用 `qwen3.8-flash`——润色和指令是每句话都要跑一次的东西，一个想好几秒才答的模型不如两秒内答的用着顺手。
- **联网搜索默认开着**（服务商支持的话），只在按住说指令时才可能用到（轻点听写的润色永远不联网）——OpenAI 每次约 $0.01，阿里云按它自己的价目计费。
- **OpenAI 一律走 Fast 档**——更低更稳的延迟，代价是约两倍的 token 单价，这句话只在 关于 → 隐私 里出现一次。

菜单栏（或设置页底部）的 **「写作偏好…」** 是你真正能管的那部分：

- **专有词汇表**：人名、品牌、术语的热词——OpenAI 的识别会用到它，两家的 AI 润色永远会用到它（阿里云那一档专名正是靠润色纠回来的）。
- **自定义规则**：一个自由文本框，写给 AI 的长期偏好（「署名用 Gen」「英文术语保留原文」），每次润色和每条语音指令都会带上它。

润色档位：仅识别（最快，不联网）或 AI 润色（自适应：短句轻清理，长段口述自动重构）——按每句话自动选择，不是你要手动挑的设置。

## 隐私

- **你说话的同时，音频就实时传给你选定的服务商。** 这一版没有本地识别——这是为了实时云端识别的速度与质量做出的有意取舍，直接写在这里，不是一个要你自己找的开关。
- 识别出的**文本**随后会发给同一家服务商做 AI 润色或执行语音指令。OpenAI 侧每次请求都带 `store: false`，你的文本不会被留在服务端 30 天。
- API Key 存放在 macOS 钥匙串，不落明文文件，导出设置时也从不包含。
- 听写历史只存在本机，随时可以关闭或清空。
- 联网搜索在支持的服务商上默认开着，由该服务商按次计费——单价就在设置里写着，而且只有按住说指令那条路才会联网。
- 费用由你直接结给服务商，按他们的标准价计：阿里云识别加润色大约 **$0.2/小时**，OpenAI 大约 **$1.1/小时**，都按你实际说话的时长算。MicType 不代理你的请求，也不加价。

## 从旧版本升级

如果你是从 4.x 版本升级过来的，MicType 首次启动会自动删掉旧的本机识别模型文件，并告诉你释放了多少空间。如果你之前用的是 DeepSeek 或本机模型，引导会带你走到「选你的 AI」那一屏，重新选 OpenAI 或阿里云——快捷键、词汇表、历史记录这些照旧不受影响。

## 常见问题

**按快捷键没反应？** 检查 系统设置 → 隐私与安全性 → 辅助功能。从源码自行编译（ad-hoc 签名）每次重装后通常需要删除旧授权条目再重新添加；官方公证版签名身份稳定，升级不需要这一步。

**识别专有名词不准？** 把常用人名、品牌、产品、术语写进菜单栏 「写作偏好…」→ 专有词汇表。OpenAI 的识别会用到它，AI 润色永远会用到它（阿里云的识别器不认热词，那一档靠润色这一步纠回来）。阿语口述里夹的英文品牌名同样靠它。

**润色失败，或者根本识别不出来？** 设置里 Key 旁边直接显示连接状态，能分清是 Key 无效、地区不支持、被限流还是余额不足。识别本身现在也跑在服务商那边，所以连不上时听写也一起不工作，把 Key 修好即可。

**文字没有输入到目标应用？** 处理期间切走窗口的话，MicType 会自动把目标应用拉回前台再粘贴；如果还是丢了，菜单栏 → 最近记录 里点一下即可复制找回。个别输入框（如密码框）禁止粘贴。

**编译时报 `Invalid manifest` / `PackageDescription` 链接错误？** Xcode 命令行工具可能损坏（多见于系统升级后），双击 `scripts/Fix Build Tools.command` 重装即可。

## 卸载

双击 `Uninstall MicType.command`。

## 技术栈

原生 Swift（菜单栏 App，SwiftUI 设置界面）· 实时云端识别（OpenAI `gpt-live-transcribe` / 阿里云百炼 `qwen3-asr-flash-realtime`，边说边传，阿里云接入地址自动探测）· OpenAI Responses 接口与阿里云 Chat Completions（润色与指令）· macOS 钥匙串 · 菜单栏即时切换的双语 L10n。

目录结构见上方英文版。

## 作者

作者：**Gen** — [genli-ai.github.io/portfolio](https://genli-ai.github.io/portfolio/) · [ligen.thu@gmail.com](mailto:ligen.thu@gmail.com)

## 致谢与许可

本项目从需求分析、架构设计、全部代码到调试排错，均通过 AI 协作完成。MIT License。
