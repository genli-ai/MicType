using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using MicType.Win.Core;
using MicType.Win.Views;

namespace MicType.Win.Services;

public sealed class DictationController
{
    private readonly AudioRecorder _recorder = new();
    private readonly ISpeechEngine _speechEngine;
    private readonly OverlayWindow _overlay;
    private readonly ProcessingWatchdog _processingWatchdog;
    private IntPtr _targetWindow;
    private string? _targetProcessName;
    private string? _targetSelection;
    private string? _pendingDeliverText;
    private bool _skillSession;

    public DictationController(ISpeechEngine speechEngine, OverlayWindow overlay)
    {
        _speechEngine = speechEngine;
        _overlay = overlay;
        _processingWatchdog = new ProcessingWatchdog(TimeSpan.FromSeconds(30), () => Phase, OnProcessingTimeoutAsync);
    }

    public event Action<Phase>? PhaseChanged;
    public event Action? NeedSettings;

    public Phase Phase { get; private set; } = Phase.Idle;
    public bool IsRecording => Phase == Phase.Recording;

    public void Toggle()
    {
        switch (Phase)
        {
            case Phase.Idle:
                _ = StartRecordingAsync();
                break;
            case Phase.Recording:
                _ = FinishRecordingAsync();
                break;
        }
    }

    public void SkillHoldStart()
    {
        if (Phase == Phase.Idle)
        {
            _ = StartRecordingAsync(skill: true);
        }
    }

    public void SkillHoldEnd()
    {
        if (Phase == Phase.Recording)
        {
            _ = FinishRecordingAsync();
        }
    }

    public void Cancel()
    {
        if (Phase != Phase.Recording) return;
        _recorder.Stop();
        _skillSession = false;
        Log.Info("Recording cancelled by user");
        SetPhase(Phase.Idle);
        _overlay.Hide();
        Sounds.PlayCancel();
    }

    private async Task StartRecordingAsync(bool skill = false)
    {
        if (!_speechEngine.IsModelAvailable)
        {
            Log.Warn("Start recording blocked because speech model is not available");
            _overlay.FlashError(L10n.Tr(
                "识别模型未下载，请在设置中下载",
                "Speech model not downloaded — see Settings"));
            Sounds.PlayError();
            NeedSettings?.Invoke();
            return;
        }

        if (Phase != Phase.Idle) return;
        _targetWindow = TextInserter.CaptureForegroundWindow();
        _targetProcessName = GetProcessNameForWindow(_targetWindow);
        if (_targetProcessName is "explorer" or "MicType")
        {
            // 从托盘菜单启动时前台是任务栏/自己——别把它当投递目标，粘贴时跟随当时的前台窗口
            Log.Info($"Captured foreground is {_targetProcessName} (tray launch?) — paste will follow the foreground at delivery time");
            _targetWindow = IntPtr.Zero;
            _targetProcessName = null;
        }
        _skillSession = skill;
        _targetSelection = skill ? SelectionReader.ReadSelectedText() : null;
        Log.Info(
            "Recording start " +
            $"skill={skill} targetProcess={_targetProcessName ?? "unknown"} targetWindow=0x{_targetWindow.ToInt64():X}");

        // UIA 读不到选区（浏览器/Chrome、Electron、微信/企业微信/QQ 都接口残缺）→ Ctrl+C 兜底。
        // 异步不阻塞录音；保存并恢复剪贴板，非破坏性。UIA 能直接读到的原生应用根本走不到这一步。
        if (skill && _targetSelection is null)
        {
            _ = Task.Run(async () =>
            {
                var selected = await SelectionReader.ReadSelectedTextWithClipboardFallbackAsync();
                if (Phase == Phase.Recording) _targetSelection = selected;
            });
        }

        _ = LlmClient.PrewarmAsync();
        try
        {
            _recorder.Start();
        }
        catch (Exception ex)
        {
            Log.Error(ex, "Failed to start audio recorder");
            _overlay.FlashError(L10n.Tr("无法启动录音：", "Could not start recording: ") + ex.Message);
            Sounds.PlayError();
            return;
        }

        SetPhase(Phase.Recording);
        _overlay.ShowRecording(skill
            ? L10n.Tr("正在听指令…", "Listening for command…")
            : L10n.Tr("正在听…", "Listening…"));
        Sounds.PlayStart();
    }

