using XboxOS11.Builder.Core.Models;

namespace XboxOS11.Builder.Core.Backend;

/// <summary>Typed client for <c>scripts/Invoke-XboxOSBuilderApi.ps1</c> and <c>scripts/Invoke-XboxOSBuild.ps1</c>.</summary>
public sealed class BuilderBackend
{
    private readonly ToolkitLocation _toolkit;
    private readonly IProcessRunner _runner;
    private readonly string _scratchDirectory;

    public BuilderBackend(ToolkitLocation toolkit, IProcessRunner? runner = null, string? scratchDirectory = null)
    {
        _toolkit = toolkit;
        _runner = runner ?? new ProcessRunner();
        _scratchDirectory = scratchDirectory ?? Path.Combine(Path.GetTempPath(), "XboxOS11.Builder");
    }

    public ToolkitLocation Toolkit => _toolkit;

    private IReadOnlyList<string> ScriptArguments(string script, IEnumerable<string> args)
    {
        var list = new List<string> { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script };
        list.AddRange(args);
        return list;
    }

    private async Task<T> CallAsync<T>(string command, IEnumerable<string> extraArgs, CancellationToken ct)
    {
        var args = ScriptArguments(_toolkit.ApiScript, new[] { "-Command", command }.Concat(extraArgs));
        var result = await _runner.RunAsync(_toolkit.PowerShellPath, args, null, ct).ConfigureAwait(false);
        return Protocol.ParseResult<T>(command, result.Lines);
    }

    /// <summary>Writes the profile to a private scratch file so commands always see exactly what the UI holds.</summary>
    private string WriteScratchProfile(BuildProfile profile)
    {
        Directory.CreateDirectory(_scratchDirectory);
        var path = Path.Combine(_scratchDirectory, $"profile-{Guid.NewGuid():N}.json");
        File.WriteAllText(path, profile.ToJson());
        return path;
    }

    private async Task<T> WithProfileAsync<T>(BuildProfile profile, Func<string, Task<T>> action)
    {
        var path = WriteScratchProfile(profile);
        try
        {
            return await action(path).ConfigureAwait(false);
        }
        finally
        {
            try { File.Delete(path); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }

    public Task<BuilderCatalog> GetCatalogAsync(CancellationToken ct = default) =>
        CallAsync<BuilderCatalog>("catalog", [], ct);

    public Task<BuildProfile> NewProfileAsync(string presetId, string name, string? sourceIso = null, CancellationToken ct = default)
    {
        var args = new List<string> { "-PresetId", presetId, "-Name", name };
        if (!string.IsNullOrWhiteSpace(sourceIso))
        {
            args.AddRange(["-SourceIso", sourceIso]);
        }

        return CallAsync<BuildProfile>("new-profile", args, ct);
    }

    public Task<ValidationResult> ValidateAsync(BuildProfile profile, bool forBuild, CancellationToken ct = default) =>
        WithProfileAsync(profile, path =>
        {
            var args = new List<string> { "-ProfilePath", path };
            if (forBuild)
            {
                args.Add("-ForBuild");
            }

            return CallAsync<ValidationResult>("validate", args, ct);
        });

    public Task<ProfileReview> ReviewAsync(BuildProfile profile, CancellationToken ct = default) =>
        WithProfileAsync(profile, path => CallAsync<ProfileReview>("review", ["-ProfilePath", path], ct));

    public Task<UnattendPreview> PreviewUnattendAsync(BuildProfile profile, CancellationToken ct = default) =>
        WithProfileAsync(profile, path => CallAsync<UnattendPreview>("unattend", ["-ProfilePath", path], ct));

    public Task<SavedProfile> SaveProfileAsync(BuildProfile profile, string destination, CancellationToken ct = default) =>
        WithProfileAsync(profile, path => CallAsync<SavedProfile>("save-profile", ["-ProfilePath", path, "-OutputPath", destination], ct));

    public Task<ImageInfo> GetImageInfoAsync(string isoPath, CancellationToken ct = default) =>
        CallAsync<ImageInfo>("image-info", ["-SourceIso", isoPath], ct);

    /// <summary>
    /// Runs a profile-driven build, reporting each progress event and log line. Returns the script exit code
    /// (0 success, 1 build failure, 4 invalid profile).
    /// </summary>
    public async Task<BuildOutcome> RunBuildAsync(BuildProfile profile, bool dryRun, IProgress<BuildEvent>? events, IProgress<string>? log, CancellationToken ct = default)
    {
        Directory.CreateDirectory(_scratchDirectory);
        var path = Path.Combine(_scratchDirectory, $"build-profile-{DateTime.UtcNow:yyyyMMddHHmmss}.json");
        await File.WriteAllTextAsync(path, profile.ToJson(), ct).ConfigureAwait(false);

        var args = new List<string> { "-ProfilePath", path, "-EmitEvents" };
        if (dryRun)
        {
            args.Add("-DryRun");
        }

        BuildEvent? last = null;
        var result = await _runner.RunAsync(_toolkit.PowerShellPath, ScriptArguments(_toolkit.BuildScript, args), line =>
        {
            if (Protocol.TryParseEvent(line, out var evt) && evt is not null)
            {
                last = evt;
                events?.Report(evt);
            }
            else
            {
                log?.Report(line);
            }
        }, ct).ConfigureAwait(false);

        return new BuildOutcome(result.ExitCode, last, path);
    }
}

public sealed record BuildOutcome(int ExitCode, BuildEvent? LastEvent, string ProfileSnapshotPath)
{
    public bool Succeeded => ExitCode == 0 && LastEvent?.Type == "completed";
    public bool InvalidProfile => ExitCode == 4;
    public string? IsoPath => LastEvent?.GetString("isoPath");
}
