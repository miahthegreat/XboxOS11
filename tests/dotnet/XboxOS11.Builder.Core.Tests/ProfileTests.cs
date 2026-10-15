using System.Text.Json;
using System.Text.Json.Nodes;
using XboxOS11.Builder.Core.Models;
using XboxOS11.Builder.Core.Profiles;

namespace XboxOS11.Builder.Core.Tests;

public class ProfileTests
{
    private static BuildProfile LoadPreset(string id)
    {
        var doc = JsonNode.Parse(File.ReadAllText(Path.Combine(RepoPaths.PresetsDirectory, id + ".json")))!;
        var profile = BuildProfile.FromJson(doc["profile"]!.ToJsonString());
        profile.PresetId = id;
        return profile;
    }

    [Theory]
    [InlineData("gaming-balanced")]
    [InlineData("gaming-lean")]
    [InlineData("gaming-tiny")]
    [InlineData("handheld-xbox-mode")]
    [InlineData("stock-safe")]
    public void ReadsEveryShippedPreset(string id)
    {
        var p = LoadPreset(id);
        Assert.Equal("*Pro*", p.Source.EditionPattern);
        Assert.Null(p.Source.ImageIndex);
        Assert.False(string.IsNullOrWhiteSpace(p.Output.Directory));
    }

    [Fact]
    public void SerializesEveryBackendKeyInCamelCaseIncludingNulls()
    {
        var json = JsonNode.Parse(new BuildProfile().ToJson())!.AsObject();
        Assert.Equal(
            ["schemaVersion", "name", "description", "presetId", "source", "apps", "features", "drivers", "updates", "setup", "output", "capabilities", "image"],
            json.Select(kv => kv.Key).ToArray());
        Assert.True(json["source"]!.AsObject().ContainsKey("imageIndex"));
        Assert.Null(json["source"]!["imageIndex"]);
        Assert.Equal(
            ["enabled", "gameMode", "hardwareAcceleratedGpuScheduling", "launchers", "optimizations"],
            json["setup"]!["postInstall"]!.AsObject().Select(kv => kv.Key).ToArray());
    }

    [Fact]
    public void RoundTripsAndClonesIndependently()
    {
        var p = LoadPreset("gaming-balanced");
        var copy = p.Clone();
        copy.Apps.Remove.Clear();
        Assert.NotEmpty(p.Apps.Remove);
        Assert.Equal(JsonSerializer.Serialize(p, BuilderJson.Options), JsonSerializer.Serialize(BuildProfile.FromJson(p.ToJson()), BuilderJson.Options));
    }

    private static ProfileEditor EditorWithReview(BuildProfile p)
    {
        var editor = new ProfileEditor(p);
        editor.ApplyReview(new ProfileReview
        {
            Apps = [new AppCandidate { Id = "Clipchamp", Selectable = true }, new AppCandidate { Id = "XboxTCUI", Protected = true, Selectable = false }],
            Features = [new FeatureCandidate { Id = "Smb1", Selectable = true }],
        });
        return editor;
    }

    [Fact]
    public void NeverSelectsProtectedComponents()
    {
        var p = LoadPreset("gaming-balanced");
        p.Apps.Remove.Add("XboxTCUI");
        var editor = EditorWithReview(p);
        Assert.DoesNotContain("XboxTCUI", editor.Profile.Apps.Remove);
        Assert.False(editor.SetAppRemoved("XboxTCUI", true));
        Assert.True(editor.IsAppProtected("XboxTCUI"));
        Assert.DoesNotContain("XboxTCUI", editor.Profile.Apps.Remove);
    }

    [Fact]
    public void EditsMarkTheProfileCustomAndDirty()
    {
        var editor = EditorWithReview(LoadPreset("gaming-balanced"));
        Assert.False(editor.IsDirty);
        Assert.True(editor.SetAppRemoved("Clipchamp", false));
        Assert.True(editor.IsDirty);
        Assert.Equal(ProfileEditor.CustomPresetId, editor.Profile.PresetId);
        Assert.DoesNotContain("Clipchamp", editor.Profile.Apps.Remove);
        editor.SetLauncher("Epic", true);
        editor.SetLauncher("Epic", true);
        Assert.Single(editor.Profile.Setup.PostInstall.Launchers, l => l == "Epic");
        editor.SetOptimization("VariableRefreshRate", true);
        editor.SetOptimization("WindowedGameOptimizations", false);
        Assert.Contains("VariableRefreshRate", editor.Profile.Setup.PostInstall.Optimizations);
        Assert.DoesNotContain("WindowedGameOptimizations", editor.Profile.Setup.PostInstall.Optimizations);
    }

    [Fact]
    public void ReadsTheTinyPresetLeanOptions()
    {
        var p = LoadPreset("gaming-tiny");
        Assert.Equal(8, p.Capabilities.Remove.Count);
        Assert.True(p.Image.ComponentCleanup);
        Assert.True(p.Image.ResetBase);
        Assert.Equal("Recovery", p.Image.Compression);
        Assert.Contains("NoOneDriveForNewAccounts", p.Image.Tweaks);
        var balanced = LoadPreset("gaming-balanced");
        Assert.Empty(balanced.Capabilities.Remove);
        Assert.Equal(ImageOptions.DefaultCompression, balanced.Image.Compression);
    }

