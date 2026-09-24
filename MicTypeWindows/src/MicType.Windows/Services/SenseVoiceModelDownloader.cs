using System.Globalization;
using System.IO;
using System.Net.Http;
using MicType.Win.Core;
using SharpCompress.Common;
using SharpCompress.Readers;

namespace MicType.Win.Services;

public sealed record SenseVoiceDownloadState(
    bool IsDownloading,
    double? Progress,
    string StatusText,
    bool IsAvailable);

public sealed class SenseVoiceModelDownloader
{
    public const string ModelId = "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17";
    public const string ArchiveFileName = ModelId + ".tar.bz2";

    public static readonly Uri PrimaryArchiveUri =
        new($"https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/{ArchiveFileName}");

    public static readonly Uri[] MirrorArchiveUris =
    [
        new($"https://gh-proxy.com/https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/{ArchiveFileName}")
    ];

    private static readonly HttpClient HttpClient = new()
    {
        Timeout = TimeSpan.FromHours(2)
    };

    private readonly SemaphoreSlim _downloadLock = new(1, 1);
    private CancellationTokenSource? _downloadCts;

    public static SenseVoiceModelDownloader Shared { get; } = new();

    public event Action<SenseVoiceDownloadState>? StateChanged;

    public string ModelDirectory { get; private set; }

    public SenseVoiceDownloadState CurrentState { get; private set; }

    public SenseVoiceModelDownloader(string? modelDirectory = null)
    {
        ModelDirectory = ResolveModelDirectory(modelDirectory);
        CurrentState = new SenseVoiceDownloadState(
            false,
            null,
            SenseVoiceModelPaths.IsAvailable(ModelDirectory)
                ? L10n.Tr("SenseVoice 模型已就绪", "SenseVoice model ready")
                : L10n.Tr("SenseVoice 模型未下载", "SenseVoice model not downloaded"),
            SenseVoiceModelPaths.IsAvailable(ModelDirectory));
    }

    public static Uri[] BuildArchiveUris() => [PrimaryArchiveUri, .. MirrorArchiveUris];

    public static string ResolveModelDirectory(string? customDir)
    {
        if (!string.IsNullOrWhiteSpace(customDir)) return customDir;
        var settingsDir = SettingsStore.Instance.Current.SpeechModelDirectory;
        if (!string.IsNullOrWhiteSpace(settingsDir)) return settingsDir;
        return AppPaths.SenseVoiceModelDir;
    }

    public void SetModelDirectory(string directory)
    {
        if (string.IsNullOrWhiteSpace(directory)) return;
        ModelDirectory = directory;
        Refresh();
    }

    public void DeleteModelFiles()
    {
        if (!Directory.Exists(ModelDirectory)) return;
        try
        {
            foreach (var entry in Directory.EnumerateFileSystemEntries(ModelDirectory))
            {
                try
                {
                    if (File.Exists(entry))
                    {
                        File.Delete(entry);
                    }
                    else if (Directory.Exists(entry))
                    {
                        Directory.Delete(entry, recursive: true);
                    }
                }
                catch (Exception ex)
                {
                    Log.Error(ex, "Failed to delete model file: " + entry);
                }
            }
            Log.Info("Model files deleted from " + ModelDirectory);
        }
        catch (Exception ex)
        {
            Log.Error(ex, "Failed to enumerate model directory for deletion: " + ModelDirectory);
        }
        Refresh();
    }

    public bool IsModelAvailable => SenseVoiceModelPaths.IsAvailable(ModelDirectory);

    public SenseVoiceModelPaths FindModelFiles() => SenseVoiceModelPaths.Find(ModelDirectory);

    public void Refresh()
    {
        Publish(false, null, IsModelAvailable
            ? L10n.Tr("SenseVoice 模型已就绪", "SenseVoice model ready")
            : L10n.Tr("SenseVoice 模型未下载", "SenseVoice model not downloaded"));
    }

    public void CancelDownload()
    {
        _downloadCts?.Cancel();
    }