    private async Task FinishRecordingAsync()
    {
        if (Phase != Phase.Recording) return;
        var samples = _recorder.Stop();
        var duration = samples.Length / 16000.0;
        var peak = samples.Length == 0 ? 0 : samples.Max(Math.Abs);
        Log.Info($"Recording stop duration={duration:0.###}s samples={samples.Length} peak={peak:0.####}");

        if (duration < 0.4)
        {
            SetPhase(Phase.Idle);
            _overlay.Hide();
            return;
        }

        if (peak < 0.012f)
        {
            SetPhase(Phase.Idle);
            _overlay.FlashError(L10n.Tr("没有听到内容", "Nothing heard"));
            return;
        }

        SetPhase(Phase.Processing);
        _overlay.ShowProcessing(L10n.Tr("识别中…", "Transcribing…"));

        string rawText;
        try
        {
            rawText = TextPostProcessor.ApplyVocabReplacements(
                TextPostProcessor.CleanTranscript(await _speechEngine.TranscribeAsync(samples)));
            if (TextPostProcessor.IsVocabEcho(rawText, SettingsStore.Instance.Current.VocabularyTerms))
            {
                rawText = "";
            }
        }
        catch (Exception ex)
        {
            Log.Error(ex, "Transcription pipeline failed");
            SetPhase(Phase.Idle);
            _overlay.FlashError(ex is MTException mt ? mt.UserMessage : ex.Message);
            Sounds.PlayError();
            return;
        }

        if (string.IsNullOrWhiteSpace(rawText))
        {
            Log.Warn("Transcription returned empty text");
            SetPhase(Phase.Idle);
            _overlay.FlashError(L10n.Tr("没有听到内容", "Nothing heard"));
            return;
        }

        if (_skillSession)
        {
            _skillSession = false;
            // 指令模式要跑 LLM。没配 API Key 时，明确提示用户「轻点」做纯语音输入（无需 Key），
            // 而不是长按——长按进的是需要 Key 的指令模式。教用户用对手势，不做剪贴板兜底。
            if (CredentialStore.Load(SettingsStore.Instance.Current.CurrentCredentialTarget) is null)
            {
                var keyName = SettingsStore.Instance.Current.Hotkey == HotkeyChoice.RightShift
                    ? L10n.Tr("右 Shift", "Right Shift")
                    : L10n.Tr("右 Ctrl", "Right Ctrl");
                Fail(L10n.Tr(
                    $"指令模式需配置 API Key；纯语音输入请「轻点」{keyName}（而非长按）",
                    $"Command mode needs an API key. For dictation, tap {keyName} (don't hold)"));
                return;
            }
            await RunSkillSessionAsync(rawText);
            return;
        }

        var settings = SettingsStore.Instance.Current;
        if (settings.PolishLevel != PolishLevel.Off &&
            CredentialStore.Load(settings.CurrentCredentialTarget) is not null)
        {
            _overlay.ShowProcessing(L10n.Tr("润色中…", "Polishing…"));
            var polished = await PolishService.PolishAsync(rawText, settings.PolishLevel);
            if (polished.Text is not null)
            {
                await DeliverAsync(rawText, polished.Text, L10n.Tr("已输入", "Inserted"));
            }
            else
            {
                await DeliverAsync(
                    rawText,
                    rawText,
                    L10n.Tr("润色失败（", "Polish failed (") +
                    (polished.Error ?? L10n.Tr("未知", "unknown")) +
                    L10n.Tr("），已输出识别原文", ") — raw transcript inserted"),
                    warning: true);
            }
        }
        else
        {
            await DeliverAsync(rawText, rawText, L10n.Tr("已输入", "Inserted"));
        }
    }

    private async Task RunSkillSessionAsync(string rawText)
    {
        Log.Info($"Skill dispatch selection={(_targetSelection is null ? "nil" : _targetSelection.Length + "chars")} app={_targetProcessName ?? "unknown"}");
        if (SkillRouter.IsReplyTrigger(rawText))
        {
            await RunReplyDraftAsync(rawText, rawText);
            return;
        }

        if (!string.IsNullOrWhiteSpace(_targetSelection))
        {
            await RunSelectionCommandAsync(_targetSelection!, rawText, rawText);
            return;
        }

        await RunFreeformAsync(rawText, rawText);
    }

    private async Task RunFreeformAsync(string instruction, string raw)
    {
        _overlay.ShowProcessing(L10n.Tr("执行指令中…", "Running command…"));
        var result = await AgentService.FreeformAsync(instruction);
        if (result.Text is not null)
        {
            Log.Info($"Freeform command succeeded resultChars={result.Text.Length}");
            await DeliverAsync(raw, result.Text, L10n.Tr("已输入指令结果", "Command result inserted"));
        }
        else
        {
            Log.Warn("Freeform command failed: " + (result.Error ?? "unknown"));
            Fail(L10n.Tr("指令执行失败（", "Command failed (") + (result.Error ?? L10n.Tr("未知", "unknown")) + ")");
        }
    }

