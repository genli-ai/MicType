using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using MicType.Win.Core;

namespace MicType.Win.Services;

public enum InsertOutcome
{
    Pasted,
    ClipboardOnly,
    Timeout,
    Error
}

public sealed record InsertResult(InsertOutcome Outcome, bool ClipboardReady, string? Error = null);

public static class TextInserter
{
    private static readonly StaWorker Worker = new("MicType Clipboard STA");
    private static readonly TimeSpan InsertTimeout = TimeSpan.FromSeconds(5);
    private static readonly TimeSpan ClipboardTimeout = TimeSpan.FromMilliseconds(750);
    private static readonly TimeSpan RestoreDelay = TimeSpan.FromSeconds(5);

    // ── 剪贴板恢复会话（全 App 唯一，只在 STA worker 线程上读写）────────────────────
    //
    // 旧实现是裸的 `Task.Run + Task.Delay(5s)`：不可取消，判据还是"字符串相等"，快照只存
    // 一个 string。两个后果：
    //   1) 连着听写两次、间隔 <5s 时，第二次会把 **MicType 自己刚写进去的输出**当成
    //      "用户的原剪贴板"快照下来，用户真正的原内容被链式覆盖，永久丢失。
    //   2) 剪贴板里是图片/文件/富文本时，写文本那一刻的 EmptyClipboard 就把它们毁了。
    // 所以恢复任务收敛成单一可取消的 CancellationTokenSource，由 TextInserter 持有：
    // 新插入先取消旧任务，并在剪贴板确实还是我们上次写的那一份时**沿用最早的那份非自产快照**。
    // 与 Mac 端 TextInserter.swift 的会话模型同源（那边是 DispatchWorkItem + changeCount）。

    /// 待执行的恢复任务；null = 当前没有待恢复的会话
    private static CancellationTokenSource? _pendingRestore;
    /// 待恢复的原剪贴板（永远是最早的那份非自产快照）
    private static ClipboardSnapshot? _pendingSnapshot;
    /// 我们自己最后一次写入剪贴板之后的序列号；0 = 没在跟踪
    private static uint _ourSequence;

    public static IntPtr CaptureForegroundWindow() => GetForegroundWindow();

    public static async Task<InsertResult> InsertAsync(
        string text,
        IntPtr targetWindow,
        string? targetProcessName = null,
        bool allowClipboardRestore = true,
        bool conservativePaste = false)
    {
        Log.Info(
            "Insert begin " +
            $"targetWindow=0x{targetWindow.ToInt64():X} targetProcess={targetProcessName ?? "unknown"} chars={text.Length}");

        var operation = Worker.InvokeAsync(() =>
            InsertCore(text, targetWindow, targetProcessName, allowClipboardRestore, conservativePaste));
        var completed = await Task.WhenAny(operation, Task.Delay(InsertTimeout));
        if (completed == operation)
        {
            return await operation;
        }

        Log.Warn("Insert timeout; paste abandoned after 5s");
        _ = operation.ContinueWith(
            task => Log.Error(task.Exception!, "Timed-out insert later failed"),
            TaskContinuationOptions.OnlyOnFaulted);
        var clipboardReady = await TrySetClipboardTextOnTemporaryStaAsync(text, TimeSpan.FromSeconds(1));
        Log.Warn($"Insert timeout fallback clipboardReady={clipboardReady}");
        return new InsertResult(InsertOutcome.Timeout, clipboardReady, "Insert timed out");
    }

    public static async Task<bool> SetClipboardTextAsync(string text)
    {
        var result = await Worker.InvokeAsync(() =>
        {
            // 文本要留在剪贴板等用户 Ctrl+V：上一次插入遗留的恢复任务必须放弃，
            // 否则它 5 秒后会把这段用户正要粘的文字擦掉（Mac 端 putOnClipboard 同理）
            DropPendingRestore("text-left-on-clipboard");
            return TrySetClipboardText(text, ClipboardTimeout);
        });
        Log.Info($"Clipboard write text chars={text.Length} ok={result}");
        return result;
    }

