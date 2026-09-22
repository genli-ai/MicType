using MicType.Win.Core;

namespace MicType.Windows.Tests;

/// 4.3.2 回归：切服务商时「上一家的字段被写进下一家」。
/// 这个 bug 的后果不是显示错乱，而是 OpenAI 的地址 / 型号被换成 DeepSeek 的（反向同理），
/// 于是一家的 Key 被发去另一家的服务器——所以下面每一条都要钉死。
public sealed class AppSettingsProviderFieldsTests
{
    /// 写 OpenAI 的槽位不许碰 DeepSeek 的三个字段，也不许动 LlmProvider
    [Fact]
    public void SetProviderFieldsWritesOnlyOpenAiSlots()
    {
        var settings = new AppSettings { LlmProvider = LlmProvider.DeepSeek };

        settings.SetProviderFields(LlmProvider.OpenAi, "https://proxy.example.com/v1", "polish-x", "command-x");

        Assert.Equal("https://proxy.example.com/v1", settings.OpenAiBaseUrl);
        Assert.Equal("polish-x", settings.OpenAiPolishModel);
        Assert.Equal("command-x", settings.OpenAiCommandModel);
        Assert.Equal(AppSettings.DefaultDeepSeekBaseUrl, settings.DeepSeekBaseUrl);
        Assert.Equal(LlmModels.DeepSeekPolishDefault, settings.DeepSeekPolishModel);
        Assert.Equal(LlmModels.DeepSeekCommandDefault, settings.DeepSeekCommandModel);
        Assert.Equal(LlmProvider.DeepSeek, settings.LlmProvider);
    }

    /// 反向同理：写 DeepSeek 的槽位不许碰 OpenAI 的三个字段
    [Fact]
    public void SetProviderFieldsWritesOnlyDeepSeekSlots()
    {
        var settings = new AppSettings { LlmProvider = LlmProvider.OpenAi };

        settings.SetProviderFields(LlmProvider.DeepSeek, "https://ds.example.com", "polish-y", "command-y");

        Assert.Equal("https://ds.example.com", settings.DeepSeekBaseUrl);
        Assert.Equal("polish-y", settings.DeepSeekPolishModel);
        Assert.Equal("command-y", settings.DeepSeekCommandModel);
        Assert.Equal(AppSettings.DefaultOpenAiBaseUrl, settings.OpenAiBaseUrl);
        Assert.Equal(LlmModels.OpenAiPolishDefault, settings.OpenAiPolishModel);
        Assert.Equal(LlmModels.OpenAiCommandDefault, settings.OpenAiCommandModel);
        Assert.Equal(LlmProvider.OpenAi, settings.LlmProvider);
    }

    /// 复现老 bug 的那一刻：LlmProvider 已经切到 OpenAI，界面四个框里还装着 DeepSeek 的值。
    /// 正确行为 = 按「框里装的那一家」回写，OpenAI 的三个槽位保持原样。
    [Fact]
    public void StaleUiFieldsNeverLeakIntoTheNewlySelectedProvider()
    {
        var settings = new AppSettings { LlmProvider = LlmProvider.OpenAi };

        settings.SetProviderFields(
            LlmProvider.DeepSeek, AppSettings.DefaultDeepSeekBaseUrl, "deepseek-flash", "deepseek-v4-pro");

        Assert.Equal(AppSettings.DefaultOpenAiBaseUrl, settings.OpenAiBaseUrl);
        Assert.Equal(LlmModels.OpenAiPolishDefault, settings.OpenAiPolishModel);
        Assert.Equal(LlmModels.OpenAiCommandDefault, settings.OpenAiCommandModel);
        Assert.Equal(AppSettings.DefaultDeepSeekBaseUrl, settings.DeepSeekBaseUrl);
        Assert.Equal("deepseek-flash", settings.DeepSeekPolishModel);
    }

    /// Key 槽位按服务商分开，两家绝不能共用一把
    [Fact]
    public void CredentialTargetsAreDistinctPerProvider()
    {
        Assert.Equal(CredentialTargets.OpenAiApiKey, CredentialTargets.For(LlmProvider.OpenAi));
        Assert.Equal(CredentialTargets.DeepSeekApiKey, CredentialTargets.For(LlmProvider.DeepSeek));
        Assert.NotEqual(CredentialTargets.For(LlmProvider.OpenAi), CredentialTargets.For(LlmProvider.DeepSeek));

        var settings = new AppSettings { LlmProvider = LlmProvider.DeepSeek };
        Assert.Equal(CredentialTargets.For(LlmProvider.DeepSeek), settings.CurrentCredentialTarget);
    }

