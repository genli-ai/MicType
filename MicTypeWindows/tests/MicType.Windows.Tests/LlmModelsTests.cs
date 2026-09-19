using MicType.Win.Core;

namespace MicType.Windows.Tests;

/// 与 Mac 端 LLMCatalogTests.swift 的迁移 / temperature 用例同源
public sealed class LlmModelsTests
{
    private static LlmModels.ModelSet Set(
        string openAiPolish = "", string openAiCommand = "",
        string deepSeekPolish = "", string deepSeekCommand = "")
        => new(openAiPolish, openAiCommand, deepSeekPolish, deepSeekCommand);

    /// 已下线的 DeepSeek 型号无论怎么来的都要改名——留着就是每次调用 404
    [Fact]
    public void MigrationRenamesDeadDeepSeekModels()
    {
        var migrated = LlmModels.MigrateTo56(Set(
            deepSeekPolish: "deepseek-v4-flash", deepSeekCommand: "deepseek-reasoner"));
        Assert.Equal(LlmModels.DeepSeekPolishDefault, migrated.DeepSeekPolish);
        Assert.Equal(LlmModels.DeepSeekCommandDefault, migrated.DeepSeekCommand);
    }

    /// 空 / 空白 = 没存过，给新默认
    [Fact]
    public void MigrationFillsEmptyValuesWithDefaults()
    {
        var migrated = LlmModels.MigrateTo56(Set("  ", "", "", "  "));
        Assert.Equal(LlmModels.OpenAiPolishDefault, migrated.OpenAiPolish);
        Assert.Equal(LlmModels.OpenAiCommandDefault, migrated.OpenAiCommand);
        Assert.Equal(LlmModels.DeepSeekPolishDefault, migrated.DeepSeekPolish);
        Assert.Equal(LlmModels.DeepSeekCommandDefault, migrated.DeepSeekCommand);
    }

    /// 历史自动默认（各版自己写进去的）才搬
    [Fact]
    public void MigrationMovesHistoricalAutoDefaults()
    {
        var migrated = LlmModels.MigrateTo56(Set("gpt-5.5", "gpt-5.4-mini"));
        Assert.Equal(LlmModels.OpenAiPolishDefault, migrated.OpenAiPolish);
        Assert.Equal(LlmModels.OpenAiCommandDefault, migrated.OpenAiCommand);
    }

    /// 铁律：用户手选过的型号一个都不动
    [Fact]
    public void MigrationKeepsUserChosenModels()
    {
        var migrated = LlmModels.MigrateTo56(Set("gpt-5.4", "gpt-4.1", "deepseek-v4-pro", "deepseek-flash"));
        Assert.Equal("gpt-5.4", migrated.OpenAiPolish);
        Assert.Equal("gpt-4.1", migrated.OpenAiCommand);
        Assert.Equal("deepseek-v4-pro", migrated.DeepSeekPolish);
        Assert.Equal("deepseek-flash", migrated.DeepSeekCommand);
    }

    /// 只跑一次：迁移之后用户手填回 gpt-5.5，下次启动不许再被改掉
    [Fact]
    public void ApplyMigrationRunsOnlyOnce()
    {
        var settings = new AppSettings { OpenAiPolishModel = "gpt-5.5" };
        Assert.True(LlmModels.ApplyMigration(settings));
        Assert.Equal(LlmModels.OpenAiPolishDefault, settings.OpenAiPolishModel);
        Assert.True(settings.ModelsMigratedTo56);

        settings.OpenAiPolishModel = "gpt-5.5";
        Assert.False(LlmModels.ApplyMigration(settings));
        Assert.Equal("gpt-5.5", settings.OpenAiPolishModel);
    }

    /// 出厂默认已经是 v4.0 的型号，迁移不该把它们再动一遍
    [Fact]
    public void FactoryDefaultsAreTheV4Models()
    {
        var settings = new AppSettings();
        Assert.Equal(LlmModels.OpenAiPolishDefault, settings.OpenAiPolishModel);
        Assert.Equal(LlmModels.OpenAiCommandDefault, settings.OpenAiCommandModel);
        Assert.Equal(LlmModels.DeepSeekPolishDefault, settings.DeepSeekPolishModel);
        Assert.Equal(LlmModels.DeepSeekCommandDefault, settings.DeepSeekCommandModel);
    }

    /// 推理系型号不发 temperature：5.5 / 5.6 线 / gpt-6 线 / *-pro / o 系
    [Theory]
    [InlineData("gpt-5.5")]
    [InlineData("gpt-5.6-luna")]
    [InlineData("gpt-5.6-terra")]
    [InlineData("gpt-6-astra")]
    [InlineData("deepseek-v4-pro")]
    [InlineData("o3-mini")]
    [InlineData("O4-MINI")]
    public void ReasoningModelsRejectCustomTemperature(string model)
    {
        Assert.True(LlmModels.RejectsCustomTemperature(model));
    }

    /// 普通型号照常发 temperature（发了才有档位可调）
    [Theory]
    [InlineData("gpt-5.4-mini")]
    [InlineData("gpt-4o-mini")]
    [InlineData("deepseek-flash")]
    [InlineData("qwen-plus")]
    [InlineData("")]
    public void RegularModelsAcceptCustomTemperature(string model)
    {
        Assert.False(LlmModels.RejectsCustomTemperature(model));
    }
}
