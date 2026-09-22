using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;

namespace MicType.Win.Core;

public sealed class AppSettings
{
    public AppLanguage AppLanguage { get; set; } = CultureDefaultLanguage();
    public HotkeyChoice Hotkey { get; set; } = HotkeyChoice.RightControl;
    public bool PlaySounds { get; set; } = true;
    public bool RestoreClipboard { get; set; } = true;
    public bool LaunchAtLogin { get; set; }

    public string SpeechModelRepo { get; set; } = "sherpa-onnx/SenseVoiceSmall";
    public string CustomVocabulary { get; set; } = "";
    /// 本地口水词过滤表（逗号/换行分隔），默认空 = 不过滤，绝不替用户决定哪些词该删
    public string FillerWords { get; set; } = "";

    public PolishLevel PolishLevel { get; set; } = PolishLevel.Smart;
    public LlmProvider LlmProvider { get; set; } = LlmProvider.OpenAi;

    // 官方接入地址的唯一出处：属性初始值、被清空时的回退、串槽自愈都引这两个常量，别再另写字面量。
    // 用 const 而不是 static readonly：const 是编译期常量，不参与静态字段初始化顺序——
    // Windows 端踩过「默认值覆盖已存档设置」那个坑，起因就是静态初始化的先后依赖。
    public const string DefaultOpenAiBaseUrl = "https://api.openai.com/v1";
    public const string DefaultDeepSeekBaseUrl = "https://api.deepseek.com";

    public string OpenAiBaseUrl { get; set; } = DefaultOpenAiBaseUrl;
    public string DeepSeekBaseUrl { get; set; } = DefaultDeepSeekBaseUrl;
    // 出厂型号全部引 LlmModels 的常量，别在这里另写一份——两处值不一样的时候，
    // 用户看到的默认和代码里认的"自动默认"对不上，迁移就会把他手填的值当成默认值改掉。
    public string OpenAiPolishModel { get; set; } = LlmModels.OpenAiPolishDefault;
    public string OpenAiCommandModel { get; set; } = LlmModels.OpenAiCommandDefault;
    public string DeepSeekPolishModel { get; set; } = LlmModels.DeepSeekPolishDefault;
    public string DeepSeekCommandModel { get; set; } = LlmModels.DeepSeekCommandDefault;
    /// v4.0 型号迁移记账位。老 settings.json 里没有这个键 → 反序列化得 false → 迁移跑一次。
    /// 所以它**必须**默认 false；出厂新设置走 Factory() 直接置 true。
    public bool ModelsMigratedTo56 { get; set; }
    /// 润色温度。**4.3.3 从 0.5 降到 0.3**（与 Mac 端同源）：温度越低模型越少自由发挥
    /// （少无中生有的编号列表、少改写措辞），保真校验（PolishDriftCheck）的误拦就跟着少
    /// ——而误拦的代价是用户拿到一整段没润色过的识别原文。真 Key 实测 qwen3.8-flash：
    /// 0.2 与 0.5 对满是语气词的口述都是 0 残留，清理质量没差别。
    /// 只改默认值：settings.json 里已经存过值的用户照旧（滑杆上的数是他自己定的）。
    public double PolishTemperature { get; set; } = 0.3;
    public double CommandTemperature { get; set; } = 1.0;
    public string AboutMe { get; set; } = "";
    public string CustomPolishRules { get; set; } = "";

    [JsonIgnore]
    public string CurrentBaseUrl
    {
        get
        {
            // 被清空也回退官方默认——Base URL 永远自动有值
            var value = (LlmProvider == LlmProvider.OpenAi ? OpenAiBaseUrl : DeepSeekBaseUrl)?.Trim();
            if (!string.IsNullOrEmpty(value)) return value;
            return LlmProvider == LlmProvider.OpenAi ? DefaultOpenAiBaseUrl : DefaultDeepSeekBaseUrl;
        }
    }

    [JsonIgnore]
    public string CurrentPolishModel => LlmProvider == LlmProvider.OpenAi ? OpenAiPolishModel : DeepSeekPolishModel;

    [JsonIgnore]
    public string CurrentCommandModel => LlmProvider == LlmProvider.OpenAi ? OpenAiCommandModel : DeepSeekCommandModel;

    [JsonIgnore]
    public string CurrentCredentialTarget => CredentialTargets.For(LlmProvider);

