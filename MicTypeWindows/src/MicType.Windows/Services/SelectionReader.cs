using System.Windows.Automation;
using MicType.Win.Core;

namespace MicType.Win.Services;

public static class SelectionReader
{
    public static string? ReadSelectedText()
    {
        try
        {
            var focused = AutomationElement.FocusedElement;
            if (focused is null) return null;
            if (!focused.TryGetCurrentPattern(TextPattern.Pattern, out var patternObj)) return null;
            var pattern = (TextPattern)patternObj;
            var ranges = pattern.GetSelection();
            var text = string.Join("", ranges.Select(r => r.GetText(-1)));
            return string.IsNullOrWhiteSpace(text) ? null : text;
        }
        catch (Exception ex)
        {
            Log.Error(ex, "Failed to read selected text through UI Automation");
            return null;
        }
    }

    public static async Task<string?> ReadSelectedTextWithClipboardFallbackAsync()
    {
        var direct = ReadSelectedText();
        if (!string.IsNullOrWhiteSpace(direct)) return direct;

        // 全格式快照：用户的剪贴板里可能是图片 / 文件 / 富文本，只存纯文本再写回
        // 等于把这些格式抹掉（原来没有文本时 oldText 还是 null，剪贴板直接归零）。
        // 与 Mac 端 SelectionReader.swift 的 ⌘C 兜底同源。
        var snapshot = await TextInserter.CaptureClipboardSnapshotAsync();
        if (snapshot is null || snapshot.IsOversize)
        {
            // 快照拿不到（剪贴板被按住）或大到整份放弃：这时候再发 Ctrl+C，
            // 等于拿选区把它顶掉且永远还不回来。宁可让这次指令降级成"没选区"，
            // 也不毁掉用户剪贴板里的那份东西。
            Log.Warn("Selection fallback skipped: clipboard could not be snapshotted");
            return null;
        }
        Log.Info($"Selection fallback snapshot {snapshot.LogSummary}");

        TextInserter.SendCtrlC();
        await Task.Delay(350);

        var copied = await TextInserter.GetClipboardTextAsync();
        // 原样写回，不留痕迹；写回会让序列号跳一格，RestoreClipboardSnapshotAsync
        // 内部会把这一跳同步给插入会话，否则它待恢复的任务会误判成"用户复制了新东西"
        var restored = await TextInserter.RestoreClipboardSnapshotAsync(snapshot);
        Log.Info($"Selection fallback restored formats={snapshot.FormatCount} ok={restored}");

        return string.IsNullOrWhiteSpace(copied) ? null : copied;
    }
}
