# MicType 🎤 — Speak to Type. Hold to Command.

**Voice input for macOS that doubles as your AI entry point.** One key, two gestures: **tap** the hotkey and your speech becomes clean, punctuated text at the cursor — recognized on your own Mac by default. **Hold** the same key and your voice becomes an instruction to AI: rewrite the selection, draft a reply, compose an email, translate, ask anything — right where you're working, in any app.

See a live draft while you are still speaking, dictate for up to ten minutes without losing a word, and set it up with one decision: local only, or local plus one AI provider.

> **⬇️ Just want to use the app? [Download it from Releases](https://github.com/genli-ai/MicType/releases/latest) — no Xcode, no build step.**
> The green "Code" button downloads the *source code*; building from source is for developers and requires full Xcode.

**中文说明在下方。**

## Two Gestures

**Tap Right Option (⌥) = dictation.**

```
Tap ⌥ → speak (a live grey draft shows what it hears) → tap ⌥ again
   ↓
Local Qwen3-ASR transcription (on-device by default — see Recognition engines)
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

Tap is always pure dictation (what you say is what gets typed), hold is always a command — that part is decided by gesture, never by guessing. Recording starts the moment you press the key, and Esc cancels at any point: while recording, and while MicType is transcribing, polishing or running a command.

## Why MicType

- **See what it hears, as you say it** — a grey draft appears in the floating indicator while you are still talking. It never goes into your document: the inserted text is always the finished transcription.
- **Local speech recognition by default** — Qwen3-ASR on Apple Silicon (MLX/Metal): ~30 languages, 22 Chinese dialects, strong Chinese–English mixed dictation, Arabic for Modern Standard Arabic. Your audio stays on your Mac unless you deliberately pick a cloud engine.
- **Cloud recognition when you want it** — on-device Qwen3-ASR by default, or one switch that sends recognition to Alibaba Cloud instead, labelled with what it costs and where your audio goes. The speech model itself updates in one click and cleans up after itself.
- **Never lose a word** — dictate for up to **ten minutes**: the take is transcribed in segments while you speak, and if anything fails — or you cancel — everything already transcribed is still delivered. Your clipboard (images, files, formatted text) is captured and restored around every insertion, and changing microphone mid-recording doesn't lose the take.
- **Cancel at any point** — Esc, the menu bar, or a click on the indicator stops recording, transcription, polish or a running command; nothing is inserted afterwards.
- **Voice commands in any app** — the hold gesture works wherever your cursor is: chat, mail, docs, browser.
- **Adaptive AI polish, with a safety net** — short phrases get light cleanup; long rambling speech is restructured into ready-to-use text. If the polished version drifts from what you said (numbers, negations), MicType inserts the raw transcript and tells you — and for a minute afterwards the menu bar can swap a polished insertion back to the raw transcript.
- **Custom vocabulary as hotwords** — names, brands, and jargon are fed straight into the speech model and used by AI polish: the #1 lever for proper-noun accuracy. Add `wrong=right` (or `wrong1|wrong2=right`) for homophones that no model gets right.
- **Searchable history** — the last 200 dictations stay on your Mac (⌘Y): search raw and polished text, re-insert an old result at the cursor, or send a mis-heard word to your vocabulary. Turn it off or clear it any time.
- **Your key, your mic** — three hotkey choices (Right Option, Right Command, Right Control), named in full wherever MicType asks you to press one, plus microphone selection and a level test.
- **Setup is one decision** — *Local only* or *Local + AI*. With AI: one provider (OpenAI · DeepSeek · Alibaba Cloud), one key, one Model dropdown. Paste the key and it is verified on the spot; keys live in the macOS Keychain. Other OpenAI-compatible endpoints and local models (Ollama / LM Studio) are under Advanced. No key? MicType still works fully offline as a dictation tool.
- **Guided setup, one-click updates** — a four-screen first-run guide: welcome, permissions (the speech model downloads in the background while you grant them), how you'll use it, and a dictation you try on the spot; Settings → About → Check for Updates verifies, installs and relaunches the new version. Export/import your settings to move them to another machine (API keys are never included).
- **Bilingual UI** — English / 中文, switch instantly in Settings.

## Quick Start (5 minutes)

Everything downloads from one page: **[Releases · latest](https://github.com/genli-ai/MicType/releases/latest)**

| | 🍎 macOS (Apple Silicon, macOS 15+) | 🪟 Windows (Win10 22H2+ / 11, x64 — beta) |
|---|---|---|
| **1. Download & run** | `MicType-{version}-arm64.zip` → unzip → drag `MicType.app` to Applications. If blocked: System Settings → Privacy & Security → **Open Anyway** | `MicType-{version}-win-x64.zip` → unzip → run `MicType.exe`. SmartScreen: **More info → Run anyway** |
| **2. One-time setup** | A four-screen first-run guide does all of it: allow **Microphone** (with a live level meter) and enable **Accessibility** (System Settings → Privacy & Security) while the speech model downloads in the background, choose *Local only* or *Local + AI* (paste a key, it is verified there and then), and try a dictation on the spot. You can skip the AI decision in one click: dictation is complete without it | Right-click the tray icon → Settings → download the speech model (~250 MB) |
| **3. Speak** | **Tap Right Option (⌥)** → talk → tap again. Text appears at your cursor | **Tap Right Ctrl** → talk → tap again. Text appears at your cursor |

Speech recognition runs on your device by default — audio leaves your Mac only if you deliberately choose a cloud engine. Optional: add an API key in Settings to unlock AI polish and **hold-to-command** (rewrite selection / draft replies / ask anything). Upgrades: Settings → About → **Check for Updates** — on macOS it verifies the new build, installs it in place and relaunches.

## Install

Requirements: **Apple Silicon + macOS 15+**. (Building from source additionally needs full Xcode — MLX compiles Metal shaders.)

**Prebuilt (recommended):** download `MicType-{version}-arm64.dmg` from [GitHub Releases](https://github.com/genli-ai/MicType/releases/latest), open it, and drag `MicType.app` to Applications. The DMG is **notarized by Apple — it opens with zero security warnings**. (A `.zip` is also attached — Developer ID signed but not notarized, so the first launch may need System Settings → Privacy & Security → **Open Anyway**.)

**From source, three steps:**

1. Double-click `scripts/Generate Qwen Tokenizer.command` once to generate tokenizer resources.
2. Double-click `Install MicType.command`. The first build takes 5–15 minutes and checks the Metal toolchain.
3. Open the app → Settings → Dictation → download the model (~860 MB).

## First Launch Permissions

| Permission | Why It Is Needed | How to Enable |
|------------|------------------|---------------|
| Microphone | Record your speech | Click Allow in the macOS prompt |
| Accessibility | Global hotkey, reading the selection, inserting text | System Settings → Privacy & Security → Accessibility → enable MicType |

If the hotkey still does not work after Accessibility appears enabled, remove MicType from the Accessibility list, add `/Applications/MicType.app` again, then quit and reopen MicType.

## Recognition Engines

**On-device Qwen3-ASR is the default**, and it is the whole of Settings → **Dictation**: microphone, language, vocabulary, filler words, the speech model and performance. Recognition runs on your Mac through MLX/Metal and your audio never leaves the machine. The model updates itself: when a better or newer one is published you get a single non-modal hint, one click downloads and verifies it, and the old weights are removed only after the new model has actually worked and you have restarted once.

**Cloud recognition is one switch**, and it lives with the rest of your AI setup: Settings → **AI** → pick **Alibaba Cloud** → *Also recognize speech in the cloud*. It is off by default. Useful when this Mac is slow, the takes are long, or you need a language the local model handles poorly. Two things are true and stated on the same screen: **your audio is uploaded to that provider**, and **that provider bills you by the second of audio** — their retention policy is quoted there too.

- **One key, one host, no region choice.** Cloud recognition uses the same Model Studio key as polish and commands, and the same endpoint. MicType finds that endpoint itself: when you paste the key it tries candidate hosts with a free model-list request, stops at the first that accepts the key, and remembers it — so there is no International/China picker to get wrong. An optional **API host** field takes the console's `apiHost` (or a full URL) if you would rather name it yourself; paste one and MicType uses only that host.
- **The model is `qwen3-asr-flash`** — the one model the synchronous endpoint serves. A setting left over from 4.0.0 naming `qwen-audio-3.0-asr-flash` falls back to it automatically and is remembered.
- **Verified before you rely on it.** Pasting the key sends one second of synthetic tone to the recognition endpoint, which also proves you have enabled the model once in Model Studio's Model Gallery. A **Test recognition** button repeats that round trip any time and reports the round-trip time.
- Your custom vocabulary is sent along as hotwords, and the recognition-language setting becomes the language hint. If a cloud request fails and the local model is installed, MicType re-runs the recording locally and says so — rather than losing it. The live grey draft always comes from the local model, and a cloud take is uploaded only after you release the key. Switch to a different AI provider and recognition returns to on-device.

**Recognition language** is set under Settings → Dictation. Leave it on Auto, or pick a language — with a language chosen, every segment of a long dictation is locked to it, which prevents the model from drifting to another language mid-recording.

**Arabic** is supported: Modern Standard Arabic works well. Gulf, Egyptian and other dialects are *not* promised — the setting says so rather than pretending. One tip that measurably matters: English brand and product names spoken inside Arabic come back written in Arabic letters, so **add them to your custom vocabulary** (`Microsoft Excel`, `Power BI`) — vocabulary entries go to the model as hotwords and fix exactly this. Arabic punctuation is mostly supplied by AI polish.

## Long Dictation

A single take can run up to **ten minutes**. Anything under 90 seconds is transcribed in one pass, exactly as before; past that it is transcribed in 45-second segments *while you are still speaking*, each cut at a natural pause, so releasing the key finishes almost immediately however long you talked, and memory stays flat. If a segment fails, or you press Esc halfway, everything already transcribed is still inserted and written to history. When you reach the limit MicType wraps the take up and inserts **everything** you said — nothing is discarded at the limit.

## AI: Polish, Commands, and Your Provider

Menu bar 🎤 → Settings → **AI**. The page is one decision: **Local only** or **Local + AI**. Local only means polish off and recognition on-device — and nothing else is shown, because there is nothing else to decide.

With AI, three controls and no more:

- **One provider**: OpenAI, DeepSeek or Alibaba Cloud (Model Studio). Other OpenAI-compatible endpoints and a **local model** on your own machine (Ollama / LM Studio — no key needed, nothing leaves your computer) are under *Advanced*; whichever one you are actually using always stays visible in the picker.
- **One key**, verified as you paste it (Checking… / Connected ✓ / Failed, with the reason and what to do). A key that does not verify is never written to the Keychain. There is no second key field anywhere in the app.
- **One Model dropdown**, which sets the polish model and the command model together. Defaults: `gpt-5.6-sol`, `deepseek-v4-pro`, `qwen3.8-max` — each provider's strongest mainstream tier, with cheaper tiers one click away in the same list. Pick *Custom…* to type any model name.

*Advanced* (collapsed) holds About me and custom polish rules, split polish/command models, temperatures, **web search** (off by default and billed per search by your provider, stated next to the switch), the low-latency priority tier, the Base URL, a **Refresh model list** button that asks your provider what it actually serves, and the other endpoints above.

Polish modes:

- **Transcribe only**: fully offline, fastest
- **AI polish (adaptive)**: light cleanup for short phrases; full restructuring for long spoken paragraphs

Voice commands use the same provider and key.

Two kinds of vocabulary, not to confuse:

- **Custom vocabulary**: hotwords you enter in Settings — stored locally, effective on the next transcription (and sent as hotwords to a cloud engine, if you picked one).
- **Model tokenizer/vocab**: shipped with the Qwen model. If upstream updates it, run `scripts/Generate Qwen Tokenizer.command` again and reinstall.

## Privacy

- **Local by default.** Speech recognition runs on your Mac, and your audio leaves it **only if you turn on cloud recognition** in Settings → AI — one switch, off by default, labelled with its cost and where the audio goes.
- Only when AI polish or a voice command runs is the recognized **text** (never audio) sent to the provider you configured. On OpenAI, MicType sends `store: false` on every request, so your text is not retained for the 30 days the API otherwise keeps it. Pick the local-model provider and even the text stays on your machine.
- API keys are stored in the macOS Keychain, not in plain-text files, and are never included in a settings export.
- Transcript history is kept on your Mac only; you can switch it off or clear it at any time.
- Web search is off by default and billed per search (roughly a cent) by your provider — stated next to the switch that turns it on.
- You pay your provider directly at their rates. MicType never proxies your requests and never adds a fee.

## FAQ

**Hotkey does not respond?** Check System Settings → Privacy & Security → Accessibility. If you build from source (ad-hoc signing), macOS usually requires removing the old permission entry and adding the app again after each rebuild; official notarized releases keep a stable identity, so upgrades don't need this.

**Custom names or terms are wrong?** Add names, brands, products, and technical terms to Settings → Dictation → Custom Vocabulary. They are used as hotwords by the speech engine (local or cloud) and as hints for AI polish. This is also the fix for English brand names spoken inside Arabic.

**Model download is slow?** MicType tries `hf-mirror.com` first and falls back to `huggingface.co`. Successfully downloaded files are kept, so retrying resumes by file.

**AI polish failed?** Settings → AI shows the connection state next to your key, and Advanced has a per-model Test button — between them you can tell a bad key from a wrong model name, an unsupported region, rate limiting or exhausted credit. Local transcription still works; MicType falls back to the raw transcript on polish failure.

**Text was not inserted into the target app?** If you switch windows during processing, MicType tries to bring the original app back before pasting. If insertion still fails, click the latest item in Menu bar → Recent Transcripts to copy it. Some fields, such as password fields, block paste.

**Build fails with `Invalid manifest` or `PackageDescription` link errors?** Your Xcode command line tools may be broken, often after a system upgrade. Double-click `scripts/Fix Build Tools.command`.

## Uninstall

Double-click `Uninstall MicType.command`.

## Tech Stack

Native Swift menu bar app with SwiftUI settings · Qwen3-ASR via MLX (on-device, segmented for long takes) · optional cloud recognition (Alibaba Cloud Model Studio, endpoint auto-detected) · OpenAI Responses API and OpenAI-compatible Chat Completions for polish & commands · macOS Keychain · bilingual in-line L10n.

```
MicType/
├── Package.swift                  # Swift Package definition (MLXASR)
├── Sources/MicType/
│   ├── main.swift                 # Entry point
│   ├── AppDelegate.swift          # Menu bar app wiring
│   ├── DictationController.swift  # Recording → transcription → polish/skills → insertion
│   ├── HotkeyManager.swift        # Global hotkey: tap = dictate, hold = command, Esc cancel
│   ├── AudioRecorder.swift        # 16 kHz recording and level monitoring
│   ├── QwenEngine.swift           # Local Qwen3-ASR inference (MLX)
│   ├── QwenModelDownloader.swift  # In-app model download, catalog-driven upgrade and cleanup
│   ├── CloudASR/                  # Optional cloud recognition (endpoint detection, segmenting, WAV encoding)
│   ├── LLMCatalog.swift           # Model ids, presets and per-model capabilities in one place
│   ├── PolishService.swift        # Adaptive AI polish
│   ├── AgentService.swift         # LLM client + voice-command skills (intent-inferred selection commands / reply / free-form)
│   ├── SkillRouter.swift          # Explicit reply-trigger fast path
│   ├── SelectionReader.swift      # Read selected text via Accessibility (⌘C fallback)
│   ├── TextInserter.swift         # Clipboard + ⌘V insertion, full clipboard snapshot/restore
│   ├── Overlay.swift              # Floating indicator (live draft, elapsed time, cancel)
│   ├── HistoryStore.swift         # Last 200 transcripts, raw + polished, on disk
│   ├── HistoryWindow.swift        # History window: search, compare, re-insert, add to vocabulary
│   ├── OnboardingWindow.swift     # First-run guide (four screens: welcome, permissions, how you'll use it, try it)
│   ├── MicCheck.swift             # Microphone picker and level meter (Settings + onboarding)
│   ├── UpdateChecker.swift        # Update check + verify, install and relaunch
│   ├── SettingsBackup.swift       # Settings export / import (shared JSON with Windows)
│   ├── Localization.swift         # In-line bilingual L10n (instant switch)
│   └── SettingsView.swift         # Settings window
├── Resources/                     # Info.plist, icon, QwenTokenizer
└── Package.resolved               # Locked dependency versions

scripts/                       # Repair tools and tokenizer generator
MicTypeWindows/                # Windows port (C# / .NET, public beta)
Install MicType.command       # One-click installer (build from source)
Uninstall MicType.command     # Uninstaller
```

> 🪟 **Windows (public beta):** download `MicType-{version}-win-x64.zip` from [Releases](https://github.com/genli-ai/MicType/releases/latest) — local SenseVoice recognition, tap Right Ctrl to dictate. Windows 10 22H2+ / 11 x64; first run downloads a ~250 MB speech model in Settings; SmartScreen will warn (unsigned beta) — More info → Run anyway. Upgrades are one click via Settings → About → Check for Updates. Details: [MicTypeWindows/](MicTypeWindows/)
> **Windows 版（公开测试）**：从 [Releases](https://github.com/genli-ai/MicType/releases/latest) 下载 `MicType-{版本}-win-x64.zip`——本地 SenseVoice 识别，轻点右 Ctrl 听写。Win10 22H2+/11 x64；首次在设置里下载约 250MB 识别模型；SmartScreen 拦截时点「更多信息 → 仍要运行」。之后升级在 设置 → 关于 → 检查更新 一键完成。

## Author

Built by **Gen** — [genli-ai.github.io/portfolio](https://genli-ai.github.io/portfolio/) · [ligen.thu@gmail.com](mailto:ligen.thu@gmail.com)

## Credits and License

This project was designed, implemented, debugged, and refined with AI collaboration. MIT License.

---

# MicType 🎤 — 轻点听写，按住说指令

**Mac 语音输入法，也是你的 AI 入口。** 一个键，两种手势：**轻点**快捷键，说话变成干净、带标点的文字出现在光标处——默认在你自己的 Mac 上识别；**按住**同一个键，说出的话就是给 AI 的指令——改写选中文字、草拟回复、写邮件、翻译、随口提问，在任何应用里、就在你正在打字的地方。

说话过程中就看得见草稿，一口气说十分钟也不丢字，配置只有一个决定：只用本地，还是本地 + 一家 AI 服务商。

> **⬇️ 只是想用？[去 Releases 下载现成的 App](https://github.com/genli-ai/MicType/releases/latest)——不需要 Xcode、不需要编译。**
> 绿色 "Code" 按钮下载的是*源代码*；从源码安装只面向开发者，需要完整 Xcode。

## 两种手势

**轻点 右 Option (⌥) = 听写**

```
按 右⌥ → 说话（悬浮窗里灰字实时草稿，让你看见它听到了什么）→ 再按 右⌥
   ↓
本地 Qwen3-ASR 识别（默认在本机完成，MLX/Metal 加速——见「识别引擎」）
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

轻点永远是纯听写（说什么打什么），按住永远是指令——这一层靠手势区分，永不猜测。按下那一刻就开始录音；Esc 随时取消——录音中可以，识别中 / 润色中 / 执行指令中同样可以。

## 为什么选 MicType

- **边说边看**——说话过程中悬浮窗就显示灰字草稿。草稿绝不进入你的文档：真正插入的永远是完整识别的结果
- **默认在本机识别**——Apple Silicon 上跑 Qwen3-ASR（MLX/Metal）：约 30 种语言 + 22 种中文方言，中英混说尤其强，阿拉伯语支持标准阿语（MSA）。除非你主动选了云端引擎，录音不会离开这台 Mac
- **要云端识别时才用云端**——默认在本机识别；想上云只有一个开关（交给阿里云），旁边写清费用和音频去向。识别模型本身也能一键升级，升完自动清理旧文件
- **一个字都不丢**——单次可以说到**十分钟**：录音期间就在分段识别，中途出错或你按了取消，已经识别出来的部分照样交付。每次插入前后完整快照并还原剪贴板（图片、文件、富文本都不会被吃掉）；录音中途换麦克风也不丢这一段
- **任何阶段都能取消**——Esc、菜单栏、或者直接点悬浮窗：录音中、识别中、润色中、执行指令中都能停，停了之后一个字也不会插进来
- **任何应用里都能下指令**——光标在哪，按住就在哪用：聊天、邮件、文档、浏览器
- **自适应 AI 润色，带安全网**——短句轻清理；长段混乱口述重构成可直接使用的成品文字。润色结果若与原话出入过大（数字、否定词被改动）会自动改输出识别原文并明说；插入后一分钟内还能在菜单栏一键「换回识别原文」
- **专有词汇表 = 热词**——人名、品牌、术语直接送入识别模型并参与润色纠错，是专有名词准确率的第一杠杆。完全同音的词可以写 `错写=正写`（一个正写挂多个错写：`错1|错2=正写`）
- **可搜索的历史**——最近 200 条听写留在本机（⌘Y）：按识别原文和润色结果一起搜，重新插入到光标处，或把听错的词一键送进词汇表。随时可关、可清
- **热键和麦克风都由你定**——三个可选热键（右 Option / 右 Command / 右 Control），凡是让你按键的地方都写全名，还能选麦克风并测试输入电平
- **配置只有一个决定**——「只用本地」或「本地 + AI」。选了 AI：一家服务商（OpenAI · DeepSeek · 阿里云百炼）、一把 Key、一个「模型」下拉。粘贴 Key 就地验证，Key 存 macOS 钥匙串。其他 OpenAI 兼容接口与本机模型（Ollama / LM Studio）在「高级」里。不填 Key 也完全可用：纯离线听写
- **有引导，升级一键完成**——首次启动的四屏引导：欢迎 → 权限（授权的同时识别模型已在后台下载）→ 怎么用 → 就地试一句；设置 → 关于 → 检查更新 会验签、就地安装并自动重启。设置可导出导入，换机不用重配（API Key 从不进文件）
- **中英双语界面**——设置里即时切换

## 快速上手（5 分钟）

所有下载都在一个页面：**[Releases · latest](https://github.com/genli-ai/MicType/releases/latest)**

| | 🍎 macOS（Apple Silicon，macOS 15+） | 🪟 Windows（Win10 22H2+/11，x64，公测） |
|---|---|---|
| **1. 下载运行** | `MicType-{版本}-arm64.zip` → 解压 → 把 `MicType.app` 拖进应用程序。被拦时：系统设置 → 隐私与安全性 → **「仍要打开」** | `MicType-{版本}-win-x64.zip` → 解压 → 运行 `MicType.exe`。SmartScreen 拦截点 **「更多信息 → 仍要运行」** |
| **2. 一次性设置** | 首次启动的四屏引导会带着走完：允许**麦克风**（当场看电平条）、开启**辅助功能**（系统设置 → 隐私与安全性）——识别模型在这期间后台下载——然后选「只用本地」还是「本地 + AI」（粘贴 Key 当场验证），最后就地试说一句。AI 那个决定一键就能跳过，不影响听写 | 右键托盘图标 → 设置 → 下载识别模型（约 250MB） |
| **3. 开口说话** | **轻点右 Option（⌥）**→ 说话 → 再点一下，文字出现在光标处 | **轻点右 Ctrl** → 说话 → 再点一下，文字出现在光标处 |

语音识别默认在本机运行，只有你主动选择云端引擎时录音才会离开这台 Mac。可选：在设置里配 API Key，解锁 AI 润色和**按住说指令**（改写选中文字 / 代拟回复 / 随口提问）。升级：设置 → 关于 → **检查更新**——Mac 端会验签后就地安装并自动重启。

## 安装

要求：**Apple Silicon + macOS 15+**（从源码编译另需完整 Xcode——MLX 要编译 Metal 着色器）。

**预编译包（推荐）**：从 [GitHub Releases](https://github.com/genli-ai/MicType/releases/latest) 下载 `MicType-{版本}-arm64.dmg`，打开后把 `MicType.app` 拖进应用程序。DMG **已通过 Apple 公证，打开零拦截、零警告**。（同时附有 `.zip`：Developer ID 签名但未公证，首次打开可能需要到 系统设置 → 隐私与安全性 → **「仍要打开」**。）

**源码安装三步**：

1. 双击 `scripts/Generate Qwen Tokenizer.command`（一次性生成 tokenizer 资源）
2. 双击 `Install MicType.command`（首次编译 5-15 分钟，会自动检查 Metal 工具链）
3. 打开 App → 设置 → 听写 → 下载模型（约 860 MB，国内镜像加速）

## 首次启动授权

| 权限 | 用途 | 怎么开 |
|------|------|--------|
| 麦克风 | 录音 | 弹窗点「允许」 |
| 辅助功能 | 全局快捷键、读取选中文本、自动输入文字 | 系统设置 → 隐私与安全性 → 辅助功能 → 打开 MicType |

如果系统设置里显示已开启但快捷键仍失效：在辅助功能列表中删除 MicType，重新添加 `/Applications/MicType.app`，然后退出并重新打开 MicType。

## 识别引擎

**本地 Qwen3-ASR 是默认**，也是 设置 → **听写** 这一页的全部内容：麦克风、识别语言、专有词汇表、口水词、本机模型与性能。识别通过 MLX/Metal 跑在你的 Mac 上，录音不出机。模型自己会升级：出现更好或更新的模型时只给**一条**非模态提示，点一下完成下载与校验；旧模型要等新模型真正成功识别过一次、并且你重启过一次之后才会被删掉。

**云端识别是一个开关**，而且和你的 AI 配置放在一起：设置 → **AI** → 选「阿里云百炼」→「识别也用云端」。默认关着。这台 Mac 慢、录音长、或者要识别本地模型不擅长的语言时才值得开。有两件事写在同一屏上：**你的音频会上传到该服务商**，**该服务商按音频秒数向你计费**——留存口径也写在旁边。

- **一把 Key、一台主机，没有区域选择题。** 云端识别用的就是润色与指令那把百炼 Key、那一台接入地址。地址由 MicType 自己试出来：粘 Key 的时候拿免费的型号清单请求逐台试候选主机，第一台认这把 Key 的就是答案并记住——不再有「国际站 / 中国站」可以选错。另有**可选**的「接入地址」框，给想自己指定的人：把控制台的 `apiHost`（或整条 URL）粘进去，MicType 就只用这一台。
- **识别模型是 `qwen3-asr-flash`**——同步端点上唯一提供的那个。设置里还留着 4.0.0 的 `qwen-audio-3.0-asr-flash` 时会自动回落到它并记住。
- **先验过再用**：粘贴 Key 会立刻发 1 秒合成音到识别端点，连「模型有没有在百炼『模型广场』开通过」一起验到；旁边的**「测试识别」**按钮随时可以再跑一遍并报出往返毫秒数。
- 专有词汇表会作为热词一起发过去，识别语言设置会变成语言提示。云端请求失败时，**本地模型在就整段改用本地再识别一遍**并明说，而不是丢掉你的录音。实时灰字草稿永远来自本地模型；云端档是松手之后才上传。换成别家 AI 服务商时，识别自动回到本机。

**识别语言**在 设置 → 听写 里设置。保持「自动」即可；一旦指定语言，长录音的每一段都会锁住这个语言，杜绝录到一半漂到别的语言。

**阿拉伯语**可用：标准阿语（MSA）表现不错；海湾、埃及等**方言不做承诺**——界面上就这么写，不粉饰。有一条实测有效的用法：阿语口述里夹的英文品牌 / 产品名会被写成阿拉伯字母，**请把它们加进专有词汇表**（如 `Microsoft Excel`、`Power BI`）——词汇表会作为热词直接送进模型，正好治这个。阿语的标点主要由 AI 润色补齐。

## 长录音

单次录音最长 **10 分钟**。90 秒以内的录音一次过，和以前完全一样；超过之后，它是在你**还在说的时候**按 45 秒一段、在自然停顿处切开逐段识别的——所以不管说了多久，松手后几乎立刻出结果，内存也是平的。某一段失败、或者你说到一半按了 Esc，**已经识别出来的内容照样插入并写进历史**。到达上限时 MicType 会收尾并把你说的**全部**插入，不是丢弃。

## AI：润色、指令与服务商

菜单栏 🎤 → 设置 → **AI**。这一页只有一个决定：**只用本地** 还是 **本地 + AI**。「只用本地」= 润色关掉、识别在本机——然后下面一个控件都不摆，因为确实没有别的要决定了。

选了 AI，也只有三个控件：

- **一家服务商**：OpenAI、DeepSeek 或阿里云百炼。其他 OpenAI 兼容接口、以及跑在你自己机器上的**本机模型**（Ollama / LM Studio——不用 Key，什么都不出本机）在「高级」里；不过**你正在用的那一档永远摆在选择器上**。
- **一把 Key**，在粘贴的当下就会被验证（正在验证… / 已连通 ✓ / 连不上 + 原因与下一步）；验证不过的 Key 不会被写进钥匙串。全 App 没有第二个 Key 输入框。
- **一个「模型」下拉**，选一下把润色和指令两个型号一起改掉。默认分别是 `gpt-5.6-sol`、`deepseek-v4-pro`、`qwen3.8-max`——每家最主流的那个好模型；想省钱的档就在同一个下拉里。选「自定义…」可以手填任意型号名。

**「高级」**（默认折叠）里是：关于我与自定义润色规则、分开设润色/指令型号、温度、**联网搜索**（默认关、由服务商按次计费，这句话就写在开关旁边）、低延迟优先档、Base URL、**刷新模型列表**（直接问服务商现在提供哪些模型），以及上面提到的其他端点。

润色档位：

- **仅识别**：完全不联网，最快
- **AI 润色（自适应）**：短句轻清理；长段口述自动重构

语音指令与润色共用同一个服务商和 Key。

两类「词汇」要区分：

- **专有词汇表**：你在设置里填的热词，保存在本机，下次识别立即生效（选了云端引擎时也会作为热词发过去）
- **模型 tokenizer/vocab**：Qwen 模型自带的分词词表，上游更新后需重新运行 `scripts/Generate Qwen Tokenizer.command` 并重新安装

## 隐私

- **本地是默认。** 语音识别在你的 Mac 上完成，录音**只有在你自己到 设置 → AI 里打开「识别也用云端」时**才会离开这台机器——一个默认关着的开关，旁边写明了费用和音频去向。
- 只有运行 AI 润色或语音指令时，识别出的**文本**（绝不是录音）才会发给你配置的服务商。OpenAI 侧每次请求都带 `store: false`，你的文本不会被留在服务端 30 天。选「本机模型」的话，连文本也不出这台机器。
- API Key 存放在 macOS 钥匙串，不落明文文件，导出设置时也从不包含。
- 听写历史只存在本机，随时可以关闭或清空。
- 联网搜索默认关闭，开了之后由服务商**按次计费**（一次大约一美分）——这句话就写在开关旁边。
- 费用由你直接结给服务商，按他们的标准价计。MicType 不代理你的请求，也不加价。

## 常见问题

**按快捷键没反应？** 检查 系统设置 → 隐私与安全性 → 辅助功能。从源码自行编译（ad-hoc 签名）每次重装后通常需要删除旧授权条目再重新添加；官方公证版签名身份稳定，升级不需要这一步。

**识别专有名词不准？** 把常用人名、品牌、产品、术语写进 设置 → 听写 → 专有词汇表。它会作为识别引擎（本地或云端）的热词，也参与 AI 润色纠错。阿语口述里夹的英文品牌名同样靠它。

**模型下载慢？** 默认先走 hf-mirror.com，失败后回退 huggingface.co；已下载成功的文件会保留，重试可按文件续传。

**润色失败？** 设置 → AI 里 Key 旁边直接显示连接状态，「高级」里每个型号另有「测试」按钮——两者结合能分清是 Key 无效、模型名写错、所在地区不支持、被限流还是余额不足。不影响本地识别，失败时自动输出识别原文。

**文字没有输入到目标应用？** 处理期间切走窗口的话，MicType 会自动把目标应用拉回前台再粘贴；如果还是丢了，菜单栏 → 最近记录 里点一下即可复制找回。个别输入框（如密码框）禁止粘贴。

**编译时报 `Invalid manifest` / `PackageDescription` 链接错误？** Xcode 命令行工具可能损坏（多见于系统升级后），双击 `scripts/Fix Build Tools.command` 重装即可。

## 卸载

双击 `Uninstall MicType.command`。

## 技术栈

原生 Swift（菜单栏 App，SwiftUI 设置界面）· Qwen3-ASR / MLX 本地推理（长录音分段）· 可选云端识别（阿里云百炼，接入地址自动探测）· OpenAI Responses 接口与 OpenAI 兼容 Chat Completions（润色与指令）· macOS 钥匙串 · 行内双语 L10n。

目录结构见上方英文版。

## 作者

作者：**Gen** — [genli-ai.github.io/portfolio](https://genli-ai.github.io/portfolio/) · [ligen.thu@gmail.com](mailto:ligen.thu@gmail.com)

## 致谢与许可

本项目从需求分析、架构设计、全部代码到调试排错，均通过 AI 协作完成。MIT License。