    [JsonIgnore]
    public IReadOnlyList<string> VocabularyTerms => ParseVocabulary(CustomVocabulary).Terms;

    [JsonIgnore]
    public IReadOnlyList<string> FillerWordList => ParseFillerWords(FillerWords);

    [JsonIgnore]
    public IReadOnlyList<(string Wrong, string Right)> VocabularyReplacements =>
        ParseVocabulary(CustomVocabulary).Replacements;

    /// 只写**指定服务商**的三个槽位，不读也不改 LlmProvider。
    /// 界面保存必须走这里：按「当前生效的服务商」判断写哪一家，会在切换的那一刻把上一家的值写进下一家
    /// （4.3.1 及以前的 bug，后果是 OpenAI 的 Key 被发去 DeepSeek 的服务器）。
    public void SetProviderFields(LlmProvider provider, string baseUrl, string polishModel, string commandModel)
    {
        if (provider == LlmProvider.OpenAi)
        {
            OpenAiBaseUrl = baseUrl;
            OpenAiPolishModel = polishModel;
            OpenAiCommandModel = commandModel;
        }
        else
        {
            DeepSeekBaseUrl = baseUrl;
            DeepSeekPolishModel = polishModel;
            DeepSeekCommandModel = commandModel;
        }
    }

    /// 自愈已经被上面那个 bug 写坏的设置（载入之后跑一次，幂等）。
    /// 只认「明显串槽」这一种形态：接入地址的主机名属于另一家、或型号名带着另一家的前缀。
    /// 自定义代理地址、解析不出主机名的地址、空值**一律不动**——分不清是不是用户有意填的就别替他改。
    /// 返回 true = 有改动，调用方负责记日志并保存。
    public bool RepairCrossProviderFields() => RepairCrossProviderFields(out _);

    /// 同上，另带被修复的字段名（给日志用；日志只写字段名，不写地址、更不写 Key）。
    public bool RepairCrossProviderFields(out IReadOnlyList<string> repairedFields)
    {
        var repaired = new List<string>();

        if (HostBelongsTo(OpenAiBaseUrl, "deepseek.com"))
        {
            OpenAiBaseUrl = DefaultOpenAiBaseUrl;
            repaired.Add(nameof(OpenAiBaseUrl));
        }
        if (HostBelongsTo(DeepSeekBaseUrl, "openai.com"))
        {
            DeepSeekBaseUrl = DefaultDeepSeekBaseUrl;
            repaired.Add(nameof(DeepSeekBaseUrl));
        }
        if (StartsWithIgnoreCase(OpenAiPolishModel, "deepseek"))
        {
            OpenAiPolishModel = LlmModels.OpenAiPolishDefault;
            repaired.Add(nameof(OpenAiPolishModel));
        }
        if (StartsWithIgnoreCase(OpenAiCommandModel, "deepseek"))
        {
            OpenAiCommandModel = LlmModels.OpenAiCommandDefault;
            repaired.Add(nameof(OpenAiCommandModel));
        }
        // DeepSeek 侧只认 gpt- 前缀：o 系、别家的型号名规则猜不准，猜错就是替用户改掉他手选的型号
        if (StartsWithIgnoreCase(DeepSeekPolishModel, "gpt-"))
        {
            DeepSeekPolishModel = LlmModels.DeepSeekPolishDefault;
            repaired.Add(nameof(DeepSeekPolishModel));
        }
        if (StartsWithIgnoreCase(DeepSeekCommandModel, "gpt-"))
        {
            DeepSeekCommandModel = LlmModels.DeepSeekCommandDefault;
            repaired.Add(nameof(DeepSeekCommandModel));
        }

        repairedFields = repaired;
        return repaired.Count > 0;
    }

    /// 「这个地址是不是那一家的」：只看主机名，端口 / 路径不参与。
    /// 用「等于 domain 或以 .domain 结尾」而不是裸 EndsWith——否则 notdeepseek.com 也会被当成 DeepSeek。
    private static bool HostBelongsTo(string? url, string domain)
    {
        if (!Uri.TryCreate(url?.Trim(), UriKind.Absolute, out var uri)) return false;
        var host = uri.Host;
        return host.Equals(domain, StringComparison.OrdinalIgnoreCase)
               || host.EndsWith("." + domain, StringComparison.OrdinalIgnoreCase);
    }

    private static bool StartsWithIgnoreCase(string? value, string prefix) =>
        (value ?? "").TrimStart().StartsWith(prefix, StringComparison.OrdinalIgnoreCase);