    public static Task<string?> GetClipboardTextAsync()
    {
        return Worker.InvokeAsync(() => TryGetClipboardText(ClipboardTimeout));
    }

    /// 给 SelectionReader 的 Ctrl+C 兜底用：拍一份全格式快照（兜底会用选区把剪贴板顶掉，
    /// 完事必须原样还回去）。返回 null = 剪贴板打不开，调用方应放弃兜底而不是硬上。
    internal static Task<ClipboardSnapshot?> CaptureClipboardSnapshotAsync()
    {
        return Worker.InvokeAsync(() => ClipboardSnapshot.Capture(ClipboardTimeout));
    }

    /// 兜底结束后把快照原样写回。内容一模一样，但剪贴板序列号必然跳一格；
    /// 不同步给插入会话的话，它待恢复的任务会误判成"用户复制了新东西"而放弃恢复，
    /// 用户的原剪贴板就此丢失。与 Mac 端 clipboardRewritten(previousChangeCount:newChangeCount:) 同源。
    internal static Task<bool> RestoreClipboardSnapshotAsync(ClipboardSnapshot snapshot)
    {
        return Worker.InvokeAsync(() =>
        {
            // 拍快照那一刻剪贴板还是我们自己写的那一份吗？是的话写回后要把会话接上
            var wasOurs = _pendingRestore is not null && _ourSequence != 0 &&
                          _ourSequence == snapshot.SequenceNumber;
            var ok = snapshot.Restore(ClipboardTimeout);
            if (ok && wasOurs)
            {
                _ourSequence = GetClipboardSequenceNumber();
                Log.Info($"Clipboard session follows rewrite sequence={_ourSequence}");
            }
            return ok;
        });
    }

    internal static void SendCtrlC()
    {
        Worker.Post(() =>
        {
            Log.Info("SendInput Ctrl+C");
            SendModifiedKey(0x11, 0x43, 30);
        });
    }

    private static InsertResult InsertCore(
        string text,
        IntPtr targetWindow,
        string? targetProcessName,
        bool allowClipboardRestore,
        bool conservativePaste)
    {
        try
        {
            if (targetWindow != IntPtr.Zero && GetForegroundWindow() != targetWindow)
            {
                Log.Info(
                    "Insert focus switch " +
                    $"targetWindow=0x{targetWindow.ToInt64():X} targetProcess={targetProcessName ?? "unknown"}");
                var focused = SetForegroundWindow(targetWindow);
                Log.Info($"Insert focus SetForegroundWindow result={focused}");
                Thread.Sleep(conservativePaste ? 750 : 250);
            }

            // 快照必须在写文本**之前**拍：TrySetClipboardText 内部的 EmptyClipboard 一落，
            // 图片 / 文件列表 / 富文本当场就没了。旧实现只存一个 string，这一刀在粘贴那一刻
            // 就把非文本剪贴板永久毁掉了，不是 5 秒后恢复时才发生。
            var wantRestore = allowClipboardRestore && SettingsStore.Instance.Current.RestoreClipboard;
            var snapshot = TakeRestoreSnapshot(wantRestore);

            var clipboardReady = TrySetClipboardText(text, ClipboardTimeout);
            Log.Info($"Insert clipboard write result={clipboardReady} chars={text.Length}");
            if (!clipboardReady)
            {
                return new InsertResult(InsertOutcome.Error, ClipboardReady: false, Error: "Could not write clipboard");
            }

            _pendingSnapshot = snapshot;
            _ourSequence = GetClipboardSequenceNumber();

            if (targetWindow != IntPtr.Zero && GetForegroundWindow() != targetWindow)
            {
                Log.Warn($"Insert clipboard fallback; foreground did not return to target=0x{targetWindow.ToInt64():X}");
                // 文本留在剪贴板等用户手动 Ctrl+V：此时恢复原剪贴板会把他要粘的字擦掉
                DropPendingRestore("text-left-on-clipboard");
                return new InsertResult(InsertOutcome.ClipboardOnly, ClipboardReady: true);
            }

            Thread.Sleep(conservativePaste ? 350 : 180);
            Log.Info("Insert SendInput Ctrl+V");
            if (!SendCtrlV(conservativePaste ? 120 : 30))
            {
                // 粘贴按键没发出去：文本还在剪贴板，降级提示用户手动 Ctrl+V（此时绝不能恢复旧剪贴板）
                Log.Warn("Insert clipboard fallback; SendInput rejected the paste keystrokes");
                DropPendingRestore("text-left-on-clipboard");
                return new InsertResult(InsertOutcome.ClipboardOnly, ClipboardReady: true);
            }

            if (snapshot is not null)
            {
                ScheduleClipboardRestore(snapshot);
            }

            Log.Info($"Insert end outcome=Pasted chars={text.Length}");
            return new InsertResult(InsertOutcome.Pasted, ClipboardReady: true);
        }
        catch (Exception ex)
        {
            Log.Error(ex, "Insert failed");
            return new InsertResult(InsertOutcome.Error, ClipboardReady: false, Error: ex.Message);
        }
    }