    [Fact]
    public void LeanOptionRulesMirrorTheBackend()
    {
        var editor = new ProfileEditor(LoadPreset("stock-safe"));
        editor.ApplyReview(new ProfileReview
        {
            Capabilities = [new CapabilityCandidate { Id = "StepsRecorder", Selectable = true }, new CapabilityCandidate { Id = "Locked", Protected = true }],
        });
        Assert.True(editor.SetCapabilityRemoved("StepsRecorder", true));
        Assert.False(editor.SetCapabilityRemoved("Locked", true));
        Assert.Equal(["StepsRecorder"], editor.Profile.Capabilities.Remove);

        editor.SetResetBase(true);
        Assert.True(editor.Profile.Image.ComponentCleanup);
        editor.SetComponentCleanup(false);
        Assert.False(editor.Profile.Image.ResetBase);

        editor.SetAllowUnsupportedHardware(true);
        Assert.True(editor.Profile.Setup.Unattend);
        editor.SetLocalAccount(true);
        editor.SetUnattend(false);
        Assert.False(editor.Profile.Setup.AllowUnsupportedHardware);
        Assert.False(editor.Profile.Setup.LocalAccount);
        Assert.Equal(ProfileEditor.CustomPresetId, editor.Profile.PresetId);
    }

    [Fact]
    public void DisablingUnattendDisablesDependentOptions()
    {
        var editor = new ProfileEditor(LoadPreset("handheld-xbox-mode"));
        editor.SetUnattend(false);
        Assert.False(editor.Profile.Setup.PostInstall.Enabled);
        Assert.False(editor.Profile.Setup.StartupToGamingHome);
        Assert.False(editor.Profile.Setup.HideEula);

        editor.SetStartupToGamingHome(true);
        Assert.True(editor.Profile.Setup.Unattend);
        Assert.True(editor.Profile.Setup.StartupToGamingHome);
    }

    [Fact]
    public void ApplyingAPresetKeepsIsoNameAndOutput()
    {
        var current = LoadPreset("gaming-balanced");
        current.Name = "Living Room";
        current.Source.IsoPath = @"D:\ISOs\Win11.iso";
        current.Source.ImageIndex = 6;
        current.Output.Directory = @"D:\Builds";
        var editor = new ProfileEditor(current);
        editor.ApplyPreset(LoadPreset("stock-safe"));
        Assert.Equal("Living Room", editor.Profile.Name);
        Assert.Equal(@"D:\ISOs\Win11.iso", editor.Profile.Source.IsoPath);
        Assert.Equal(6, editor.Profile.Source.ImageIndex);
        Assert.Equal(@"D:\Builds", editor.Profile.Output.Directory);
        Assert.Empty(editor.Profile.Apps.Remove);
        Assert.Equal("stock-safe", editor.Profile.PresetId);
    }

    [Theory]
    [InlineData("My Rig", true)]
    [InlineData("rig_v2.1-final", true)]
    [InlineData("", false)]
    [InlineData(" leading", false)]
    [InlineData("bad/slash", false)]
    public void MirrorsBackendNameRules(string name, bool valid) => Assert.Equal(valid, ProfileEditor.IsValidProfileName(name));

    [Theory]
    [InlineData("XboxOS11", true)]
    [InlineData("GAME_ISO", true)]
    [InlineData("Xbox OS", false)]
    [InlineData("ThisLabelIsWayTooLongForAnIsoVolume", false)]
    public void MirrorsBackendIsoLabelRules(string label, bool valid) => Assert.Equal(valid, ProfileEditor.IsValidIsoLabel(label));

    [Fact]
    public void KeepsABoundedRecentProfileList()
    {
        using var tmp = new TempDir();
        var store = new AppSettingsStore(Path.Combine(tmp.Path, "settings.json"));
        for (var i = 0; i < 12; i++)
        {
            store.AddRecentProfile($@"C:\XboxOS\Profiles\p{i}.json");
        }

        var s = store.AddRecentProfile(@"C:\XboxOS\Profiles\P3.JSON");
        Assert.Equal(AppSettingsStore.MaxRecentProfiles, s.RecentProfiles.Count);
        Assert.Equal(@"C:\XboxOS\Profiles\P3.JSON", s.RecentProfiles[0]);
        Assert.Single(s.RecentProfiles, p => p.Equals(@"C:\XboxOS\Profiles\p3.json", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public void ToleratesCorruptSettings()
    {
        using var tmp = new TempDir();
        var path = Path.Combine(tmp.Path, "settings.json");
        File.WriteAllText(path, "{ not json");
        Assert.Empty(new AppSettingsStore(path).Load().RecentProfiles);
    }
}