    /// 词汇表解析：普通词条做热词/润色提示；"错写=正写"词条做硬替换（正写同时进热词）。
    /// 一个正写可以挂多个错写：「杰文|捷纹|结文=捷文」——同一个名字的各种听错法不必分行写。
    public static (IReadOnlyList<string> Terms, IReadOnlyList<(string Wrong, string Right)> Replacements)
        ParseVocabulary(string value)
    {
        var terms = new List<string>();
        var replacements = new List<(string Wrong, string Right)>();
        foreach (var raw in value.Split([',', '，', '、', '\n', '\r'],
                     StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries))
        {
            var entry = raw.Replace('＝', '=').Replace('｜', '|').Trim();
            var equalsIndex = entry.IndexOf('=');
            if (equalsIndex >= 0)
            {
                var left = entry[..equalsIndex].Trim();
                var right = entry[(equalsIndex + 1)..].Trim();
                if (left.Length == 0 || right.Length == 0) continue;
                var wrongs = left.Split('|', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
                if (wrongs.Length == 0) continue;
                foreach (var wrong in wrongs) replacements.Add((wrong, right));
                terms.Add(right);
            }
            else if (entry.Length > 0)
            {
                terms.Add(entry);
            }
        }

        return (terms, replacements);
    }

    /// 口水词表解析：逗号/换行分隔，和词汇表同一套分隔符
    public static IReadOnlyList<string> ParseFillerWords(string value)
    {
        return value.Split([',', '，', '、', '\n', '\r'],
                StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)
            .Where(item => item.Length > 0)
            .ToList();
    }

    /// 出厂新设置：型号已经是 v4.0 的了，不需要再迁移（标记直接置位，免得首启动多写一遍文件）
    internal static AppSettings Factory() => new() { ModelsMigratedTo56 = true };

    private static AppLanguage CultureDefaultLanguage()
    {
        var name = Thread.CurrentThread.CurrentUICulture.Name;
        return name.StartsWith("zh", StringComparison.OrdinalIgnoreCase) ? AppLanguage.Zh : AppLanguage.En;
    }
}

public static class CredentialTargets
{
    public const string OpenAiApiKey = "MicType/openai_api_key";
    public const string DeepSeekApiKey = "MicType/deepseek_api_key";

    /// 按服务商取 Key 的存放槽位。界面读写 Key 一律走这里传「框里装的那一家」，
    /// 这样「Key 只会存回它被载入的那一家」是结构性保证，不用靠事件先后碰运气。
    public static string For(LlmProvider provider) =>
        provider == LlmProvider.OpenAi ? OpenAiApiKey : DeepSeekApiKey;
}

public sealed class SettingsStore
{
    public static SettingsStore Instance { get; } = new();

    // 懒加载——绝不能用 static readonly 字段初始化器。静态字段按【文本声明顺序】初始化，
    // 而 Instance（声明在前）的构造函数会调用 Load() 用到 JsonOptions；若用字段，此刻
    // JsonOptions 尚未轮到初始化、值为 null，Deserialize(json, null) 退回默认选项（不含
    // lenient/string 枚举转换器），于是 Save() 写出的字符串枚举值（如 "Zh"）下次启动 Load
    // 时直接抛 JsonException → 设置被判损坏重置（每次启动都"保存不上"）。属性懒加载与声明
    // 顺序无关，首次访问即构建，故不会再踩这个坑。
    private static JsonSerializerOptions? _jsonOptions;
    private static JsonSerializerOptions JsonOptions => _jsonOptions ??= new JsonSerializerOptions
    {
        WriteIndented = true,
        Converters =
        {
            new HotkeyChoiceJsonConverter(),
            new LenientEnumConverterFactory(),
            new JsonStringEnumConverter()
        }
    };

    private SettingsStore()
    {
        Current = Load();
        ApplyPostLoadFixups();
    }

    public AppSettings Current { get; private set; }

    public void Save()
    {
        Directory.CreateDirectory(AppPaths.AppDataDir);
        var json = JsonSerializer.Serialize(Current, JsonOptions);
        // 原子写入：先写临时文件再替换，进程被杀或并发时不会留下半截文件
        var tmp = AppPaths.SettingsPath + ".tmp";
        File.WriteAllText(tmp, json);
        File.Move(tmp, AppPaths.SettingsPath, overwrite: true);
        Log.Info("Settings saved");
    }