    /// 为这一次插入挑出"待恢复的原剪贴板"。必须在 STA worker 线程上、写入文本**之前**调用。
    private static ClipboardSnapshot? TakeRestoreSnapshot(bool wantRestore)
    {
        // 先取消上一次还没跑的恢复任务，再决定这次用哪份快照
        _pendingRestore?.Cancel();
        _pendingRestore = null;

        if (!wantRestore)
        {
            if (_pendingSnapshot is not null)
            {
                Log.Info("Clipboard pending restore dropped reason=restore-disabled");
            }
            _pendingSnapshot = null;
            _ourSequence = 0;
            return null;
        }

        if (_pendingSnapshot is not null && _ourSequence != 0 &&
            GetClipboardSequenceNumber() == _ourSequence)
        {
            // 剪贴板里躺的还是 MicType 上次写进去的输出 → 用户的原内容在那份旧快照里，沿用它。
            // 绝不能在这里重新快照：那等于把"我们自己上一句的听写结果"当成用户的原剪贴板，
            // 5 秒后还回去的是 MicType 的输出，用户真正的内容被链式覆盖、永久丢失。
            Log.Info($"Clipboard snapshot carried over {_pendingSnapshot.LogSummary}");
            return _pendingSnapshot;
        }

        var fresh = ClipboardSnapshot.Capture(ClipboardTimeout);
        if (fresh is null || fresh.IsOversize)
        {
            // 读不到（剪贴板被别的进程按住）或大到超预算：宁可这一次不恢复，
            // 也不拿一份空快照去写回（那是把用户的剪贴板清空）。日志里说清楚，出事有据可查。
            Log.Warn("Clipboard snapshot skipped " + (fresh?.LogSummary ?? "open timeout")
                     + " — original clipboard will NOT be restored this time");
            return null;
        }

        Log.Info($"Clipboard snapshot {fresh.LogSummary}");
        return fresh;
    }

