using System.Text.Json;
using XboxOS11.Builder.Core.Models;

namespace XboxOS11.Builder.Core.Profiles;

public sealed class AppSettings
{
    public List<string> RecentProfiles { get; set; } = [];
    public string? LastIsoFolder { get; set; }
    public string? ToolkitOverride { get; set; }
}

/// <summary>Per-user app settings in %LOCALAPPDATA%\XboxOS11\settings.json. Never stores secrets.</summary>
public sealed class AppSettingsStore
{
    public const int MaxRecentProfiles = 8;
    private readonly string _path;

    public AppSettingsStore(string? path = null)
    {
        _path = path ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "XboxOS11", "settings.json");
    }

    public AppSettings Load()
    {
        try
        {
            if (File.Exists(_path))
            {
                return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(_path), BuilderJson.Options) ?? new AppSettings();
            }
        }
        catch (JsonException)
        {
            // Corrupt settings are non-fatal; start fresh.
        }
        catch (IOException)
        {
        }

        return new AppSettings();
    }

    public void Save(AppSettings settings)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        File.WriteAllText(_path, JsonSerializer.Serialize(settings, BuilderJson.Indented));
    }

    public AppSettings AddRecentProfile(string profilePath)
    {
        var s = Load();
        s.RecentProfiles.RemoveAll(p => p.Equals(profilePath, StringComparison.OrdinalIgnoreCase));
        s.RecentProfiles.Insert(0, profilePath);
        if (s.RecentProfiles.Count > MaxRecentProfiles)
        {
            s.RecentProfiles.RemoveRange(MaxRecentProfiles, s.RecentProfiles.Count - MaxRecentProfiles);
        }

        Save(s);
        return s;
    }
}
