using XboxOS11.Builder.Core.Backend;

namespace XboxOS11.Builder.Core.Tests;

internal static class RepoPaths
{
    public static string RepoRoot { get; } = ToolkitLocator.FindToolkitRoot(AppContext.BaseDirectory)
        ?? throw new InvalidOperationException("Tests must run from inside the XboxOS11 repository.");

    public static string PresetsDirectory => Path.Combine(RepoRoot, "config", "presets");
}

internal sealed class FakeRunner : IProcessRunner
{
    private readonly Func<string, IReadOnlyList<string>, (int ExitCode, string[] Lines)> _respond;

    public FakeRunner(Func<string, IReadOnlyList<string>, (int, string[])> respond) => _respond = respond;

    public List<(string File, IReadOnlyList<string> Args)> Calls { get; } = [];

    public Task<ProcessResult> RunAsync(string fileName, IReadOnlyList<string> arguments, Action<string>? onLine, CancellationToken cancellationToken)
    {
        Calls.Add((fileName, arguments.ToList()));
        var (code, lines) = _respond(fileName, arguments);
        foreach (var l in lines)
        {
            onLine?.Invoke(l);
        }

        return Task.FromResult(new ProcessResult(code, lines));
    }
}

internal sealed class SyncProgress<T>(Action<T> handler) : IProgress<T>
{
    public void Report(T value) => handler(value);
}

internal sealed class TempDir : IDisposable
{
    public TempDir()
    {
        Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "xboxos11-core-tests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Path);
    }

    public string Path { get; }

    public void Dispose()
    {
        try { Directory.Delete(Path, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }
}
