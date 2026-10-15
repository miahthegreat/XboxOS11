using XboxOS11.Builder.Core.Models;

namespace XboxOS11.Builder.Core.Profiles;

/// <summary>
/// UI-independent editing rules over a <see cref="BuildProfile"/>: protected components can never be selected,
/// dependent setup options follow their prerequisites, and every change marks the profile as Custom.
/// </summary>
public sealed class ProfileEditor
{
    public const string CustomPresetId = "custom";

    private readonly HashSet<string> _protectedApps = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> _protectedFeatures = new(StringComparer.OrdinalIgnoreCase);

    public ProfileEditor(BuildProfile profile) => Profile = profile;

    public BuildProfile Profile { get; private set; }

    public bool IsDirty { get; private set; }

    public void ApplyReview(ProfileReview review)
    {
        _protectedApps.Clear();
        _protectedFeatures.Clear();
        foreach (var a in review.Apps.Where(a => a.Protected || !a.Selectable))
        {
            _protectedApps.Add(a.Id);
        }

        foreach (var f in review.Features.Where(f => f.Protected || !f.Selectable))
        {
            _protectedFeatures.Add(f.Id);
        }

        // Defensive: drop anything protected that slipped into the profile.
        Profile.Apps.Remove.RemoveAll(_protectedApps.Contains);
        Profile.Features.Disable.RemoveAll(_protectedFeatures.Contains);
    }

    /// <summary>Replaces component/setup choices with a preset while keeping the user's ISO, name, and output.</summary>
    public void ApplyPreset(BuildProfile preset)
    {
        var next = preset.Clone();
        next.Name = Profile.Name;
        next.Source.IsoPath = Profile.Source.IsoPath;
        next.Source.ImageIndex = Profile.Source.ImageIndex;
        next.Output.Directory = Profile.Output.Directory;
        Profile = next;
        IsDirty = true;
    }

    public void Load(BuildProfile profile)
    {
        Profile = profile;
        IsDirty = false;
    }

    public void MarkSaved() => IsDirty = false;

    private void Changed()
    {
        IsDirty = true;
        Profile.PresetId = CustomPresetId;
    }

    public bool IsAppProtected(string id) => _protectedApps.Contains(id);

    public bool IsFeatureProtected(string id) => _protectedFeatures.Contains(id);

    public bool SetAppRemoved(string id, bool remove)
    {
        if (remove && _protectedApps.Contains(id))
        {
            return false;
        }

        var list = Profile.Apps.Remove;
        var has = list.Contains(id, StringComparer.OrdinalIgnoreCase);
        if (remove == has)
        {
            return true;
        }

        if (remove) { list.Add(id); } else { list.RemoveAll(x => x.Equals(id, StringComparison.OrdinalIgnoreCase)); }
        Changed();
        return true;
    }

    public bool SetFeatureDisabled(string id, bool disable)
    {
        if (disable && _protectedFeatures.Contains(id))
        {
            return false;
        }

        var list = Profile.Features.Disable;
        var has = list.Contains(id, StringComparer.OrdinalIgnoreCase);
        if (disable == has)
        {
            return true;
        }

        if (disable) { list.Add(id); } else { list.RemoveAll(x => x.Equals(id, StringComparison.OrdinalIgnoreCase)); }
        Changed();
        return true;
    }

    public void SetLauncher(string launcher, bool selected)
    {
        var list = Profile.Setup.PostInstall.Launchers;
        var has = list.Contains(launcher, StringComparer.OrdinalIgnoreCase);
        if (selected == has)
        {
            return;
        }

        if (selected) { list.Add(launcher); } else { list.RemoveAll(x => x.Equals(launcher, StringComparison.OrdinalIgnoreCase)); }
        Changed();
    }

    /// <summary>Turning unattend off also turns off the options that depend on it (the backend would reject them).</summary>
    public void SetUnattend(bool enabled)
    {
        if (Profile.Setup.Unattend == enabled)
        {
            return;
        }

        Profile.Setup.Unattend = enabled;
        if (!enabled)
        {
            Profile.Setup.PostInstall.Enabled = false;
            Profile.Setup.StartupToGamingHome = false;
            Profile.Setup.HideEula = false;
        }

        Changed();
    }

    public void SetStartupToGamingHome(bool enabled)
    {
        if (enabled && !Profile.Setup.Unattend)
        {
            SetUnattend(true);
        }

        if (Profile.Setup.StartupToGamingHome != enabled)
        {
            Profile.Setup.StartupToGamingHome = enabled;
            Changed();
        }
    }

    public void SetPostInstall(bool enabled)
    {
        if (enabled && !Profile.Setup.Unattend)
        {
            SetUnattend(true);
        }

        if (Profile.Setup.PostInstall.Enabled != enabled)
        {
            Profile.Setup.PostInstall.Enabled = enabled;
            Changed();
        }
    }

    /// <summary>Generic edit hook for simple scalar settings bound directly from the UI.</summary>
    public void Edit(Action<BuildProfile> change, bool marksCustom = true)
    {
        change(Profile);
        IsDirty = true;
        if (marksCustom)
        {
            Profile.PresetId = CustomPresetId;
        }
    }

    /// <summary>Profile name rules mirrored from the backend so the UI can flag them as the user types.</summary>
    public static bool IsValidProfileName(string? name) =>
        !string.IsNullOrEmpty(name)
        && name.Length <= 64
        && char.IsAsciiLetterOrDigit(name[0])
        && name.All(c => char.IsAsciiLetterOrDigit(c) || c is ' ' or '_' or '.' or '-');

    public static bool IsValidIsoLabel(string? label) =>
        !string.IsNullOrEmpty(label) && label.Length <= 32 && label.All(c => char.IsAsciiLetterOrDigit(c) || c == '_');
}
