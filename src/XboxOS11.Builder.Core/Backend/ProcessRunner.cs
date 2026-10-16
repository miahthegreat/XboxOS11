using System.Diagnostics;
using System.Text;

namespace XboxOS11.Builder.Core.Backend;

public sealed record ProcessResult(int ExitCode, IReadOnlyList<string> Lines);

/// <summary>Runs a process and streams each stdout/stderr line. Abstracted so tests never spawn PowerShell.</summary>
public interface IProcessRunner
{
    Task<ProcessResult> RunAsync(string fileName, IReadOnlyList<string> arguments, Action<string>? onLine, CancellationToken cancellationToken);
}

public sealed class ProcessRunner : IProcessRunner
{
    public async Task<ProcessResult> RunAsync(string fileName, IReadOnlyList<string> arguments, Action<string>? onLine, CancellationToken cancellationToken)
    {
        var psi = new ProcessStartInfo(fileName)
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var a in arguments)
        {
            psi.ArgumentList.Add(a);
        }

        using var process = new Process { StartInfo = psi, EnableRaisingEvents = true };
        var lines = new List<string>();
        var gate = new object();
        void Handle(string? data)
        {
            if (data is null)
            {
                return;
            }

            lock (gate)
            {
                lines.Add(data);
            }

            onLine?.Invoke(data);
        }

        process.OutputDataReceived += (_, e) => Handle(e.Data);
        process.ErrorDataReceived += (_, e) => Handle(e.Data);

        if (!process.Start())
        {
            throw new BackendException($"Failed to start {fileName}.");
        }

        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        try
        {
            await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            try
            {
                // Build-ISO's finally blocks discard any mounted image; killing the tree is the documented cancel path.
                process.Kill(entireProcessTree: true);
            }
            catch (InvalidOperationException)
            {
                // Already exited.
            }

            throw;
        }

        // Drain asynchronous readers.
        process.WaitForExit();
        lock (gate)
        {
            return new ProcessResult(process.ExitCode, lines.ToList());
        }
    }
}
