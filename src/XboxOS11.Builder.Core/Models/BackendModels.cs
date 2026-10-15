using System.Text.Json;

namespace XboxOS11.Builder.Core.Models;

public sealed class BuilderCatalog
{
    public string EngineVersion { get; set; } = string.Empty;
    public string ProfileSchemaVersion { get; set; } = string.Empty;
    public List<PresetSummary> Presets { get; set; } = [];
    public List<string> Launchers { get; set; } = [];
    public List<string> PrivacyOptions { get; set; } = [];
    public List<OptimizationInfo> Optimizations { get; set; } = [];
    public List<NeverChangeInfo> NeverChange { get; set; } = [];
    public string DefaultOutput { get; set; } = @"C:\XboxOS\Output";
    public string DefaultProfileFolder { get; set; } = @"C:\XboxOS\Profiles";
}

public sealed class OptimizationInfo
{
    public string Id { get; set; } = string.Empty;
    public string Title { get; set; } = string.Empty;
    public string Description { get; set; } = string.Empty;
    public string Scope { get; set; } = "User";
    public bool RequiresRestart { get; set; }
    public bool DefaultEnabled { get; set; }
    public string SettingsPage { get; set; } = string.Empty;
}

public sealed class NeverChangeInfo
{
    public string Item { get; set; } = string.Empty;
    public string Reason { get; set; } = string.Empty;
}

public sealed class PresetSummary
{
    public string Id { get; set; } = string.Empty;
    public string DisplayName { get; set; } = string.Empty;
    public string Description { get; set; } = string.Empty;
    public bool Recommended { get; set; }
    public int Order { get; set; }
}

public sealed class ValidationResult
{
    public bool Valid { get; set; }
    public List<string> Errors { get; set; } = [];
    public List<string> Warnings { get; set; } = [];
}

public sealed class ProfileReview
{
    public string ProfileName { get; set; } = string.Empty;
    public string PresetId { get; set; } = string.Empty;
    public string ProfileHash { get; set; } = string.Empty;
    public List<AppCandidate> Apps { get; set; } = [];
    public List<FeatureCandidate> Features { get; set; } = [];
    public List<string> AlwaysPreserved { get; set; } = [];
    public ReviewSummary Summary { get; set; } = new();
    public ValidationResult Validation { get; set; } = new();
}

public sealed class AppCandidate
{
    public string Id { get; set; } = string.Empty;
    public string DisplayName { get; set; } = string.Empty;
    public string Reason { get; set; } = string.Empty;
    public bool Selected { get; set; }
    public bool Protected { get; set; }
    public bool Selectable { get; set; }
    public string? Note { get; set; }
}

public sealed class FeatureCandidate
{
    public string Id { get; set; } = string.Empty;
    public List<string> FeatureNames { get; set; } = [];
    public string Reason { get; set; } = string.Empty;
    public bool Selected { get; set; }
    public bool Protected { get; set; }
    public bool Selectable { get; set; }
    public bool PayloadKept { get; set; }
}

public sealed class ReviewSummary
{
    public int AppsRemoved { get; set; }
    public int FeaturesDisabled { get; set; }
    public bool DriversIntegrated { get; set; }
    public bool UpdatesIntegrated { get; set; }
    public bool UnattendGenerated { get; set; }
    public bool PostInstallEnabled { get; set; }
}

public sealed class ImageInfo
{
    public string ImageFile { get; set; } = string.Empty;
    public List<ImageEdition> Images { get; set; } = [];
}

public sealed class ImageEdition
{
    public int Index { get; set; }
    public string Name { get; set; } = string.Empty;
    public long SizeBytes { get; set; }

    public override string ToString() => $"{Index}: {Name}";
}

public sealed class UnattendPreview
{
    public string Xml { get; set; } = string.Empty;
}

public sealed class SavedProfile
{
    public string Path { get; set; } = string.Empty;
    public List<string> Warnings { get; set; } = [];
}

/// <summary>One <c>XBOXOS-EVENT</c> progress line emitted by the build scripts.</summary>
public sealed class BuildEvent
{
    public string Type { get; init; } = string.Empty;
    public DateTimeOffset? Utc { get; init; }
    public JsonElement Raw { get; init; }

    public string? GetString(string name) =>
        Raw.ValueKind == JsonValueKind.Object && Raw.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString()
            : null;

    public bool? GetBool(string name) =>
        Raw.ValueKind == JsonValueKind.Object && Raw.TryGetProperty(name, out var v) && v.ValueKind is JsonValueKind.True or JsonValueKind.False
            ? v.GetBoolean()
            : null;

    public IReadOnlyList<string> GetStrings(string name)
    {
        if (Raw.ValueKind != JsonValueKind.Object || !Raw.TryGetProperty(name, out var v))
        {
            return [];
        }

        return v.ValueKind switch
        {
            JsonValueKind.Array => v.EnumerateArray().Where(e => e.ValueKind == JsonValueKind.String).Select(e => e.GetString()!).ToList(),
            JsonValueKind.String => [v.GetString()!],
            _ => [],
        };
    }
}