    private async Task RunSelectionCommandAsync(string selection, string instruction, string raw)
    {
        _overlay.ShowProcessing(L10n.Tr("执行指令中…", "Running command…"));
        var chatContext = IsPoorSelectionApp(_targetProcessName);
        var result = await AgentService.RunOnSelectionAsync(selection, instruction, chatContext);
        if (result.Text is null)
        {
            Log.Warn("Selection command failed: " + (result.Error ?? "unknown"));
            Fail(L10n.Tr("指令执行失败（", "Command failed (") + (result.Error ?? L10n.Tr("未知", "unknown")) + ")");
            return;
        }
        Log.Info($"Selection command succeeded action={result.Action} resultChars={result.Text.Length}");

        switch (result.Action)
        {
            case SelectionAction.Modify:
                await DeliverAsync(raw, result.Text, L10n.Tr("已替换选中文本", "Selection replaced"));
                break;
            case SelectionAction.New:
                await DeliverAsync(raw, result.Text, L10n.Tr("已输入指令结果", "Command result inserted"));
                break;
            case SelectionAction.Reply:
                await CopyToClipboardAsync(raw, result.Text, L10n.Tr("回复草稿已复制——点到输入框按 Ctrl+V", "Reply draft copied — click the input field and press Ctrl+V"));
                break;
            default:
                await CopyToClipboardAsync(raw, result.Text, L10n.Tr("结果已复制到剪贴板——按 Ctrl+V 粘贴", "Result copied — press Ctrl+V to paste"));
                break;
        }
    }

    private async Task RunReplyDraftAsync(string instruction, string raw)
    {
        var context = _targetSelection;
        if (string.IsNullOrWhiteSpace(context))
        {
            _overlay.ShowProcessing(L10n.Tr("读取选中内容…", "Reading selection…"));
            context = await SelectionReader.ReadSelectedTextWithClipboardFallbackAsync();
        }

        if (string.IsNullOrWhiteSpace(context))
        {
            Log.Warn("Reply draft failed because selected context was empty");
            Fail(L10n.Tr("读不到选中内容：请重新选中要回复的消息再试", "Could not read selection — reselect the message and try again"));
            return;
        }

        _overlay.ShowProcessing(L10n.Tr("草拟回复中…", "Drafting reply…"));
        var result = await AgentService.ReplyDraftAsync(context, instruction);
        if (result.Text is not null)
        {
            Log.Info($"Reply draft succeeded resultChars={result.Text.Length}");
            await CopyToClipboardAsync(raw, result.Text, L10n.Tr("回复草稿已复制——点到输入框按 Ctrl+V", "Reply draft copied — click the input field and press Ctrl+V"));
        }
        else
        {
            Log.Warn("Reply draft failed: " + (result.Error ?? "unknown"));
            Fail(L10n.Tr("草拟失败（", "Draft failed (") + (result.Error ?? L10n.Tr("未知", "unknown")) + ")");
        }
    }

