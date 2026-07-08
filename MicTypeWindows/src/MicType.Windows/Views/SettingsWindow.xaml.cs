using System.IO;
using System.Windows;
using System.Windows.Controls;
using MicType.Win.Core;
using MicType.Win.Services;
using WinForms = System.Windows.Forms;

namespace MicType.Win.Views;

public partial class SettingsWindow : Window
{
    private readonly SenseVoiceModelDownloader _modelDownloader = SenseVoiceModelDownloader.Shared;
    private AppSettings Settings => SettingsStore.Instance.Current;

    public SettingsWindow()
    {
        InitializeComponent();
        LoadSettingsIntoUi();
        ApplyTexts();
        _modelDownloader.StateChanged += OnModelDownloadStateChanged;
        ApplyModelState(_modelDownloader.CurrentState);
        L10n.LanguageChanged += ApplyTexts;
    }

    protected override void OnClosed(EventArgs e)
    {
        L10n.LanguageChanged -= ApplyTexts;
        _modelDownloader.StateChanged -= OnModelDownloadStateChanged;
        base.OnClosed(e);
    }

    private void LoadSettingsIntoUi()
    {
        SelectByTag(LanguageBox, Settings.AppLanguage.ToString());
        SelectByTag(HotkeyBox, Settings.Hotkey.ToString());
        PlaySoundsBox.IsChecked = Settings.PlaySounds;
        RestoreClipboardBox.IsChecked = Settings.RestoreClipboard;
        VocabularyBox.Text = Settings.CustomVocabulary;
        SelectByTag(PolishLevelBox, Settings.PolishLevel.ToString());
        SelectByTag(ProviderBox, Settings.LlmProvider.ToString());
        PolishTempSlider.Value = Settings.PolishTemperature;
        CommandTempSlider.Value = Settings.CommandTemperature;
        AboutMeBox.Text = Settings.AboutMe;
        RulesBox.Text = Settings.CustomPolishRules;
        LoadProviderFields();
    }

    private void ApplyTexts()
    {
        Title = L10n.Tr("MicType 设置", "MicType Settings");
        GeneralTab.Header = L10n.Tr("通用", "General");
        RecognitionTab.Header = L10n.Tr("识别", "Recognition");
        AiTab.Header = L10n.Tr("AI 润色", "AI Polish");
        AboutTab.Header = L10n.Tr("关于", "About");
        LanguageLabel.Text = L10n.Tr("界面语言 / Language", "Language / 界面语言");
        HotkeyLabel.Text = L10n.Tr("听写快捷键", "Dictation hotkey");
        SetComboContent(HotkeyBox, "RightControl", L10n.Tr("右 Ctrl", "Right Ctrl"));
        SetComboContent(HotkeyBox, "RightShift", L10n.Tr("右 Shift", "Right Shift"));
        PlaySoundsBox.Content = L10n.Tr("开始 / 完成时播放提示音", "Play sounds on start / finish");
        RestoreClipboardBox.Content = L10n.Tr("输入后恢复原剪贴板内容", "Restore clipboard after inserting");
        GestureHelp.Text = L10n.Tr(
            "轻点：开始 / 结束听写 · 按住说话、松手：执行语音指令 · 录音中按 Esc 取消。",
            "Tap: start / stop dictation · Hold to speak a command, release to run · Esc cancels.");
        AsrStatusLabel.Text = L10n.Tr("本地识别引擎", "Local speech engine");
        DownloadModelButton.Content = L10n.Tr("下载模型", "Download model");
        RedownloadModelButton.Content = L10n.Tr("重新下载", "Re-download");
        CancelModelDownloadButton.Content = L10n.Tr("取消", "Cancel");
        VocabularyLabel.Text = L10n.Tr("专有词汇表（逗号或换行分隔）", "Custom vocabulary (comma or newline separated)");
        VocabularyHelp.Text = L10n.Tr(
            "普通词条提升识别命中率；「杰文=捷文」格式则把左边强制替换为右边——适合同音人名等热词救不了的情况。",
            "Plain entries bias recognition; \"wrong=right\" force-replaces the left side with the right — for exact homophones that hotwords can't fix.");
        PolishModeLabel.Text = L10n.Tr("润色档位", "Polish mode");
        SetComboContent(PolishLevelBox, "Off", L10n.Tr("仅识别", "Transcribe only"));
        SetComboContent(PolishLevelBox, "Smart", L10n.Tr("AI 润色", "AI polish"));
        ProviderLabel.Text = L10n.Tr("当前使用", "Active provider");
        PolishModelLabel.Text = L10n.Tr("润色模型（求快）", "Polish model (fast)");
        CommandModelLabel.Text = L10n.Tr("指令模型（求好）", "Command model (strong)");
        SaveKeyButton.Content = L10n.Tr("保存 Key", "Save Key");
        TestPolishButton.Content = L10n.Tr("测试润色模型", "Test polish");
        TestCommandButton.Content = L10n.Tr("测试指令模型", "Test command");
        TemperatureLabel.Text = L10n.Tr("温度", "Temperature");
        PolishTempLabel.Text = L10n.Tr("润色温度", "Polish temp");
        CommandTempLabel.Text = L10n.Tr("指令温度", "Command temp");
        AboutMeLabel.Text = L10n.Tr("关于我（可选）", "About me (optional)");
        RulesLabel.Text = L10n.Tr("自定义规则（可选）", "Custom rules (optional)");
        AboutText.Text = L10n.Tr(
            "Windows 版目标：右 Ctrl 轻点语音输入，长按说指令；录音和本地识别不上传；文本可按你的 GPT / DeepSeek API 润色或执行指令。\n\n当前版本使用 sherpa-onnx + SenseVoice 本地识别。",
            "Windows goal: tap Right Ctrl to dictate, hold it to command AI. Audio and local recognition stay on device; text can be polished or executed through your GPT / DeepSeek API.\n\nThis build uses local sherpa-onnx + SenseVoice recognition.");
        SaveButton.Content = L10n.Tr("保存设置", "Save Settings");
        VersionText.Text = L10n.Tr("版本 ", "Version ") + UpdateChecker.CurrentVersion + " · sherpa-onnx SenseVoice";
        BuildAuthorLine();
        CheckUpdateButton.Content = L10n.Tr("检查更新", "Check for Updates");
        ReleasesButton.Content = L10n.Tr("发布页", "Releases");
        ApplyModelState(_modelDownloader.CurrentState);
    }