    public void Reload()
    {
        Current = Load();
        ApplyPostLoadFixups();
    }

    /// 载入之后的修复，只在这一处：型号迁移 + 跨服务商串槽自愈。任一有改动才保存（保存仍是原子写入）。
    private void ApplyPostLoadFixups()
    {
        // v4.0 一次性型号迁移：旧版写进设置的 deepseek-v4-flash 等型号已经下线（调用直接 404/400），
        // 不改名的话用户每次润色 / 指令都失败，而错误只说「模型名不存在」，他无从知道是默认值死了。
        var needsSave = LlmModels.ApplyMigration(Current);
        // 4.3.1 及以前切服务商会把上一家的地址 / 型号写进下一家（SettingsWindow 里先保存后重载、
        // 保存时却按刚切过去的新服务商判断写哪一家）。已经写坏的设置在这里自愈；日志只记字段名。
        if (Current.RepairCrossProviderFields(out var repairedFields))
        {
            Log.Info("Repaired cross-provider settings fields: " + string.Join(", ", repairedFields));
            needsSave = true;
        }
        if (needsSave) Save();
    }

    private static AppSettings Load()
    {
        try
        {
            if (!File.Exists(AppPaths.SettingsPath))
            {
                var fresh = AppSettings.Factory();
                File.WriteAllText(AppPaths.SettingsPath, JsonSerializer.Serialize(fresh, JsonOptions));
                return fresh;
            }

            var json = File.ReadAllText(AppPaths.SettingsPath);
            return JsonSerializer.Deserialize<AppSettings>(json, JsonOptions) ?? AppSettings.Factory();
        }
        catch (Exception ex)
        {
            Log.Error(ex, "Failed to load settings");
            SelfHealCorruptFile();
            return AppSettings.Factory();
        }
    }

    /// 坏文件备份为 settings.corrupt.json 并写回默认——避免每次启动都解析失败、用户设置看似"保存不上"
    private static void SelfHealCorruptFile()
    {
        try
        {
            var path = AppPaths.SettingsPath;
            if (File.Exists(path))
            {
                File.Move(path, path.Replace("settings.json", "settings.corrupt.json"), overwrite: true);
                Log.Warn("Corrupt settings backed up to settings.corrupt.json and reset to defaults");
            }
            File.WriteAllText(path, JsonSerializer.Serialize(AppSettings.Factory(), JsonOptions));
        }
        catch (Exception ex)
        {
            Log.Error(ex, "Settings self-heal failed");
        }
    }
}

/// 宽容的枚举反序列化：无法识别的值回退枚举默认值，绝不让单个坏字段毁掉整份设置
public sealed class LenientEnumConverterFactory : JsonConverterFactory
{
    public override bool CanConvert(Type typeToConvert) => typeToConvert.IsEnum;

    public override JsonConverter CreateConverter(Type typeToConvert, JsonSerializerOptions options)
    {
        return (JsonConverter)Activator.CreateInstance(
            typeof(LenientEnumConverter<>).MakeGenericType(typeToConvert))!;
    }

    private sealed class LenientEnumConverter<T> : JsonConverter<T> where T : struct, Enum
    {
        public override T Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
        {
            if (reader.TokenType == JsonTokenType.String &&
                Enum.TryParse<T>(reader.GetString(), ignoreCase: true, out var parsed) &&
                Enum.IsDefined(parsed))
            {
                return parsed;
            }
            if (reader.TokenType == JsonTokenType.Number &&
                reader.TryGetInt32(out var number) &&
                Enum.IsDefined((T)Enum.ToObject(typeof(T), number)))
            {
                return (T)Enum.ToObject(typeof(T), number);
            }
            return default;
        }

        public override void Write(Utf8JsonWriter writer, T value, JsonSerializerOptions options)
        {
            writer.WriteStringValue(value.ToString());
        }
    }
}

public sealed class HotkeyChoiceJsonConverter : JsonConverter<HotkeyChoice>
{
    public override HotkeyChoice Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        var value = reader.TokenType == JsonTokenType.String ? reader.GetString() : null;
        return value switch
        {
            nameof(HotkeyChoice.RightShift) => HotkeyChoice.RightShift,
            _ => HotkeyChoice.RightControl
        };
    }

    public override void Write(Utf8JsonWriter writer, HotkeyChoice value, JsonSerializerOptions options)
    {
        writer.WriteStringValue(value.ToString());
    }
}
