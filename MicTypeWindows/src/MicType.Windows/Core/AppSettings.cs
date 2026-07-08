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
    public string SpeechModelDirectory { get; set; } = "";
    public string CustomVocabulary { get; set; } = "";

    public PolishLevel PolishLevel { get; set; } = PolishLevel.Smart;
    public LlmProvider LlmProvider { get; set; } = LlmProvider.OpenAi;
    public string OpenAiBaseUrl { get; set; } = "https://api.openai.com/v1";
    public string DeepSeekBaseUrl { get; set; } = "https://api.deepseek.com";
    public string OpenAiPolishModel { get; set; } = "gpt-5.5";
    public string OpenAiCommandModel { get; set; } = "gpt-5.4-mini";
    public string DeepSeekPolishModel { get; set; } = "deepseek-v4-flash";
    public string DeepSeekCommandModel { get; set; } = "deepseek-v4-flash";
    public double PolishTemperature { get; set; } = 0.5;
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
            return LlmProvider == LlmProvider.OpenAi ? "https://api.openai.com/v1" : "https://api.deepseek.com";
        }
    }

    [JsonIgnore]
    public string CurrentPolishModel => LlmProvider == LlmProvider.OpenAi ? OpenAiPolishModel : DeepSeekPolishModel;

    [JsonIgnore]
    public string CurrentCommandModel => LlmProvider == LlmProvider.OpenAi ? OpenAiCommandModel : DeepSeekCommandModel;

    [JsonIgnore]
    public string CurrentCredentialTarget =>
        LlmProvider == LlmProvider.OpenAi ? CredentialTargets.OpenAiApiKey : CredentialTargets.DeepSeekApiKey;

    [JsonIgnore]
    public IReadOnlyList<string> VocabularyTerms => ParseVocabulary(CustomVocabulary).Terms;

    [JsonIgnore]
    public IReadOnlyList<(string Wrong, string Right)> VocabularyReplacements =>
        ParseVocabulary(CustomVocabulary).Replacements;

    public static (IReadOnlyList<string> Terms, IReadOnlyList<(string Wrong, string Right)> Replacements)
        ParseVocabulary(string value)
    {
        var terms = new List<string>();
        var replacements = new List<(string Wrong, string Right)>();
        foreach (var raw in value.Split([',', '，', '、', '\n', '\r'],
                     StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries))
        {
            var entry = raw.Replace('＝', '=').Trim();
            var equalsIndex = entry.IndexOf('=');
            if (equalsIndex >= 0)
            {
                var wrong = entry[..equalsIndex].Trim();
                var right = entry[(equalsIndex + 1)..].Trim();
                if (wrong.Length == 0 || right.Length == 0) continue;
                replacements.Add((wrong, right));
                terms.Add(right);
            }
            else if (entry.Length > 0)
            {
                terms.Add(entry);
            }
        }

        return (terms, replacements);
    }

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
    }

    private static AppSettings Load()
    {
        try
        {
            if (!File.Exists(AppPaths.SettingsPath))
            {
                var fresh = new AppSettings();
                File.WriteAllText(AppPaths.SettingsPath, JsonSerializer.Serialize(fresh, JsonOptions));
                return fresh;
            }

            var json = File.ReadAllText(AppPaths.SettingsPath);
            return JsonSerializer.Deserialize<AppSettings>(json, JsonOptions) ?? new AppSettings();
        }
        catch (Exception ex)
        {
            Log.Error(ex, "Failed to load settings");
            SelfHealCorruptFile();
            return new AppSettings();
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
            File.WriteAllText(path, JsonSerializer.Serialize(new AppSettings(), JsonOptions));
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
