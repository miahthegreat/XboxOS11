using System.Text.Json;
using System.Text.Json.Serialization;

namespace XboxOS11.Builder.Core.Models;

/// <summary>
/// Mirrors the backend <c>xboxos-build-profile-v1</c> schema exactly. The backend rejects unknown keys and
/// requires every key to be present, so every property here is always serialized (including nulls).
/// </summary>
public sealed class BuildProfile
{
    public const string SchemaVersionV1 = "xboxos-build-profile-v1";

    public string SchemaVersion { get; set; } = SchemaVersionV1;
    public string Name { get; set; } = "My XboxOS11 build";
    public string Description { get; set; } = string.Empty;
    public string PresetId { get; set; } = "gaming-balanced";
    public SourceOptions Source { get; set; } = new();
    public AppOptions Apps { get; set; } = new();
    public FeatureOptions Features { get; set; } = new();
    public FolderOption Drivers { get; set; } = new() { Directory = @"C:\XboxOS\Drivers" };
    public FolderOption Updates { get; set; } = new() { Directory = @"C:\XboxOS\Updates" };
    public SetupOptions Setup { get; set; } = new();
    public OutputOptions Output { get; set; } = new();

    public BuildProfile Clone() => FromJson(ToJson());

    public string ToJson() => JsonSerializer.Serialize(this, BuilderJson.Indented);

    public static BuildProfile FromJson(string json) =>
        JsonSerializer.Deserialize<BuildProfile>(json, BuilderJson.Options)
        ?? throw new InvalidDataException("Build profile JSON is empty.");
}

public sealed class SourceOptions
{
    public string IsoPath { get; set; } = string.Empty;
    public string EditionPattern { get; set; } = "*Pro*";
    public int? ImageIndex { get; set; }
}

public sealed class AppOptions
{
    public List<string> Remove { get; set; } = [];
}

public sealed class FeatureOptions
{
    public List<string> Disable { get; set; } = [];
}

public sealed class FolderOption
{
    public bool Enabled { get; set; }
    public string Directory { get; set; } = string.Empty;
}

public sealed class SetupOptions
{
    public bool Unattend { get; set; } = true;
    public string UiLanguage { get; set; } = "en-US";
    public string InputLocale { get; set; } = "en-US";
    public string SystemLocale { get; set; } = "en-US";
    public string UserLocale { get; set; } = "en-US";
    public string TimeZone { get; set; } = "Pacific Standard Time";
    public bool HideEula { get; set; } = true;
    public string Privacy { get; set; } = "Minimal";
    public bool StartupToGamingHome { get; set; }
    public PostInstallOptions PostInstall { get; set; } = new();
}

public sealed class PostInstallOptions
{
    public bool Enabled { get; set; } = true;
    public bool GameMode { get; set; } = true;
    public bool HardwareAcceleratedGpuScheduling { get; set; }
    public List<string> Launchers { get; set; } = [];
    public List<string> Optimizations { get; set; } = [];
}

public sealed class OutputOptions
{
    public string Directory { get; set; } = @"C:\XboxOS\Output";
    public string IsoLabel { get; set; } = "XboxOS11";
}

public static class BuilderJson
{
    public static JsonSerializerOptions Options { get; } = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true,
    };

    public static JsonSerializerOptions Indented { get; } = new(Options) { WriteIndented = true };
}