    /// 已经被写坏的老设置：启动时自愈回官方默认，且跑第二遍没有可改的（幂等）
    [Fact]
    public void RepairResetsCrossProviderContamination()
    {
        var settings = new AppSettings
        {
            OpenAiBaseUrl = AppSettings.DefaultDeepSeekBaseUrl,
            OpenAiPolishModel = "deepseek-flash",
            OpenAiCommandModel = "deepseek-v4-pro",
            DeepSeekBaseUrl = AppSettings.DefaultOpenAiBaseUrl,
            DeepSeekPolishModel = "gpt-5.6-luna",
            DeepSeekCommandModel = "gpt-5.6-terra"
        };

        Assert.True(settings.RepairCrossProviderFields(out var repaired));
        Assert.Equal(6, repaired.Count);
        Assert.Equal(AppSettings.DefaultOpenAiBaseUrl, settings.OpenAiBaseUrl);
        Assert.Equal(LlmModels.OpenAiPolishDefault, settings.OpenAiPolishModel);
        Assert.Equal(LlmModels.OpenAiCommandDefault, settings.OpenAiCommandModel);
        Assert.Equal(AppSettings.DefaultDeepSeekBaseUrl, settings.DeepSeekBaseUrl);
        Assert.Equal(LlmModels.DeepSeekPolishDefault, settings.DeepSeekPolishModel);
        Assert.Equal(LlmModels.DeepSeekCommandDefault, settings.DeepSeekCommandModel);

        Assert.False(settings.RepairCrossProviderFields());
    }

    /// 干净的设置一个字段都不许动
    [Fact]
    public void RepairLeavesCleanSettingsAlone()
    {
        var settings = new AppSettings
        {
            OpenAiPolishModel = "gpt-5.4",
            DeepSeekCommandModel = "deepseek-v4-pro"
        };

        Assert.False(settings.RepairCrossProviderFields());
        Assert.Equal(AppSettings.DefaultOpenAiBaseUrl, settings.OpenAiBaseUrl);
        Assert.Equal(AppSettings.DefaultDeepSeekBaseUrl, settings.DeepSeekBaseUrl);
        Assert.Equal("gpt-5.4", settings.OpenAiPolishModel);
        Assert.Equal("deepseek-v4-pro", settings.DeepSeekCommandModel);
    }

    /// 自定义代理 / 解析不出主机名 / 空串：不认识 ≠ 串槽，一律不动，也不许抛异常
    [Theory]
    [InlineData("https://my-proxy.example.com/v1")]
    [InlineData("https://openai-proxy.internal:8443/v1")]
    [InlineData("https://notdeepseek.com/v1")]
    [InlineData("api.deepseek.com")]
    [InlineData("not a url")]
    [InlineData("")]
    public void RepairKeepsCustomOrUnparsableBaseUrls(string url)
    {
        var settings = new AppSettings { OpenAiBaseUrl = url, DeepSeekBaseUrl = url };

        Assert.False(settings.RepairCrossProviderFields());
        Assert.Equal(url, settings.OpenAiBaseUrl);
        Assert.Equal(url, settings.DeepSeekBaseUrl);
    }

    /// 主机名匹配到子域为止：api.deepseek.com / 裸 deepseek.com 都算串槽
    [Theory]
    [InlineData("https://api.deepseek.com")]
    [InlineData("https://deepseek.com/v1")]
    [InlineData("HTTPS://API.DEEPSEEK.COM/v1")]
    public void RepairDetectsDeepSeekHostsInTheOpenAiSlot(string url)
    {
        var settings = new AppSettings { OpenAiBaseUrl = url };

        Assert.True(settings.RepairCrossProviderFields(out var repaired));
        Assert.Equal(1, repaired.Count);
        Assert.Equal(nameof(AppSettings.OpenAiBaseUrl), repaired[0]);
        Assert.Equal(AppSettings.DefaultOpenAiBaseUrl, settings.OpenAiBaseUrl);
    }

    /// DeepSeek 侧只认 gpt- 前缀：别的型号名（用户自己填的第三方兼容型号）不猜、不动
    [Theory]
    [InlineData("deepseek-flash", false)]
    [InlineData("qwen-plus", false)]
    [InlineData("o3-mini", false)]
    [InlineData("gpt-5.6-luna", true)]
    [InlineData("GPT-4O-MINI", true)]
    public void RepairOnlyResetsGptPrefixedDeepSeekModels(string model, bool expectRepair)
    {
        var settings = new AppSettings { DeepSeekPolishModel = model };

        Assert.Equal(expectRepair, settings.RepairCrossProviderFields());
        Assert.Equal(expectRepair ? LlmModels.DeepSeekPolishDefault : model, settings.DeepSeekPolishModel);
    }
}