    private async Task DeliverAsync(string raw, string finalText, string note, bool warning = false)
    {
        // 托盘启动（无目标窗口）且此刻前台仍是任务栏/自己：粘贴必然落空，
        // 诚实地走"已复制"提示，而不是发一个没人接收的 Ctrl+V 然后误报"已输入"
        if (_targetWindow == IntPtr.Zero)
        {
            var fgName = GetProcessNameForWindow(TextInserter.CaptureForegroundWindow());
            if (fgName is null or "explorer" or "MicType")
            {
                Log.Info($"Deliver foreground is {fgName ?? "unknown"} — no paste target, clipboard only");
                await CopyToClipboardAsync(raw, finalText,
                    L10n.Tr("结果已复制——点到输入框按 Ctrl+V", "Copied — click the input field and press Ctrl+V"));
                return;
            }
        }

        var text = TextPostProcessor.ApplyVocabReplacements(TextPostProcessor.FixMixedPunctuation(finalText));
        _pendingDeliverText = text;
        Log.Info($"Deliver enter rawChars={raw.Length} finalChars={text.Length} targetProcess={_targetProcessName ?? "unknown"}");
        try
        {
            HistoryStore.Instance.Add(raw, text);
            var result = await TextInserter.InsertAsync(text, _targetWindow, _targetProcessName);
            Log.Info(
                "Deliver insert result " +
                $"outcome={result.Outcome} clipboardReady={result.ClipboardReady} error={result.Error ?? ""}");

            if (result.Outcome == InsertOutcome.Pasted)
            {
                Log.Info($"Deliver pasted rawChars={raw.Length} finalChars={text.Length} warning={warning}");
                if (warning) _overlay.FlashError(note);
                else _overlay.FlashSuccess(note);
                Sounds.PlaySuccess();
            }
            else
            {
                Log.Warn($"Deliver clipboard fallback rawChars={raw.Length} finalChars={text.Length} outcome={result.Outcome}");
                _overlay.FlashError(result.ClipboardReady
                    ? L10n.Tr("已复制到剪贴板——按 Ctrl+V 粘贴", "Copied to clipboard — press Ctrl+V to paste")
                    : L10n.Tr("投递失败，请重试", "Insert failed — please try again"));
                Sounds.PlayError();
            }
        }
        catch (Exception ex)
        {
            Log.Error(ex, "Deliver failed");
            var copied = await TextInserter.SetClipboardTextAsync(text);
            _overlay.FlashError(copied
                ? L10n.Tr("投递异常，结果已复制到剪贴板", "Insert failed; result copied to clipboard")
                : L10n.Tr("投递异常，请重试", "Insert failed — please try again"));
            Sounds.PlayError();
        }
        finally
        {
            _pendingDeliverText = null;
            SetPhase(Phase.Idle);
        }
    }

    private async Task CopyToClipboardAsync(string raw, string result, string note)
    {
        var text = TextPostProcessor.ApplyVocabReplacements(TextPostProcessor.FixMixedPunctuation(result));
        _pendingDeliverText = text;
        try
        {
            HistoryStore.Instance.Add(raw, text);
            var copied = await TextInserter.SetClipboardTextAsync(text);
            Log.Info($"Copied result to clipboard rawChars={raw.Length} finalChars={text.Length} copied={copied}");
            if (copied)
            {
                _overlay.FlashSuccess(note);
                Sounds.PlaySuccess();
            }
            else
            {
                _overlay.FlashError(L10n.Tr("复制失败，请重试", "Copy failed — please try again"));
                Sounds.PlayError();
            }
        }
        catch (Exception ex)
        {
            Log.Error(ex, "Copy result to clipboard failed");
            _overlay.FlashError(L10n.Tr("复制异常，请重试", "Copy failed — please try again"));
            Sounds.PlayError();
        }
        finally
        {
            _pendingDeliverText = null;
            SetPhase(Phase.Idle);
        }
    }

    private void Fail(string message)
    {
        Log.Warn("User-visible failure: " + message);
        SetPhase(Phase.Idle);
        _overlay.FlashError(message);
        Sounds.PlayError();
    }

    private void SetPhase(Phase phase)
    {
        Phase = phase;
        if (phase == Phase.Processing) _processingWatchdog.Arm();
        else _processingWatchdog.Disarm();

        var dispatcher = Application.Current.Dispatcher;
        if (dispatcher.CheckAccess())
        {
            PhaseChanged?.Invoke(phase);
        }
        else
        {
            dispatcher.BeginInvoke(() => PhaseChanged?.Invoke(phase));
        }
    }

    private async Task OnProcessingTimeoutAsync()
    {
        var pending = _pendingDeliverText;
        var copied = !string.IsNullOrWhiteSpace(pending) &&
                     await TextInserter.SetClipboardTextAsync(pending);
        SetPhase(Phase.Idle);
        _ = Application.Current.Dispatcher.BeginInvoke(() =>
        {
            _overlay.FlashError(copied
                ? L10n.Tr("处理超时，结果已复制到剪贴板", "Processing timed out; result copied to clipboard")
                : L10n.Tr("处理超时", "Processing timed out"));
            Sounds.PlayError();
        });
    }

    private static bool IsPoorSelectionApp(string? processName)
    {
        if (string.IsNullOrWhiteSpace(processName)) return false;
        return processName.Contains("WeChat", StringComparison.OrdinalIgnoreCase) ||
               processName.Contains("WXWork", StringComparison.OrdinalIgnoreCase) ||
               processName.Contains("QQ", StringComparison.OrdinalIgnoreCase);
    }

    private static string? GetProcessNameForWindow(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return null;
        GetWindowThreadProcessId(hwnd, out var pid);
        try
        {
            return Process.GetProcessById((int)pid).ProcessName;
        }
        catch (Exception ex)
        {
            Log.Error(ex, "Failed to get process name for target window");
            return null;
        }
    }

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
}
