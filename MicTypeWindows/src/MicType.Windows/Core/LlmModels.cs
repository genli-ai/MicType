namespace MicType.Win.Core;

/// LLM 型号目录：出厂默认、已下线型号的改名表、以及「这个型号收不收自定义 temperature」。
/// 与 Mac 端 LLMCatalog.swift 同源（openaiPolishDefault… / deadDeepSeekModels / rejectsCustomTemperature），
/// 一端改了另一端必须跟着改——Windows 不跟版的代价是用户停在已经 404 的型号上，
/// 而错误话术只会说「模型名不存在」，他根本不会怀疑到出厂默认值头上。
public static class LlmModels
{
    public const string OpenAiPolishDefault = "gpt-5.6-luna";
    public const string OpenAiCommandDefault = "gpt-5.6-terra";
    public const string DeepSeekPolishDefault = "deepseek-flash";
    public const string DeepSeekCommandDefault = "deepseek-v4-pro";

    /// 仍停在「历史自动默认」上的润色型号。这些值不是用户挑的，是各版 MicType 自己写进去的：
    /// gpt-4o-mini（更早的默认）/ gpt-5.4-nano / gpt-5.5（上一版的出厂默认）。
    private static readonly string[] AutoPolishModels = ["gpt-4o-mini", "gpt-5.4-nano", "gpt-5.5"];

    /// 同理，指令型号的历史自动默认只有 gpt-5.4-mini。
    private static readonly string[] AutoCommandModels = ["gpt-5.4-mini"];

    /// DeepSeek 这几个型号**已经不存在了**（调用直接 404/400），所以无论是不是用户手选的都得改名。
    private static readonly Dictionary<string, string> DeadDeepSeekModels =
        new(StringComparer.OrdinalIgnoreCase)
        {
            ["deepseek-v4-flash"] = DeepSeekPolishDefault,
            ["deepseek-chat"] = DeepSeekPolishDefault,
            ["deepseek-reasoner"] = DeepSeekCommandDefault,
        };

    /// 一次迁移要动的四个型号。用 record 是为了让 <see cref="MigrateTo56"/> 保持纯函数、可单测。
    public sealed record ModelSet(
        string OpenAiPolish,
        string OpenAiCommand,
        string DeepSeekPolish,
        string DeepSeekCommand);

    /// v4.0 迁移规则（**纯函数**，单测钉死「手选过的一个都不动」这条铁律）。
    /// 空 / 空白视为「没存过」，一律给新默认值。
    public static ModelSet MigrateTo56(ModelSet current)
    {
        return new ModelSet(
            MigrateAuto(current.OpenAiPolish, AutoPolishModels, OpenAiPolishDefault),
            MigrateAuto(current.OpenAiCommand, AutoCommandModels, OpenAiCommandDefault),
            MigrateDeepSeek(current.DeepSeekPolish, DeepSeekPolishDefault),
            MigrateDeepSeek(current.DeepSeekCommand, DeepSeekCommandDefault));
    }

    /// OpenAI 侧：只搬还停在自动默认上的用户。手选过 gpt-5.4 之类的人是自己做的决定，
    /// 替他改掉就是「替用户做主」——铁律不许。
    private static string MigrateAuto(string? stored, string[] autoDefaults, string fallback)
    {
        var value = Normalize(stored);
        if (value is null) return fallback;
        return autoDefaults.Contains(value, StringComparer.OrdinalIgnoreCase) ? fallback : value;
    }

    /// DeepSeek 侧：没存过 → 新默认；存着已下线的型号 → 按等价关系改名（不改就是每次调用都失败）。
    private static string MigrateDeepSeek(string? stored, string fallback)
    {
        var value = Normalize(stored);
        if (value is null) return fallback;
        return DeadDeepSeekModels.TryGetValue(value, out var renamed) ? renamed : value;
    }

    private static string? Normalize(string? value)
    {
        var trimmed = value?.Trim();
        return string.IsNullOrEmpty(trimmed) ? null : trimmed;
    }

    /// 把迁移结果写回设置。只跑一次（靠 <see cref="AppSettings.ModelsMigratedTo56"/> 记账）：
    /// 跑第二遍的话，用户迁移之后**手动**填回 gpt-5.5 会被每次启动改掉，那才是真的替用户做主。
    /// 返回 true = 需要保存（含只写标记的情况，标记不落盘就等于没迁移过）。
    public static bool ApplyMigration(AppSettings settings)
    {
        if (settings.ModelsMigratedTo56) return false;

        var migrated = MigrateTo56(new ModelSet(
            settings.OpenAiPolishModel,
            settings.OpenAiCommandModel,
            settings.DeepSeekPolishModel,
            settings.DeepSeekCommandModel));

        settings.OpenAiPolishModel = migrated.OpenAiPolish;
        settings.OpenAiCommandModel = migrated.OpenAiCommand;
        settings.DeepSeekPolishModel = migrated.DeepSeekPolish;
        settings.DeepSeekCommandModel = migrated.DeepSeekCommand;
        settings.ModelsMigratedTo56 = true;
        return true;
    }

    /// 推理系模型只接受默认 temperature，发了自定义值直接 400
    /// （gpt-5.5 / gpt-5.6-* / gpt-6-* / *-pro / o 系）。命中就**根本不发** temperature，
    /// 省掉「400 → 去参重试」那趟废请求；LlmClient 里的去参重试只作兜底。
    /// 注：`-pro` 也会命中 deepseek-v4-pro——DeepSeek 的思考档同样忽略 temperature，不发是对的。
    /// 与 Mac 端 LLMCatalog.rejectsCustomTemperature 同源。
    public static bool RejectsCustomTemperature(string? model)
    {
        var m = (model ?? "").ToLowerInvariant();
        if (m.Contains("5.5", StringComparison.Ordinal)
            || m.Contains("5.6", StringComparison.Ordinal)
            || m.Contains("gpt-6", StringComparison.Ordinal)) return true;
        if (m.Contains("-pro", StringComparison.Ordinal)) return true;
        // o 系（o1 / o3 / o4 / 以后的 o5…）：字母 o 紧跟一位数字
        return m.Length >= 2 && m[0] == 'o' && m[1] >= '0' && m[1] <= '9';
    }
}
