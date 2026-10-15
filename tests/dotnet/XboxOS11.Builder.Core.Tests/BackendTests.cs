using XboxOS11.Builder.Core.Backend;
using XboxOS11.Builder.Core.Models;

namespace XboxOS11.Builder.Core.Tests;

public class BackendTests
{
    private static readonly ToolkitLocation Toolkit = new(@"C:\Toolkit", @"C:\pwsh\pwsh.exe");

    private static string Ok(string command, string data) =>
        $"XBOXOS-RESULT {{\"ok\":true,\"command\":\"{command}\",\"apiVersion\":\"xboxos-builder-api-v1\",\"data\":{data}}}";

    [Fact]
    public async Task CallsTheApiScriptWithFixedSafeArguments()
    {
        var runner = new FakeRunner((_, _) => (0, [Ok("catalog", "{\"engineVersion\":\"7.0.0\",\"presets\":[{\"id\":\"gaming-balanced\",\"recommended\":true}],\"launchers\":[\"Steam\"]}")]));
        var catalog = await new BuilderBackend(Toolkit, runner).GetCatalogAsync();
        Assert.Equal("7.0.0", catalog.EngineVersion);
        Assert.True(catalog.Presets[0].Recommended);
        var (file, args) = Assert.Single(runner.Calls);
        Assert.Equal(@"C:\pwsh\pwsh.exe", file);
        Assert.Equal(["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", Toolkit.ApiScript, "-Command", "catalog"], args);
    }

    [Fact]
    public async Task ValidatesThroughAScratchFileThatIsRemovedAfterwards()
    {
        using var tmp = new TempDir();
        string? seenPath = null;
        string? seenJson = null;
        var runner = new FakeRunner((_, args) =>
        {
            seenPath = args[args.ToList().IndexOf("-ProfilePath") + 1];
            seenJson = File.ReadAllText(seenPath);
            return (0, [Ok("validate", "{\"valid\":true,\"errors\":[],\"warnings\":[\"w\"]}")]);
        });
        var profile = new BuildProfile { Name = "Scratch Test" };
        var result = await new BuilderBackend(Toolkit, runner, tmp.Path).ValidateAsync(profile, forBuild: true);
        Assert.True(result.Valid);
        Assert.Equal(["w"], result.Warnings);
        Assert.Contains("-ForBuild", runner.Calls[0].Args);
        Assert.Contains("\"name\": \"Scratch Test\"", seenJson);
        Assert.False(File.Exists(seenPath));
    }

    [Fact]
    public async Task StreamsBuildEventsSeparatelyFromLogLines()
    {
        using var tmp = new TempDir();
        var runner = new FakeRunner((_, _) => (0,
        [
            "XBOXOS-EVENT {\"type\":\"started\",\"dryRun\":true}",
            "[Information] Starting phase: ImportSource",
            "XBOXOS-EVENT {\"type\":\"phase\",\"name\":\"ImportSource\",\"status\":\"succeeded\"}",
            "XBOXOS-EVENT {\"type\":\"completed\",\"isoPath\":\"C:\\\\XboxOS\\\\Output\\\\x.iso\"}",
        ]));
        var events = new List<BuildEvent>();
        var logs = new List<string>();
        var outcome = await new BuilderBackend(Toolkit, runner, tmp.Path).RunBuildAsync(
            new BuildProfile(), dryRun: true, new SyncProgress<BuildEvent>(events.Add), new SyncProgress<string>(logs.Add));

        Assert.True(outcome.Succeeded);
        Assert.Equal(@"C:\XboxOS\Output\x.iso", outcome.IsoPath);
        Assert.Equal(["started", "phase", "completed"], events.Select(e => e.Type));
        Assert.Equal(["[Information] Starting phase: ImportSource"], logs);
        var args = runner.Calls[0].Args;
        Assert.Contains(Toolkit.BuildScript, args);
        Assert.Contains("-EmitEvents", args);
        Assert.Contains("-DryRun", args);
        Assert.True(File.Exists(outcome.ProfileSnapshotPath));
    }

    [Fact]
    public async Task ReportsInvalidProfileExitCode()
    {
        using var tmp = new TempDir();
        var runner = new FakeRunner((_, _) => (4, ["XBOXOS-EVENT {\"type\":\"failed\",\"stage\":\"validation\"}"]));
        var outcome = await new BuilderBackend(Toolkit, runner, tmp.Path).RunBuildAsync(new BuildProfile(), false, null, null);
        Assert.False(outcome.Succeeded);
        Assert.True(outcome.InvalidProfile);
        Assert.DoesNotContain("-DryRun", runner.Calls[0].Args);
    }

    [Fact]
    public void FindsTheRepositoryToolkitFromNestedDirectories()
    {
        var nested = Path.Combine(RepoPaths.RepoRoot, "src", "XboxOS11.Builder.App", "bin");
        Assert.Equal(RepoPaths.RepoRoot, ToolkitLocator.FindToolkitRoot(nested, getEnvironment: _ => null));
    }

    [Fact]
    public void PrefersExplicitOverrideAndEnvironmentVariable()
    {
        Assert.Equal(RepoPaths.RepoRoot, ToolkitLocator.FindToolkitRoot(@"C:\", RepoPaths.RepoRoot, _ => null));
        Assert.Equal(RepoPaths.RepoRoot, ToolkitLocator.FindToolkitRoot(@"C:\", null, n => n == ToolkitLocator.ToolkitEnvironmentVariable ? RepoPaths.RepoRoot : null));
        Assert.Null(ToolkitLocator.FindToolkitRoot(Path.GetTempPath(), @"C:\definitely\not\here", _ => null));
    }

    [Fact]
    public void PrefersPowerShell7ThenWindowsPowerShell()
    {
        var env = new Dictionary<string, string?>
        {
            ["PATH"] = @"C:\Tools;C:\Program Files\PowerShell\7",
            ["ProgramFiles"] = @"C:\Program Files",
            ["SystemRoot"] = @"C:\Windows",
        };
        Assert.Equal(@"C:\Program Files\PowerShell\7\pwsh.exe",
            ToolkitLocator.FindPowerShell(n => env.GetValueOrDefault(n), f => f == @"C:\Program Files\PowerShell\7\pwsh.exe" || f.EndsWith("powershell.exe")));
        Assert.Equal(@"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe",
            ToolkitLocator.FindPowerShell(n => env.GetValueOrDefault(n), f => f.EndsWith("powershell.exe")));
        Assert.Null(ToolkitLocator.FindPowerShell(n => env.GetValueOrDefault(n), _ => false));
        Assert.True(new ToolkitLocation("x", @"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe").IsWindowsPowerShell);
    }
}
