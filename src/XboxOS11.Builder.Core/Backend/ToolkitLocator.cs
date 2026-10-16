namespace XboxOS11.Builder.Core.Backend;

/// <summary>Where the PowerShell toolkit (modules, scripts, config, postinstall) and a PowerShell host live.</summary>
public sealed record ToolkitLocation(string Root, string PowerShellPath)
{
    public string ApiScript => Path.Combine(Root, "scripts", "Invoke-XboxOSBuilderApi.ps1");
    public string BuildScript => Path.Combine(Root, "scripts", "Invoke-XboxOSBuild.ps1");
    public bool IsWindowsPowerShell => Path.GetFileName(PowerShellPath).Equals("powershell.exe", StringComparison.OrdinalIgnoreCase);
}

public static class ToolkitLocator
{
    public const string ToolkitEnvironmentVariable = "XBOXOS11_TOOLKIT";

    public static bool IsToolkitRoot(string? path) =>
        !string.IsNullOrWhiteSpace(path)
        && File.Exists(Path.Combine(path, "config", "build.json"))
        && File.Exists(Path.Combine(path, "scripts", "Invoke-XboxOSBuilderApi.ps1"))
        && File.Exists(Path.Combine(path, "modules", "XboxOS.Build", "XboxOS.Build.psd1"));

    /// <summary>
    /// Search order: explicit override, <c>XBOXOS11_TOOLKIT</c>, a <c>toolkit</c> folder beside the app (release layout),
    /// then each ancestor of the app folder (development layout inside the repository).
    /// </summary>
    public static string? FindToolkitRoot(string appBaseDirectory, string? overridePath = null, Func<string, string?>? getEnvironment = null)
    {
        getEnvironment ??= Environment.GetEnvironmentVariable;
        foreach (var candidate in new[] { overridePath, getEnvironment(ToolkitEnvironmentVariable), Path.Combine(appBaseDirectory, "toolkit") })
        {
            if (IsToolkitRoot(candidate))
            {
                return Path.GetFullPath(candidate!);
            }
        }

        var dir = new DirectoryInfo(appBaseDirectory);
        while (dir is not null)
        {
            if (IsToolkitRoot(dir.FullName))
            {
                return dir.FullName;
            }

            dir = dir.Parent;
        }

        return null;
    }

    /// <summary>Prefers PowerShell 7 (pwsh.exe); falls back to inbox Windows PowerShell 5.1.</summary>
    public static string? FindPowerShell(Func<string, string?>? getEnvironment = null, Func<string, bool>? fileExists = null)
    {
        getEnvironment ??= Environment.GetEnvironmentVariable;
        fileExists ??= File.Exists;

        var path = getEnvironment("PATH") ?? string.Empty;
        foreach (var dir in path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var pwsh = Path.Combine(dir, "pwsh.exe");
            if (fileExists(pwsh))
            {
                return pwsh;
            }
        }

        var programFiles = getEnvironment("ProgramFiles");
        if (!string.IsNullOrEmpty(programFiles))
        {
            var pwsh7 = Path.Combine(programFiles, "PowerShell", "7", "pwsh.exe");
            if (fileExists(pwsh7))
            {
                return pwsh7;
            }
        }

        var systemRoot = getEnvironment("SystemRoot");
        if (!string.IsNullOrEmpty(systemRoot))
        {
            var winPs = Path.Combine(systemRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
            if (fileExists(winPs))
            {
                return winPs;
            }
        }

        return null;
    }

    public static ToolkitLocation Locate(string appBaseDirectory, string? overridePath = null)
    {
        var root = FindToolkitRoot(appBaseDirectory, overridePath)
            ?? throw new BackendException($"The XboxOS11 toolkit was not found. Place the 'toolkit' folder next to the app or set {ToolkitEnvironmentVariable}.");
        var ps = FindPowerShell() ?? throw new BackendException("PowerShell was not found. Install PowerShell 7 or enable Windows PowerShell.");
        return new ToolkitLocation(root, ps);
    }
}
