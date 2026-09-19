# MicType 🎤 — Speak to Type. Hold to Command.

**Voice input for macOS that doubles as your AI entry point.** One key, two gestures: **tap** the hotkey and your speech becomes clean, punctuated text at the cursor — recognized 100% on-device. **Hold** the same key and your voice becomes an instruction to AI: rewrite the selection, draft a reply, compose an email, translate, ask anything — right where you're working, in any app.

> **⬇️ Just want to use the app? [Download it from Releases](https://github.com/genli-ai/MicType/releases/latest) — no Xcode, no build step.**
> The green "Code" button downloads the *source code*; building from source is for developers and requires full Xcode.

**中文说明在下方。**

## Two Gestures

**Tap Right Option (⌥) = dictation.**

```
Tap ⌥ → speak (a live grey draft shows what it hears) → tap ⌥ again
   ↓
Local Qwen3-ASR transcription (offline, MLX/Metal accelerated, audio never uploaded)
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

- **100% local speech recognition** — Qwen3-ASR on Apple Silicon (MLX/Metal): ~30 languages, 22 Chinese dialects, strong Chinese–English mixed dictation. Audio never leaves your Mac.
- **See what it hears** — a grey draft appears in the floating indicator while you are still talking. It never goes into your document: the inserted text is always the full re-recognition of the whole take.
- **Voice commands in any app** — the hold gesture works wherever your cursor is: chat, mail, docs, browser.
- **Adaptive AI polish, with a safety net** — short phrases get light cleanup; long rambling speech is restructured into ready-to-use text. If the polished version drifts from what you said (numbers, negations), MicType inserts the raw transcript and tells you — and for a minute afterwards the menu bar can swap a polished insertion back to the raw transcript.
- **Custom vocabulary as hotwords** — names, brands, and jargon are fed straight into the speech model and used by AI polish: the #1 lever for proper-noun accuracy. Add `wrong=right` (or `wrong1|wrong2=right`) for homophones that no model gets right.
- **Nothing lost, nothing stuck** — your clipboard (images, files, formatted text) is captured and restored around every insertion; a single recording is capped at five minutes and wraps up instead of being dropped; changing microphone mid-recording doesn't lose the take.
- **Searchable history** — the last 200 dictations stay on your Mac (⌘Y): search raw and polished text, re-insert an old result at the cursor, or send a mis-heard word to your vocabulary. Turn it off or clear it any time.
- **Your key, your mic** — eight hotkey choices including Fn / 🌐, plus microphone selection and a level test in Settings.
- **Bring your own model** — GPT or DeepSeek (both keys can be saved), any OpenAI-compatible endpoint. Keys live in the macOS Keychain. No key? MicType still works fully offline as a dictation tool.
- **Guided setup, one-click updates** — a first-run guide walks through permissions, the model download and a test dictation; Settings → About → Check for Updates verifies, installs and relaunches the new version. Export/import your settings to move them to another machine (API keys are never included).
- **Bilingual UI** — English / 中文, switch instantly in Settings.

## Quick Start (5 minutes)

Everything downloads from one page: **[Releases · latest](https://github.com/genli-ai/MicType/releases/latest)**

| | 🍎 macOS (Apple Silicon, macOS 15+) | 🪟 Windows (Win10 22H2+ / 11, x64 — beta) |
|---|---|---|
| **1. Download & run** | `MicType-{version}-arm64.zip` → unzip → drag `MicType.app` to Applications. If blocked: System Settings → Privacy & Security → **Open Anyway** | `MicType-{version}-win-x64.zip` → unzip → run `MicType.exe`. SmartScreen: **More info → Run anyway** |
| **2. One-time setup** | A first-run guide walks you through it: allow **Microphone**, enable **Accessibility** (System Settings → Privacy & Security), download the speech model (~860 MB), then try a dictation on the spot | Right-click the tray icon → Settings → download the speech model (~250 MB) |
| **3. Speak** | **Tap Right Option (⌥)** → talk → tap again. Text appears at your cursor | **Tap Right Ctrl** → talk → tap again. Text appears at your cursor |

Speech recognition runs 100% on your device — audio never leaves your machine. Optional: add a GPT/DeepSeek API key in Settings to unlock AI polish and **hold-to-command** (rewrite selection / draft replies / ask anything). Upgrades: Settings → About → **Check for Updates** — on macOS it verifies the new build, installs it in place and relaunches.

## Install

Requirements: **Apple Silicon + macOS 15+**. (Building from source additionally needs full Xcode — MLX compiles Metal shaders.)

**Prebuilt (recommended):** download `MicType-{version}-arm64.dmg` from [GitHub Releases](https://github.com/genli-ai/MicType/releases/latest), open it, and drag `MicType.app` to Applications. The DMG is **notarized by Apple — it opens with zero security warnings**. (A `.zip` is also attached — Developer ID signed but not notarized, so the first launch may need System Settings → Privacy & Security → **Open Anyway**.)

**From source, three steps:**

1. Double-click `scripts/Generate Qwen Tokenizer.command` once to generate tokenizer resources.
2. Double-click `Install MicType.command`. The first build takes 5–15 minutes and checks the Metal toolchain.
3. Open the app → Settings → Recognition → download the model (~860 MB).

## First Launch Permissions

| Permission | Why It Is Needed | How to Enable |
|------------|------------------|---------------|
| Microphone | Record your speech | Click Allow in the macOS prompt |
| Accessibility | Global hotkey, reading the selection, inserting text | System Settings → Privacy & Security → Accessibility → enable MicType |

If the hotkey still does not work after Accessibility appears enabled, remove MicType from the Accessibility list, add `/Applications/MicType.app` again, then quit and reopen MicType.

## AI Polish & Commands Setup

Menu bar 🎤 → Settings → **AI Polish** → pick a provider (GPT or DeepSeek) → paste your API key → Save Key → Test Connection.

Polish modes:

- **Transcribe only**: fully offline, fastest
- **AI polish (adaptive)**: light cleanup for short phrases; full restructuring for long spoken paragraphs

Voice commands use the same provider and key.

## Model Updates

Settings → Recognition → **Check Updates** compares the remote model repository against the version recorded when you downloaded. If a new version is found, click **Re-download / Update**.

Two kinds of vocabulary, not to confuse:

- **Custom vocabulary**: hotwords you enter in Settings — stored locally, effective on the next transcription.
- **Model tokenizer/vocab**: shipped with the Qwen model. If upstream updates it, run `scripts/Generate Qwen Tokenizer.command` again and reinstall.

## Privacy

- Audio and speech recognition are **100% local** and never uploaded.
- Only when AI polish or a voice command runs is the recognized **text** (never audio) sent to the API you configured.
- API keys are stored in the macOS Keychain, not in plain-text files.

## FAQ

**Hotkey does not respond?** Check System Settings → Privacy & Security → Accessibility. If you build from source (ad-hoc signing), macOS usually requires removing the old permission entry and adding the app again after each rebuild; official notarized releases keep a stable identity, so upgrades don't need this.

**Custom names or terms are wrong?** Add names, brands, products, and technical terms to Settings → Recognition → Custom Vocabulary. They are used both as Qwen hotwords and as hints for AI polish.

**Model download is slow?** MicType tries `hf-mirror.com` first and falls back to `huggingface.co`. Successfully downloaded files are kept, so retrying resumes by file.

**AI polish failed?** Use Settings → AI Polish → Test Connection to check your key, base URL, model name, and network. Local transcription still works; MicType falls back to the raw transcript on polish failure.

**Text was not inserted into the target app?** If you switch windows during processing, MicType tries to bring the original app back before pasting. If insertion still fails, click the latest item in Menu bar → Recent Transcripts to copy it. Some fields, such as password fields, block paste.

**Build fails with `Invalid manifest` or `PackageDescription` link errors?** Your Xcode command line tools may be broken, often after a system upgrade. Double-click `scripts/Fix Build Tools.command`.

## Uninstall

Double-click `Uninstall MicType.command`.

## Tech Stack

Native Swift menu bar app with SwiftUI settings · Qwen3-ASR via MLX (on-device) · OpenAI-compatible Chat Completions for polish & commands · macOS Keychain · bilingual in-line L10n.

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
│   ├── QwenModelDownloader.swift  # In-app model download and update check
│   ├── PolishService.swift        # Adaptive AI polish
│   ├── AgentService.swift         # LLM client + voice-command skills (intent-inferred selection commands / reply / free-form)
│   ├── SkillRouter.swift          # Explicit reply-trigger fast path
│   ├── SelectionReader.swift      # Read selected text via Accessibility (⌘C fallback)
│   ├── TextInserter.swift         # Clipboard + ⌘V insertion, full clipboard snapshot/restore
│   ├── Overlay.swift              # Floating indicator (live draft, elapsed time, cancel)
│   ├── HistoryStore.swift         # Last 200 transcripts, raw + polished, on disk
│   ├── HistoryWindow.swift        # History window: search, compare, re-insert, add to vocabulary
│   ├── OnboardingWindow.swift     # First-run guide (gestures, permissions, model, try it)
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

**Mac 语音输入法，也是你的 AI 入口。** 一个键，两种手势：**轻点**快捷键，说话变成干净、带标点的文字出现在光标处——识别 100% 在本机完成；**按住**同一个键，说出的话就是给 AI 的指令——改写选中文字、草拟回复、写邮件、翻译、随口提问，在任何应用里、就在你正在打字的地方。

> **⬇️ 只是想用？[去 Releases 下载现成的 App](https://github.com/genli-ai/MicType/releases/latest)——不需要 Xcode、不需要编译。**
> 绿色 "Code" 按钮下载的是*源代码*；从源码安装只面向开发者，需要完整 Xcode。

## 两种手势

**轻点 右 Option (⌥) = 听写**

```
按 右⌥ → 说话（悬浮窗里灰字实时草稿，让你看见它听到了什么）→ 再按 右⌥
   ↓
本地 Qwen3-ASR 识别（离线，MLX/Metal 加速，录音不上传）
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

- **识别 100% 本地**——Apple Silicon 上跑 Qwen3-ASR（MLX/Metal）：约 30 种语言 + 22 种中文方言，中英混说尤其强。录音永远不离开你的 Mac
- **看得见它听到了什么**——说话过程中悬浮窗就显示灰字草稿。草稿绝不进入你的文档：真正插入的永远是整段重新识别的结果
- **任何应用里都能下指令**——光标在哪，按住就在哪用：聊天、邮件、文档、浏览器
- **自适应 AI 润色，带安全网**——短句轻清理；长段混乱口述重构成可直接使用的成品文字。润色结果若与原话出入过大（数字、否定词被改动）会自动改输出识别原文并明说；插入后一分钟内还能在菜单栏一键「换回识别原文」
- **专有词汇表 = 热词**——人名、品牌、术语直接送入识别模型并参与润色纠错，是专有名词准确率的第一杠杆。完全同音的词可以写 `错写=正写`（一个正写挂多个错写：`错1|错2=正写`）
- **不丢东西、不卡死**——每次插入前后完整快照并还原剪贴板（图片、文件、富文本都不会被吃掉）；单次录音最长 5 分钟，到点自动收尾而不是丢弃；录音中途换麦克风也不丢这一段
- **可搜索的历史**——最近 200 条听写留在本机（⌘Y）：按识别原文和润色结果一起搜，重新插入到光标处，或把听错的词一键送进词汇表。随时可关、可清
- **热键和麦克风都由你定**——8 个可选热键（含 Fn / 🌐），设置里还能选麦克风并测试输入电平
- **模型自带**——GPT 或 DeepSeek（两个 Key 可同时保存），任何 OpenAI 兼容接口均可。Key 存 macOS 钥匙串。不填 Key 也完全可用：纯离线听写
- **有引导，升级一键完成**——首次启动的引导带你走完权限、模型下载和第一次试用；设置 → 关于 → 检查更新 会验签、就地安装并自动重启。设置可导出导入，换机不用重配（API Key 从不进文件）
- **中英双语界面**——设置里即时切换

## 快速上手（5 分钟）

所有下载都在一个页面：**[Releases · latest](https://github.com/genli-ai/MicType/releases/latest)**

| | 🍎 macOS（Apple Silicon，macOS 15+） | 🪟 Windows（Win10 22H2+/11，x64，公测） |
|---|---|---|
| **1. 下载运行** | `MicType-{版本}-arm64.zip` → 解压 → 把 `MicType.app` 拖进应用程序。被拦时：系统设置 → 隐私与安全性 → **「仍要打开」** | `MicType-{版本}-win-x64.zip` → 解压 → 运行 `MicType.exe`。SmartScreen 拦截点 **「更多信息 → 仍要运行」** |
| **2. 一次性设置** | 首次启动的引导会带着走完：允许**麦克风**、开启**辅助功能**（系统设置 → 隐私与安全性）、下载识别模型（约 860MB），然后就地试说一句 | 右键托盘图标 → 设置 → 下载识别模型（约 250MB） |
| **3. 开口说话** | **轻点右 Option（⌥）**→ 说话 → 再点一下，文字出现在光标处 | **轻点右 Ctrl** → 说话 → 再点一下，文字出现在光标处 |

语音识别 100% 本地运行，录音绝不上传。可选：在设置里配 GPT/DeepSeek 的 API Key，解锁 AI 润色和**按住说指令**（改写选中文字 / 代拟回复 / 随口提问）。升级：设置 → 关于 → **检查更新**——Mac 端会验签后就地安装并自动重启。

## 安装

要求：**Apple Silicon + macOS 15+**（从源码编译另需完整 Xcode——MLX 要编译 Metal 着色器）。

**预编译包（推荐）**：从 [GitHub Releases](https://github.com/genli-ai/MicType/releases/latest) 下载 `MicType-{版本}-arm64.dmg`，打开后把 `MicType.app` 拖进应用程序。DMG **已通过 Apple 公证，打开零拦截、零警告**。（同时附有 `.zip`：Developer ID 签名但未公证，首次打开可能需要到 系统设置 → 隐私与安全性 → **「仍要打开」**。）

**源码安装三步**：

1. 双击 `scripts/Generate Qwen Tokenizer.command`（一次性生成 tokenizer 资源）
2. 双击 `Install MicType.command`（首次编译 5-15 分钟，会自动检查 Metal 工具链）
3. 打开 App → 设置 → 识别 → 下载模型（约 860 MB，国内镜像加速）

## 首次启动授权

| 权限 | 用途 | 怎么开 |
|------|------|--------|
| 麦克风 | 录音 | 弹窗点「允许」 |
| 辅助功能 | 全局快捷键、读取选中文本、自动输入文字 | 系统设置 → 隐私与安全性 → 辅助功能 → 打开 MicType |

如果系统设置里显示已开启但快捷键仍失效：在辅助功能列表中删除 MicType，重新添加 `/Applications/MicType.app`，然后退出并重新打开 MicType。

## AI 润色与指令配置

菜单栏 🎤 → 设置 → **AI 润色** → 选服务商（GPT 或 DeepSeek）→ 粘贴 API Key →「保存 Key」→「测试连接」。

润色档位：

- **仅识别**：完全不联网，最快
- **AI 润色（自适应）**：短句轻清理；长段口述自动重构

语音指令与润色共用同一个服务商和 Key。

## 模型更新

设置 → 识别 → **检查更新** 会对比远端模型仓库与本地下载时记录的版本，发现新版本后点 **重新下载 / 更新**。

两类「词汇」要区分：

- **专有词汇表**：你在设置里填的热词，保存在本机，下次识别立即生效
- **模型 tokenizer/vocab**：Qwen 模型自带的分词词表，上游更新后需重新运行 `scripts/Generate Qwen Tokenizer.command` 并重新安装

## 隐私

- 录音和语音识别 **100% 在本机完成**，不上传
- 只有运行 AI 润色或语音指令时，识别出的**文本**（绝不是录音）才会发给你配置的 API
- API Key 存放在 macOS 钥匙串，不落明文文件

## 常见问题

**按快捷键没反应？** 检查 系统设置 → 隐私与安全性 → 辅助功能。从源码自行编译（ad-hoc 签名）每次重装后通常需要删除旧授权条目再重新添加；官方公证版签名身份稳定，升级不需要这一步。

**识别专有名词不准？** 把常用人名、品牌、产品、术语写进 设置 → 识别 → 专有词汇表。它同时参与 Qwen 热词提示和 AI 润色纠错。

**模型下载慢？** 默认先走 hf-mirror.com，失败后回退 huggingface.co；已下载成功的文件会保留，重试可按文件续传。

**润色失败？** 设置 → AI 润色 → 测试连接，检查 Key / Base URL / 模型名 / 网络。不影响本地识别，失败时自动输出识别原文。

**文字没有输入到目标应用？** 处理期间切走窗口的话，MicType 会自动把目标应用拉回前台再粘贴；如果还是丢了，菜单栏 → 最近记录 里点一下即可复制找回。个别输入框（如密码框）禁止粘贴。

**编译时报 `Invalid manifest` / `PackageDescription` 链接错误？** Xcode 命令行工具可能损坏（多见于系统升级后），双击 `scripts/Fix Build Tools.command` 重装即可。

## 卸载

双击 `Uninstall MicType.command`。

## 技术栈

原生 Swift（菜单栏 App，SwiftUI 设置界面）· Qwen3-ASR / MLX 本地推理 · OpenAI 兼容 Chat Completions（润色与指令）· macOS 钥匙串 · 行内双语 L10n。

目录结构见上方英文版。

## 作者

作者：**Gen** — [genli-ai.github.io/portfolio](https://genli-ai.github.io/portfolio/) · [ligen.thu@gmail.com](mailto:ligen.thu@gmail.com)

## 致谢与许可

本项目从需求分析、架构设计、全部代码到调试排错，均通过 AI 协作完成。MIT License。