    public async Task DownloadAsync(bool force = false, CancellationToken cancellationToken = default)
    {
        await _downloadLock.WaitAsync(cancellationToken);
        try
        {
            if (!force && IsModelAvailable)
            {
                Log.Info("SenseVoice download skipped; model already available");
                Refresh();
                return;
            }

            using var linkedCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            _downloadCts = linkedCts;
            var ct = linkedCts.Token;

            var parentDir = Path.GetDirectoryName(Path.GetFullPath(ModelDirectory)) ?? AppPaths.ModelsDir;
            Directory.CreateDirectory(parentDir);
            var stagingDir = Path.Combine(parentDir, $"sensevoice-download-{Guid.NewGuid():N}");
            var archivePath = Path.Combine(parentDir, ArchiveFileName + ".download");
            Directory.CreateDirectory(stagingDir);

            try
            {
                Log.Info($"SenseVoice download started force={force} dir={ModelDirectory}");
                Exception? lastError = null;
                foreach (var uri in BuildArchiveUris())
                {
                    try
                    {
                        Log.Info("SenseVoice download source " + uri);
                        Publish(true, 0, L10n.Tr("正在下载 SenseVoice 模型…", "Downloading SenseVoice model..."));
                        await DownloadArchiveAsync(uri, archivePath, ct);
                        lastError = null;
                        break;
                    }
                    catch (Exception ex) when (ex is not OperationCanceledException)
                    {
                        Log.Error(ex, "SenseVoice download source failed: " + uri);
                        lastError = ex;
                    }
                }

                if (lastError is not null)
                {
                    throw lastError;
                }

                Publish(true, null, L10n.Tr("正在解压模型…", "Extracting model..."));
                Log.Info("SenseVoice extracting archive");
                await Task.Run(() => ExtractArchive(archivePath, stagingDir));

                if (!SenseVoiceModelPaths.IsAvailable(stagingDir))
                {
                    throw new InvalidDataException(
                        $"Downloaded SenseVoice archive is missing {string.Join(", ", SenseVoiceModelPaths.RequiredFileNames)}.");
                }

                Publish(true, null, L10n.Tr("正在安装模型…", "Installing model..."));
                await Task.Run(() => ReplaceModelDirectory(stagingDir, ModelDirectory));
                Log.Info("SenseVoice model installed");
                Publish(false, null, L10n.Tr("SenseVoice 模型已就绪", "SenseVoice model ready"));
            }
            catch (OperationCanceledException ex)
            {
                Log.Error(ex, "SenseVoice download cancelled");
                Publish(false, null, L10n.Tr("已取消下载", "Download cancelled"));
                throw;
            }
            catch (Exception ex)
            {
                Log.Error(ex, "SenseVoice download failed");
                Publish(false, null, L10n.Tr("模型下载失败：", "Model download failed: ") + ex.Message);
                throw new MTException(L10n.Tr("模型下载失败：", "Model download failed: ") + ex.Message);
            }
            finally
            {
                TryDeleteFile(archivePath);
                TryDeleteDirectory(stagingDir);
                _downloadCts = null;
            }
        }
        finally
        {
            _downloadLock.Release();
        }
    }

    private void Publish(bool isDownloading, double? progress, string statusText)
    {
        CurrentState = new SenseVoiceDownloadState(isDownloading, progress, statusText, IsModelAvailable);
        StateChanged?.Invoke(CurrentState);
    }

    private async Task DownloadArchiveAsync(Uri uri, string archivePath, CancellationToken cancellationToken)
    {
        using var response = await HttpClient.GetAsync(uri, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        response.EnsureSuccessStatusCode();

        var totalBytes = response.Content.Headers.ContentLength;
        await using var input = await response.Content.ReadAsStreamAsync(cancellationToken);
        await using var output = File.Create(archivePath);

        var buffer = new byte[1024 * 1024];
        long readBytes = 0;
        int read;
        while ((read = await input.ReadAsync(buffer, cancellationToken)) > 0)
        {
            await output.WriteAsync(buffer.AsMemory(0, read), cancellationToken);
            readBytes += read;
            if (totalBytes is > 0)
            {
                Publish(true, Math.Clamp(readBytes / (double)totalBytes.Value, 0, 1), L10n.Tr(
                    $"正在下载 SenseVoice 模型… {readBytes / 1024 / 1024} / {totalBytes.Value / 1024 / 1024} MB",
                    $"Downloading SenseVoice model... {readBytes / 1024 / 1024} / {totalBytes.Value / 1024 / 1024} MB"));
            }
        }

        if (totalBytes.HasValue && readBytes != totalBytes.Value)
        {
            throw new IOException(string.Format(
                CultureInfo.InvariantCulture,
                "Downloaded {0} bytes, expected {1}.",
                readBytes,
                totalBytes.Value));
        }
    }

    private static void ExtractArchive(string archivePath, string destinationDir)
    {
        using var archiveStream = File.OpenRead(archivePath);
        using var reader = ReaderFactory.Open(archiveStream);
        var destinationRoot = Path.GetFullPath(destinationDir)
            .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) +
            Path.DirectorySeparatorChar;

        while (reader.MoveToNextEntry())
        {
            if (reader.Entry.IsDirectory) continue;

            var relativePath = (reader.Entry.Key ?? "").Replace('/', Path.DirectorySeparatorChar);
            if (string.IsNullOrWhiteSpace(relativePath)) continue;

            var destinationPath = Path.GetFullPath(Path.Combine(destinationRoot, relativePath));
            if (!destinationPath.StartsWith(destinationRoot, StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidDataException("Archive entry escapes the model directory.");
            }

            var parent = Path.GetDirectoryName(destinationPath);
            if (!string.IsNullOrEmpty(parent)) Directory.CreateDirectory(parent);
            reader.WriteEntryToFile(destinationPath, new ExtractionOptions
            {
                Overwrite = true,
                PreserveFileTime = true
            });
        }
    }

    private static void ReplaceModelDirectory(string stagingDir, string modelDirectory)
    {
        TryDeleteDirectory(modelDirectory);
        Directory.Move(stagingDir, modelDirectory);
    }

    private static void TryDeleteFile(string path)
    {
        try
        {
            if (File.Exists(path)) File.Delete(path);
        }
        catch (Exception ex)
        {
            Log.Error(ex, "Failed to delete temporary file: " + path);
        }
    }

    private static void TryDeleteDirectory(string path)
    {
        try
        {
            if (Directory.Exists(path)) Directory.Delete(path, recursive: true);
        }
        catch (Exception ex)
        {
            Log.Error(ex, "Failed to delete temporary directory: " + path);
        }
    }
}
