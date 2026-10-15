using XboxOS11.Builder.Core.Backend;
using XboxOS11.Builder.Core.Models;

namespace XboxOS11.Builder.Core.Tests;

/// <summary>
/// End-to-end contract tests against the real PowerShell backend in this repository. They prove that profiles
/// produced and edited by the .NET client are accepted by the strict backend validator, and vice versa.
/// </summary>
public class BackendContractTests
{
    private static BuilderBackend? CreateBackend(TempDir tmp)
    {
        var ps = ToolkitLocator.FindPowerShell();
        return ps is null ? null : new BuilderBackend(new ToolkitLocation(RepoPaths.RepoRoot, ps), scratchDirectory: tmp.Path);
    }

    [Fact]
    public async Task CatalogMatchesShippedPresets()
    {
        using var tmp = new TempDir();
        var backend = CreateBackend(tmp);
        if (backend is null) { return; }

        var catalog = await backend.GetCatalogAsync();
        Assert.Equal(BuildProfile.SchemaVersionV1, catalog.ProfileSchemaVersion);
        Assert.Equal(["gaming-balanced", "gaming-lean", "handheld-xbox-mode", "stock-safe"], catalog.Presets.Select(p => p.Id));
        Assert.Contains("Steam", catalog.Launchers);
    }

    [Fact]
    public async Task ClientProfilesRoundTripThroughTheStrictValidator()
    {
        using var tmp = new TempDir();
        var backend = CreateBackend(tmp);
        if (backend is null) { return; }

        var profile = await backend.NewProfileAsync("gaming-balanced", "Contract Rig");
        Assert.Equal("Contract Rig", profile.Name);
        profile.Output.Directory = Path.Combine(tmp.Path, "out");
        profile.Setup.PostInstall.Launchers.Add("Epic");
        profile.Source.ImageIndex = 6;

        var validation = await backend.ValidateAsync(profile, forBuild: false);
        Assert.True(validation.Valid, string.Join("; ", validation.Errors));

        var saved = await backend.SaveProfileAsync(profile, Path.Combine(tmp.Path, "saved", "rig.json"));
        var reloaded = BuildProfile.FromJson(File.ReadAllText(saved.Path));
        Assert.Equal(profile.ToJson(), reloaded.ToJson());
    }

    [Fact]
    public async Task ReviewFlagsProtectedComponentsAndValidatorRejectsThem()
    {
        using var tmp = new TempDir();
        var backend = CreateBackend(tmp);
        if (backend is null) { return; }

        var profile = await backend.NewProfileAsync("gaming-balanced", "Review Rig");
        profile.Output.Directory = Path.Combine(tmp.Path, "out");
        var review = await backend.ReviewAsync(profile);
        var tcui = Assert.Single(review.Apps, a => a.Id == "XboxTCUI");
        Assert.True(tcui.Protected);
        Assert.False(tcui.Selectable);
        Assert.Contains("Microsoft Defender", review.AlwaysPreserved);

        profile.Apps.Remove.Add("XboxTCUI");
        var validation = await backend.ValidateAsync(profile, forBuild: false);
        Assert.False(validation.Valid);
        Assert.Contains(validation.Errors, e => e.Contains("protected", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public async Task UnattendPreviewIsGeneratedAndForBuildRequiresTheIso()
    {
        using var tmp = new TempDir();
        var backend = CreateBackend(tmp);
        if (backend is null) { return; }

        var profile = await backend.NewProfileAsync("handheld-xbox-mode", "Handheld");
        profile.Output.Directory = Path.Combine(tmp.Path, "out");
        var unattend = await backend.PreviewUnattendAsync(profile);
        Assert.Contains("StartupToGamingHome", unattend.Xml);

        profile.Source.IsoPath = Path.Combine(tmp.Path, "missing.iso");
        var validation = await backend.ValidateAsync(profile, forBuild: true);
        Assert.Contains(validation.Errors, e => e.Contains("Source ISO not found"));
    }

    [Fact]
    public async Task DryRunBuildStreamsPhaseEvents()
    {
        using var tmp = new TempDir();
        var backend = CreateBackend(tmp);
        if (backend is null) { return; }

        var iso = Path.Combine(tmp.Path, "Win11.iso");
        File.WriteAllText(iso, "placeholder");
        var profile = await backend.NewProfileAsync("stock-safe", "Dry Run", iso);
        profile.Output.Directory = Path.Combine(tmp.Path, "out");

        var events = new List<BuildEvent>();
        var log = new List<string>();
        var outcome = await backend.RunBuildAsync(profile, dryRun: true, new SyncProgress<BuildEvent>(events.Add), new SyncProgress<string>(log.Add));
        Assert.True(outcome.Succeeded, $"exit {outcome.ExitCode}:\n{string.Join('\n', log.TakeLast(40))}");
        Assert.Contains(events, e => e.Type == "phase" && e.GetString("name") == "ExportIso" && e.GetString("status") == "succeeded");
    }
}