    private void OnLanguageChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!IsLoaded) return;
        if (LanguageBox.SelectedItem is ComboBoxItem item &&
            Enum.TryParse<AppLanguage>((string)item.Tag, out var lang))
        {
            L10n.Language = lang;
            TestResultText.Text = "";
        }
    }

    private void OnProviderChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!IsLoaded) return;
        SaveUiIntoSettings();
        LoadProviderFields();
        TestResultText.Text = "";
    }

    private async void OnCheckUpdate(object sender, RoutedEventArgs e)
    {
        CheckUpdateButton.IsEnabled = false;
        UpdateStatusText.Text = L10n.Tr("正在检查 GitHub 上的最新版本…", "Checking the latest release on GitHub…");
        try
        {
            var result = await UpdateChecker.CheckAndDownloadAsync();
            UpdateStatusText.Text = result.Outcome switch
            {
                UpdateChecker.CheckOutcome.UpToDate =>
                    L10n.Tr($"已是最新版本（{result.Version}）", $"You're up to date ({result.Version})"),
                UpdateChecker.CheckOutcome.Downloaded =>
                    L10n.Tr($"新版本 {result.Version} 已下载到「下载」文件夹（已在资源管理器中选中）——退出 MicType，解压并替换 MicType.exe，重新打开即完成升级",
                            $"Version {result.Version} downloaded to your Downloads folder (revealed in Explorer) — quit MicType, unzip and replace MicType.exe, then relaunch"),
                UpdateChecker.CheckOutcome.NoWindowsAsset =>
                    L10n.Tr($"最新发布（{result.Version}）暂无 Windows 包，当前版本即最新", $"Latest release ({result.Version}) has no Windows package yet — you're current"),
                _ =>
                    L10n.Tr($"检查失败：{result.Error}。可点「发布页」手动下载", $"Check failed: {result.Error}. Use the Releases button to download manually")
            };
        }
        finally
        {
            CheckUpdateButton.IsEnabled = true;
        }
    }

    private void BuildAuthorLine()
    {
        AuthorText.Inlines.Clear();
        AuthorText.Inlines.Add(new System.Windows.Documents.Run(L10n.Tr("作者：Gen · ", "Built by Gen · ")));
        AuthorText.Inlines.Add(MakeLink("genli-ai.github.io/portfolio", "https://genli-ai.github.io/portfolio/"));
        AuthorText.Inlines.Add(new System.Windows.Documents.Run(" · "));
        AuthorText.Inlines.Add(MakeLink("ligen.thu@gmail.com", "mailto:ligen.thu@gmail.com"));
    }

    private static System.Windows.Documents.Hyperlink MakeLink(string text, string uri)
    {
        var link = new System.Windows.Documents.Hyperlink(new System.Windows.Documents.Run(text))
        {
            NavigateUri = new Uri(uri)
        };
        link.RequestNavigate += (_, e) =>
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(e.Uri.ToString()) { UseShellExecute = true });
        return link;
    }

    private void OnOpenReleases(object sender, RoutedEventArgs e)
    {
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(UpdateChecker.ReleasesPage) { UseShellExecute = true });
    }

    private void OnSaveSettings(object sender, RoutedEventArgs e)
    {
        try
        {
            SaveUiIntoSettings();
            SettingsStore.Instance.Save();
            SaveStatusText.Text = L10n.Tr("已保存 ✓", "Saved ✓");
        }
        catch (Exception ex)
        {
            Log.Error(ex, "Save settings failed");
            SaveStatusText.Text = L10n.Tr("保存失败：", "Save failed: ") + ex.Message;
        }
    }

    private void OnSaveKey(object sender, RoutedEventArgs e)
    {
        try
        {
            SaveUiIntoSettings();
            if (string.IsNullOrWhiteSpace(ApiKeyBox.Password))
            {
                TestResultText.Text = L10n.Tr("Key 框为空——已存的 Key 未改动", "Key box is empty — stored key unchanged");
                return;
            }
            CredentialStore.Save(Settings.CurrentCredentialTarget, ApiKeyBox.Password);
            TestResultText.Text = CredentialStore.Load(Settings.CurrentCredentialTarget) is null
                ? L10n.Tr("保存后读取失败——请把日志发给开发者", "Saved but read-back failed — please send the logs")
                : L10n.Tr("已保存 Key ✓", "Key saved ✓");
        }
        catch (Exception ex)
        {
            Log.Error(ex, "Save key failed");
            TestResultText.Text = L10n.Tr("保存 Key 失败：", "Key save failed: ") + ex.Message;
        }
    }

    private async void OnTestPolishModel(object sender, RoutedEventArgs e)
    {
        await TestModelAsync(PolishModelBox.Text);
    }

    private async void OnTestCommandModel(object sender, RoutedEventArgs e)
    {
        await TestModelAsync(CommandModelBox.Text);
    }

    private async Task TestModelAsync(string model)
    {
        SaveUiIntoSettings();
        try
        {
            CredentialStore.Save(Settings.CurrentCredentialTarget, ApiKeyBox.Password);
        }
        catch (Exception ex)
        {
            Log.Error(ex, "Save key before model test failed");
        }
        TestResultText.Text = L10n.Tr("测试中…", "Testing…");
        var result = await LlmClient.TestModelAsync(model);
        TestResultText.Text = result.Message;
    }

    private async void OnDownloadModel(object sender, RoutedEventArgs e)
    {
        var directory = PromptModelDirectory();
        if (directory is null) return;
        _modelDownloader.SetModelDirectory(directory);
        Settings.SpeechModelDirectory = directory;
        SettingsStore.Instance.Save();
        await DownloadModelAsync(force: false);
    }

    private async void OnRedownloadModel(object sender, RoutedEventArgs e)
    {
        _modelDownloader.DeleteModelFiles();
        var directory = PromptModelDirectory();
        if (directory is null) return;
        _modelDownloader.SetModelDirectory(directory);
        Settings.SpeechModelDirectory = directory;
        SettingsStore.Instance.Save();
        await DownloadModelAsync(force: true);
    }

    private string? PromptModelDirectory()
    {
        using var dialog = new WinForms.FolderBrowserDialog
        {
            Description = L10n.Tr("请选择模型下载目录", "Select model download folder"),
            UseDescriptionForTitle = true,
            InitialDirectory = GetInitialBrowseDirectory()
        };

        var result = dialog.ShowDialog();
        if (result != WinForms.DialogResult.OK || string.IsNullOrWhiteSpace(dialog.SelectedPath))
            return null;
        return dialog.SelectedPath;
    }

    private string GetInitialBrowseDirectory()
    {
        var current = _modelDownloader.ModelDirectory;
        if (Directory.Exists(current)) return current;
        var parent = Path.GetDirectoryName(current);
        if (parent is not null && Directory.Exists(parent)) return parent;
        return Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
    }

    private void OnCancelModelDownload(object sender, RoutedEventArgs e)
    {
        _modelDownloader.CancelDownload();
    }

    private async Task DownloadModelAsync(bool force)
    {
        try
        {
            await _modelDownloader.DownloadAsync(force);
        }
        catch (OperationCanceledException ex)
        {
            Log.Error(ex, "Model download cancelled from settings");
        }
        catch (MTException ex)
        {
            Log.Error(ex, "Model download failed from settings");
            AsrStatusText.Text = ex.UserMessage;
        }
    }

    private void OnModelDownloadStateChanged(SenseVoiceDownloadState state)
    {
        Dispatcher.Invoke(() => ApplyModelState(state));
    }

    private void ApplyModelState(SenseVoiceDownloadState state)
    {
        AsrStatusText.Text = state.StatusText;
        ModelDirectoryText.Text = L10n.Tr("模型目录：", "Model folder: ") + _modelDownloader.ModelDirectory;

        ModelDownloadProgress.Visibility = state.IsDownloading ? Visibility.Visible : Visibility.Collapsed;
        ModelDownloadProgress.IsIndeterminate = state.IsDownloading && state.Progress is null;
        ModelDownloadProgress.Value = state.Progress.HasValue ? state.Progress.Value * 100 : 0;

        DownloadModelButton.IsEnabled = !state.IsDownloading && !state.IsAvailable;
        RedownloadModelButton.IsEnabled = !state.IsDownloading;
        CancelModelDownloadButton.Visibility = state.IsDownloading ? Visibility.Visible : Visibility.Collapsed;
    }

    private void SaveUiIntoSettings()
    {
        if (LanguageBox.SelectedItem is ComboBoxItem langItem &&
            Enum.TryParse<AppLanguage>((string)langItem.Tag, out var lang))
        {
            Settings.AppLanguage = lang;
        }
        if (HotkeyBox.SelectedItem is ComboBoxItem hotkeyItem &&
            Enum.TryParse<HotkeyChoice>((string)hotkeyItem.Tag, out var hotkey))
        {
            Settings.Hotkey = hotkey;
        }
        if (PolishLevelBox.SelectedItem is ComboBoxItem polishItem &&
            Enum.TryParse<PolishLevel>((string)polishItem.Tag, out var polish))
        {
            Settings.PolishLevel = polish;
        }
        if (ProviderBox.SelectedItem is ComboBoxItem providerItem &&
            Enum.TryParse<LlmProvider>((string)providerItem.Tag, out var provider))
        {
            Settings.LlmProvider = provider;
        }

        Settings.PlaySounds = PlaySoundsBox.IsChecked == true;
        Settings.RestoreClipboard = RestoreClipboardBox.IsChecked == true;
        Settings.CustomVocabulary = VocabularyBox.Text;
        Settings.PolishTemperature = PolishTempSlider.Value;
        Settings.CommandTemperature = CommandTempSlider.Value;
        Settings.AboutMe = AboutMeBox.Text;
        Settings.CustomPolishRules = RulesBox.Text;

        if (Settings.LlmProvider == LlmProvider.OpenAi)
        {
            Settings.OpenAiBaseUrl = BaseUrlBox.Text;
            Settings.OpenAiPolishModel = PolishModelBox.Text;
            Settings.OpenAiCommandModel = CommandModelBox.Text;
        }
        else
        {
            Settings.DeepSeekBaseUrl = BaseUrlBox.Text;
            Settings.DeepSeekPolishModel = PolishModelBox.Text;
            Settings.DeepSeekCommandModel = CommandModelBox.Text;
        }
    }

    private void LoadProviderFields()
    {
        BaseUrlBox.Text = Settings.CurrentBaseUrl;
        PolishModelBox.Text = Settings.CurrentPolishModel;
        CommandModelBox.Text = Settings.CurrentCommandModel;
        ApiKeyBox.Password = CredentialStore.Load(Settings.CurrentCredentialTarget) ?? "";
    }

    private static void SelectByTag(ComboBox comboBox, string tag)
    {
        foreach (var item in comboBox.Items.OfType<ComboBoxItem>())
        {
            if ((string)item.Tag == tag)
            {
                comboBox.SelectedItem = item;
                return;
            }
        }
        comboBox.SelectedIndex = 0;
    }

    private static void SetComboContent(ComboBox comboBox, string tag, string content)
    {
        foreach (var item in comboBox.Items.OfType<ComboBoxItem>())
        {
            if ((string)item.Tag == tag)
            {
                item.Content = content;
                return;
            }
        }
    }
}