    /// 排一次延迟恢复。整个 App 同时只有一个，新插入会先把它取消掉。
    private static void ScheduleClipboardRestore(ClipboardSnapshot snapshot)
    {
        var cts = new CancellationTokenSource();
        _pendingRestore = cts;
        _ = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(RestoreDelay, cts.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return;   // 新一轮插入接管了这次会话
            }

            await Worker.InvokeAsync(() =>
            {
                // 已经被新插入顶掉：那边自己会安排恢复，这里绝不能插手
                if (!ReferenceEquals(_pendingRestore, cts)) return;

                // 判据用剪贴板序列号而不是字符串相等：多格式的剪贴板根本比不出来，
                // 而"用户恰好复制了一模一样的文字"会被字符串判据误判成我们自己的输出
                if (GetClipboardSequenceNumber() != _ourSequence)
                {
                    Log.Info("Clipboard restore skipped reason=changed-by-user");
                    ClearSession();
                    return;
                }

                var ok = snapshot.Restore(ClipboardTimeout);
                Log.Info($"Clipboard restored formats={snapshot.FormatCount} ok={ok}"
                         + (snapshot.IsEmpty ? " (was empty → cleared)" : ""));
                ClearSession();
            }).ConfigureAwait(false);
        });
    }

    /// 放弃当前待恢复会话：用于"文本要留在剪贴板给用户 Ctrl+V"的路径——
    /// 此时恢复原剪贴板会把用户正要粘的文字擦掉，宁可不恢复。只在 STA worker 线程上调用。
    private static void DropPendingRestore(string reason)
    {
        if (_pendingRestore is null && _pendingSnapshot is null) return;
        _pendingRestore?.Cancel();
        ClearSession();
        Log.Info($"Clipboard pending restore dropped reason={reason}");
    }

    /// 恢复任务跑完后收尾
    private static void ClearSession()
    {
        _pendingRestore = null;
        _pendingSnapshot = null;
        _ourSequence = 0;
    }

    private static bool TrySetClipboardText(string? text, TimeSpan timeout)
    {
        var deadline = DateTimeOffset.UtcNow + timeout;
        do
        {
            if (OpenClipboard(IntPtr.Zero))
            {
                try
                {
                    EmptyClipboard();
                    if (text is null)
                    {
                        return true;
                    }

                    var bytes = (text.Length + 1) * 2;
                    var handle = GlobalAlloc(GmemMoveable, (UIntPtr)bytes);
                    if (handle == IntPtr.Zero) return false;

                    var locked = GlobalLock(handle);
                    if (locked == IntPtr.Zero)
                    {
                        GlobalFree(handle);
                        return false;
                    }

                    try
                    {
                        Marshal.Copy(text.ToCharArray(), 0, locked, text.Length);
                        Marshal.WriteInt16(locked, text.Length * 2, 0);
                    }
                    finally
                    {
                        GlobalUnlock(handle);
                    }

                    if (SetClipboardData(CfUnicodeText, handle) == IntPtr.Zero)
                    {
                        GlobalFree(handle);
                        return false;
                    }

                    return true;
                }
                finally
                {
                    CloseClipboard();
                }
            }

            Thread.Sleep(35);
        } while (DateTimeOffset.UtcNow < deadline);

        Log.Warn("Clipboard write timed out waiting for OpenClipboard");
        return false;
    }

    private static async Task<bool> TrySetClipboardTextOnTemporaryStaAsync(string text, TimeSpan timeout)
    {
        var tcs = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            try
            {
                tcs.SetResult(TrySetClipboardText(text, timeout));
            }
            catch (Exception ex)
            {
                tcs.SetException(ex);
            }
        })
        {
            IsBackground = true,
            Name = "MicType Clipboard Timeout Fallback"
        };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();

        var completed = await Task.WhenAny(tcs.Task, Task.Delay(timeout + TimeSpan.FromMilliseconds(250)));
        if (completed != tcs.Task)
        {
            Log.Warn("Temporary STA clipboard write timed out");
            return false;
        }

        return await tcs.Task;
    }

    private static string? TryGetClipboardText(TimeSpan timeout)
    {
        var deadline = DateTimeOffset.UtcNow + timeout;
        do
        {
            if (OpenClipboard(IntPtr.Zero))
            {
                try
                {
                    if (!IsClipboardFormatAvailable(CfUnicodeText)) return null;
                    var handle = GetClipboardData(CfUnicodeText);
                    if (handle == IntPtr.Zero) return null;
                    var locked = GlobalLock(handle);
                    if (locked == IntPtr.Zero) return null;
                    try
                    {
                        return Marshal.PtrToStringUni(locked);
                    }
                    finally
                    {
                        GlobalUnlock(handle);
                    }
                }
                finally
                {
                    CloseClipboard();
                }
            }

            Thread.Sleep(35);
        } while (DateTimeOffset.UtcNow < deadline);

        Log.Warn("Clipboard read timed out waiting for OpenClipboard");
        return null;
    }

    private static bool SendCtrlV(int holdMilliseconds)
    {
        return SendModifiedKey(0x11, 0x56, holdMilliseconds);
    }

    private static bool SendModifiedKey(ushort modifier, ushort key, int holdMilliseconds)
    {
        var inputs = new[]
        {
            KeyboardInput(modifier, false),
            KeyboardInput(key, false),
            KeyboardInput(key, true),
            KeyboardInput(modifier, true)
        };
        var sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Input>());
        if (sent != inputs.Length)
        {
            Log.Warn($"SendInput key=0x{key:X} sent={sent}/{inputs.Length} lastError={Marshal.GetLastWin32Error()}");
            return false;
        }

        Log.Info($"SendInput key=0x{key:X} sent={sent}/{inputs.Length}");
        if (holdMilliseconds > 30)
        {
            Thread.Sleep(holdMilliseconds);
        }
        return true;
    }

    private static Input KeyboardInput(ushort key, bool keyUp) => new()
    {
        Type = 1,
        U = new InputUnion
        {
            Ki = new KeyboardInputStruct
            {
                WVk = key,
                DwFlags = keyUp ? 0x0002u : 0
            }
        }
    };

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, Input[] pInputs, int cbSize);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool OpenClipboard(IntPtr hWndNewOwner);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool CloseClipboard();

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool EmptyClipboard();

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetClipboardData(uint uFormat, IntPtr hMem);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr GetClipboardData(uint uFormat);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool IsClipboardFormatAvailable(uint format);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint EnumClipboardFormats(uint format);

    /// 剪贴板每被写一次就 +1。判断"剪贴板还是我认识的那一份吗"只能靠它——
    /// 不需要打开剪贴板，也骗不过多格式内容和"用户恰好复制了同样文字"的情况。
    [DllImport("user32.dll")]
    private static extern uint GetClipboardSequenceNumber();

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern UIntPtr GlobalSize(IntPtr hMem);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GlobalAlloc(uint uFlags, UIntPtr dwBytes);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GlobalLock(IntPtr hMem);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GlobalUnlock(IntPtr hMem);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GlobalFree(IntPtr hMem);

    private const uint CfUnicodeText = 13;
    private const uint GmemMoveable = 0x0002;

    [StructLayout(LayoutKind.Sequential)]
    private struct Input
    {
        public uint Type;
        public InputUnion U;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        // MOUSEINPUT 是 union 里最大的成员——没有它 INPUT 在 x64 上只有 32 字节而系统要求 40，
        // SendInput 会拒收全部输入并返回 0（真机三轮 "sent=0/4" 的根因）
        [FieldOffset(0)] public MouseInputStruct Mi;
        [FieldOffset(0)] public KeyboardInputStruct Ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MouseInputStruct
    {
        public int Dx;
        public int Dy;
        public uint MouseData;
        public uint DwFlags;
        public uint Time;
        public IntPtr DwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KeyboardInputStruct
    {
        public ushort WVk;
        public ushort WScan;
        public uint DwFlags;
        public uint Time;
        public IntPtr DwExtraInfo;
    }

    /// 剪贴板的**全格式**快照：一份剪贴板同时挂着多种格式（CF_UNICODETEXT + CF_HTML +
    /// CF_DIB + CF_HDROP…）。只快照纯文本再写回，等于把其余格式全抹掉——原剪贴板是图片 /
    /// 文件时更是直接归零，而且这一刀在**写入文本那一刻**（EmptyClipboard）就落下了，
    /// 不是 5 秒后恢复时才发生。与 Mac 端 TextInserter.swift 的 ClipboardSnapshot 同源。
    /// 所有方法都必须在 STA worker 线程上调用。
    internal sealed class ClipboardSnapshot
    {
        /// 快照预算：超过就整份放弃。给得这么宽是刻意的——一张 5K 截图的 CF_DIB 就有几十 MB，
        /// 而"复制一张图 → 听写一句 → 图还在"正是全格式快照要保住的头号场景，预算卡小了
        /// 等于把这个功能废掉。这里只拦病态量级：那种整份读进内存、驻留、再写回，
        /// 低内存机器上会被压去交换。
        private const long CaptureBudget = 256L * 1024 * 1024;

        private readonly List<(uint Format, byte[] Data)> _items;
        private readonly long _byteCount;

        /// 快照那一刻的剪贴板序列号——所有"剪贴板还是我认识的那一份吗"的判据都用它
        public uint SequenceNumber { get; }
        /// 拿不到数据的格式数（非 HGLOBAL 句柄 / 延迟渲染失败），只用于日志
        public int SkippedFormats { get; }
        /// 剪贴板大到超出预算 → 整份放弃（什么都没存）。调用方必须据此决定"这次不恢复"，
        /// 而不是拿一份空快照去 Restore——那会把剪贴板清空。
        public bool IsOversize { get; }

        public int FormatCount => _items.Count;
        public bool IsEmpty => _items.Count == 0;

        /// 只有格式号和字节数，绝不含剪贴板内容——日志里永远看不到用户复制了什么
        public string LogSummary =>
            $"formats={FormatCount} bytes={_byteCount} skipped={SkippedFormats}"
            + (IsOversize ? " OVERSIZE" : "")
            + " [" + string.Join(",", _items.Take(6).Select(i => i.Format)) + "]";

        private ClipboardSnapshot(List<(uint Format, byte[] Data)> items, uint sequence,
                                  int skipped, long byteCount, bool isOversize)
        {
            _items = items;
            SequenceNumber = sequence;
            SkippedFormats = skipped;
            _byteCount = byteCount;
            IsOversize = isOversize;
        }

        /// 拍一份全格式快照。返回 null = 剪贴板打不开（被别的进程按住）：不知道原内容是什么，
        /// 调用方必须放弃恢复，而不是拿空快照去写回。
        public static ClipboardSnapshot? Capture(TimeSpan timeout)
        {
            var deadline = DateTimeOffset.UtcNow + timeout;
            do
            {
                if (OpenClipboard(IntPtr.Zero))
                {
                    try
                    {
                        var sequence = GetClipboardSequenceNumber();
                        var items = new List<(uint Format, byte[] Data)>();
                        var skipped = 0;
                        long bytes = 0;
                        uint format = 0;
                        while ((format = EnumClipboardFormats(format)) != 0)
                        {
                            if (IsUnsafeToSnapshot(format)) { skipped++; continue; }
                            var handle = GetClipboardData(format);
                            if (handle == IntPtr.Zero) { skipped++; continue; }
                            var size = (long)GlobalSize(handle).ToUInt64();
                            if (size <= 0) { skipped++; continue; }
                            if (bytes + size > CaptureBudget)
                            {
                                // 就地放弃，不把已经读到的几百 MB 继续攥在手里
                                Log.Warn($"Clipboard snapshot over budget bytes={bytes + size} — giving up this snapshot");
                                return new ClipboardSnapshot(new List<(uint Format, byte[] Data)>(),
                                    sequence, skipped, bytes + size, isOversize: true);
                            }

                            var locked = GlobalLock(handle);
                            if (locked == IntPtr.Zero) { skipped++; continue; }
                            try
                            {
                                var buffer = new byte[size];
                                Marshal.Copy(locked, buffer, 0, (int)size);
                                items.Add((format, buffer));
                                bytes += size;
                            }
                            finally
                            {
                                GlobalUnlock(handle);
                            }
                        }

                        return new ClipboardSnapshot(items, sequence, skipped, bytes, isOversize: false);
                    }
                    finally
                    {
                        CloseClipboard();
                    }
                }

                Thread.Sleep(35);
            } while (DateTimeOffset.UtcNow < deadline);

            Log.Warn("Clipboard snapshot timed out waiting for OpenClipboard");
            return null;
        }

        /// 原样写回。快照为空说明当时剪贴板本来就是空的（或只剩读不了的格式）→ 清空，
        /// 别把 MicType 的输出留在那儿。超预算的快照根本没存内容：不能写回，更不能清空。
        public bool Restore(TimeSpan timeout)
        {
            if (IsOversize) return false;

            var deadline = DateTimeOffset.UtcNow + timeout;
            do
            {
                if (OpenClipboard(IntPtr.Zero))
                {
                    try
                    {
                        EmptyClipboard();
                        foreach (var (format, data) in _items)
                        {
                            var handle = GlobalAlloc(GmemMoveable, (UIntPtr)(ulong)data.Length);
                            if (handle == IntPtr.Zero) continue;
                            var locked = GlobalLock(handle);
                            if (locked == IntPtr.Zero)
                            {
                                GlobalFree(handle);
                                continue;
                            }
                            try
                            {
                                Marshal.Copy(data, 0, locked, data.Length);
                            }
                            finally
                            {
                                GlobalUnlock(handle);
                            }
                            // SetClipboardData 成功后句柄归系统所有，失败才由我们释放
                            if (SetClipboardData(format, handle) == IntPtr.Zero) GlobalFree(handle);
                        }

                        return true;
                    }
                    finally
                    {
                        CloseClipboard();
                    }
                }

                Thread.Sleep(35);
            } while (DateTimeOffset.UtcNow < deadline);

            Log.Warn("Clipboard restore timed out waiting for OpenClipboard");
            return false;
        }

        /// 非 HGLOBAL 句柄（位图 / 图元文件 / 调色板 / GDI 对象 / 应用私有格式）：
        /// 对它们调 GlobalSize / GlobalLock 是无定义行为，一律跳过。
        /// 截图走 CF_DIB(8) / CF_DIBV5(17)、文件列表走 CF_HDROP(15)，都是 HGLOBAL——
        /// 图片和文件照样保得住，跳过的只是同一份内容的另一种句柄表示。
        private static bool IsUnsafeToSnapshot(uint format)
        {
            return format is 2u          // CF_BITMAP
                    or 3u                // CF_METAFILEPICT
                    or 9u                // CF_PALETTE
                    or 14u               // CF_ENHMETAFILE
                    or 0x0080u           // CF_OWNERDISPLAY
                    or 0x0082u           // CF_DSPBITMAP
                    or 0x0083u           // CF_DSPMETAFILEPICT
                    or 0x008Eu           // CF_DSPENHMETAFILE
                || format is >= 0x0200u and <= 0x02FFu    // CF_PRIVATEFIRST..CF_PRIVATELAST
                || format is >= 0x0300u and <= 0x03FFu;   // CF_GDIOBJFIRST..CF_GDIOBJLAST
        }
    }

    private sealed class StaWorker
    {
        private readonly BlockingCollection<Action> _queue = new();

        public StaWorker(string name)
        {
            var thread = new Thread(Run)
            {
                IsBackground = true,
                Name = name
            };
            thread.SetApartmentState(ApartmentState.STA);
            thread.Start();
        }

        public Task InvokeAsync(Action action)
        {
            var tcs = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            _queue.Add(() =>
            {
                try
                {
                    action();
                    tcs.SetResult();
                }
                catch (Exception ex)
                {
                    tcs.SetException(ex);
                }
            });
            return tcs.Task;
        }

        public Task<T> InvokeAsync<T>(Func<T> func)
        {
            var tcs = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
            _queue.Add(() =>
            {
                try
                {
                    tcs.SetResult(func());
                }
                catch (Exception ex)
                {
                    tcs.SetException(ex);
                }
            });
            return tcs.Task;
        }

        public void Post(Action action)
        {
            _queue.Add(() =>
            {
                try
                {
                    action();
                }
                catch (Exception ex)
                {
                    Log.Error(ex, "STA worker posted action failed");
                }
            });
        }

        private void Run()
        {
            foreach (var action in _queue.GetConsumingEnumerable())
            {
                action();
            }
        }
    }
}
