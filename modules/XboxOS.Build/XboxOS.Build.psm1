#Requires -Version 5.1
Set-StrictMode -Version Latest

$script:XboxOSLogFile = $null
$script:XboxOSLogLevel = 'Information'

$script:LogLevels = @{
    Trace       = 0
    Debug       = 1
    Information = 2
    Warning     = 3
    Error       = 4
}

function Get-XboxOSRepoRoot {
    [CmdletBinding()]
    param(
        [string]$StartPath = $PSScriptRoot
    )

    $currentPath = (Resolve-Path -LiteralPath $StartPath).Path
    while ($true) {
        $candidate = Join-Path $currentPath 'config\build.json'
        if (Test-Path -LiteralPath $candidate) {
            return $currentPath
        }

        $parent = Split-Path -Parent $currentPath
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $currentPath) {
            throw "Unable to locate XboxOS11 repository root from '$StartPath'."
        }

        $currentPath = $parent
    }
}

function Resolve-XboxOSPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [string]$BasePath
    )

    if ([string]::IsNullOrWhiteSpace($BasePath)) {
        $BasePath = Get-XboxOSRepoRoot
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $Path))
}

function New-XboxOSDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }

    return (Resolve-Path -LiteralPath $Path).Path
}

function Import-XboxOSManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $resolved = Resolve-XboxOSPath -Path $Path
    if (-not (Test-Path -LiteralPath $resolved)) {
        throw "Manifest not found: $resolved"
    }

    try {
        $raw = Get-Content -LiteralPath $resolved -Raw -Encoding UTF8
        $json = $raw | ConvertFrom-Json
    }
    catch {
        throw "Failed to parse JSON manifest '$resolved': $($_.Exception.Message)"
    }

    return $json
}

function Get-XboxOSRequiredConfigFields {
    [CmdletBinding()]
    param()

    return @(
        'project'
        'version'
        'target'
        'workspace'
        'paths'
        'safety'
        'phases'
        'iso'
    )
}

function Test-XboxOSManifestSchema {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Configuration,

        [string]$ManifestType = 'build'
    )

    $errors = New-Object System.Collections.Generic.List[string]

    switch ($ManifestType) {
        'build' {
            foreach ($field in (Get-XboxOSRequiredConfigFields)) {
                if (-not ($Configuration.PSObject.Properties.Name -contains $field)) {
                    $errors.Add("Missing required field: $field") | Out-Null
                }
            }

            if ($Configuration.PSObject.Properties.Name -contains 'target' -and $null -ne $Configuration.target) {
                foreach ($field in @('edition', 'architecture', 'windowsVersion')) {
                    if (-not ($Configuration.target.PSObject.Properties.Name -contains $field) -or
                        [string]::IsNullOrWhiteSpace([string]$Configuration.target.$field)) {
                        $errors.Add("target.$field is required") | Out-Null
                    }
                }
            }
        }
        'remove-apps' {
            if (-not $Configuration.candidates) {
                $errors.Add('remove-apps.json must include candidates[]') | Out-Null
            }
        }
        'disable-features' {
            if (-not $Configuration.candidates) {
                $errors.Add('disable-features.json must include candidates[]') | Out-Null
            }
        }
        'compatibility' {
            if (-not $Configuration.protectedAppxPatterns) {
                $errors.Add('compatibility.json must include protectedAppxPatterns[]') | Out-Null
            }
        }
        default {
            $errors.Add("Unknown manifest type: $ManifestType") | Out-Null
        }
    }

    return [pscustomobject]@{
        Valid  = ($errors.Count -eq 0)
        Errors = $errors.ToArray()
    }
}

function Get-XboxOSBuildConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $config = Import-XboxOSManifest -Path $Path
    $schema = Test-XboxOSManifestSchema -Configuration $config -ManifestType build
    if (-not $schema.Valid) {
        throw ("Invalid build configuration:`n - " + ($schema.Errors -join "`n - "))
    }

    $repoRoot = Get-XboxOSRepoRoot
    $resolvedPaths = @{}
    foreach ($prop in $config.paths.PSObject.Properties) {
        $resolvedPaths[$prop.Name] = Resolve-XboxOSPath -Path ([string]$prop.Value) -BasePath $repoRoot
    }

    return [pscustomobject]@{
        Raw          = $config
        Path         = (Resolve-XboxOSPath -Path $Path)
        RepoRoot     = $repoRoot
        ResolvedPath = $resolvedPaths
    }
}

function Test-XboxOSAdministrator {
    [CmdletBinding()]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-XboxOSWindowsHost {
    [CmdletBinding()]
    param()

    if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) {
        return $false
    }

    return $env:OS -eq 'Windows_NT'
}

function Find-XboxOSDism {
    [CmdletBinding()]
    param()

    $candidates = @(
        (Join-Path $env:SystemRoot 'System32\dism.exe')
        (Join-Path $env:SystemRoot 'SysWOW64\dism.exe')
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    $command = Get-Command dism.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    return $null
}

function Find-XboxOSAdkTools {
    [CmdletBinding()]
    param()

    $result = [ordered]@{
        AdkRoot      = $null
        Oscdimg      = $null
        DismAdk      = $null
        Imagex       = $null
        DeploymentTools = $null
        Found        = $false
        SearchNotes  = New-Object System.Collections.Generic.List[string]
    }

    $roots = New-Object System.Collections.Generic.List[string]
    $regPaths = @(
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots'
        'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots'
    )

    foreach ($regPath in $regPaths) {
        if (Test-Path -LiteralPath $regPath) {
            try {
                $item = Get-ItemProperty -LiteralPath $regPath -ErrorAction Stop
                foreach ($name in @('KitsRoot10', 'KitsRoot81', 'WindowsAppSdkDir')) {
                    if ($item.PSObject.Properties.Name -contains $name -and $item.$name) {
                        $roots.Add([string]$item.$name) | Out-Null
                        $result.SearchNotes.Add("Registry $regPath\$name => $($item.$name)") | Out-Null
                    }
                }
            }
            catch {
                $result.SearchNotes.Add("Failed reading $regPath : $($_.Exception.Message)") | Out-Null
            }
        }
    }

    $wellKnown = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\"
        "${env:ProgramFiles}\Windows Kits\10\"
        "${env:ProgramFiles(x86)}\Windows Kits\8.1\"
    )
    foreach ($path in $wellKnown) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            $roots.Add($path) | Out-Null
        }
    }

    $uniqueRoots = $roots | Select-Object -Unique
    foreach ($root in $uniqueRoots) {
        $deployment = Join-Path $root 'Assessment and Deployment Kit\Deployment Tools'
        if (-not (Test-Path -LiteralPath $deployment)) {
            continue
        }

        $result.AdkRoot = $root
        $result.DeploymentTools = $deployment

        $oscdimg = Get-ChildItem -LiteralPath $deployment -Recurse -Filter 'oscdimg.exe' -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($oscdimg) {
            $result.Oscdimg = $oscdimg.FullName
        }

        $dismAdk = Get-ChildItem -LiteralPath $deployment -Recurse -Filter 'dism.exe' -ErrorAction SilentlyContinue |
            Where-Object { $_.DirectoryName -match 'amd64|x86' } |
            Select-Object -First 1
        if ($dismAdk) {
            $result.DismAdk = $dismAdk.FullName
        }

        $imagex = Get-ChildItem -LiteralPath $deployment -Recurse -Filter 'imagex.exe' -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($imagex) {
            $result.Imagex = $imagex.FullName
        }

        break
    }

    $result.Found = [bool]$result.Oscdimg
    return [pscustomobject]$result
}

function Get-XboxOSDiskFreeBytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $full = Resolve-XboxOSPath -Path $Path
    $root = [System.IO.Path]::GetPathRoot($full)
    $drive = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -eq $root } | Select-Object -First 1
    if (-not $drive) {
        $letter = $root.Substring(0, 1)
        $drive = Get-PSDrive -Name $letter -ErrorAction SilentlyContinue
    }

    if (-not $drive) {
        throw "Unable to determine free space for path '$full'."
    }

    return [int64]$drive.Free
}

function Test-XboxOSWritablePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $directory = New-XboxOSDirectory -Path $Path
    $probe = Join-Path $directory ("xboxos-write-probe-{0}.tmp" -f [guid]::NewGuid().ToString('N'))
    try {
        Set-Content -LiteralPath $probe -Value 'ok' -Encoding ascii -Force
        return $true
    }
    catch {
        return $false
    }
    finally {
        if (Test-Path -LiteralPath $probe) {
            Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        }
    }
}

function New-XboxOSLogger {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LogDirectory,

        [string]$BuildId = (Get-Date -Format 'yyyyMMdd-HHmmss'),

        [ValidateSet('Trace', 'Debug', 'Information', 'Warning', 'Error')]
        [string]$Level = 'Information'
    )

    $dir = New-XboxOSDirectory -Path $LogDirectory
    $logFile = Join-Path $dir "XboxOS11-$BuildId.log"
    $script:XboxOSLogFile = $logFile
    $script:XboxOSLogLevel = $Level

    Write-XboxOSLog -Level Information -Message "Logging initialized: $logFile"
    return $logFile
}

function Write-XboxOSLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Trace', 'Debug', 'Information', 'Warning', 'Error')]
        [string]$Level,

        [Parameter(Mandatory)]
        [string]$Message,

        [hashtable]$Data
    )

    $current = $script:LogLevels[$script:XboxOSLogLevel]
    $incoming = $script:LogLevels[$Level]
    if ($incoming -lt $current) {
        return
    }

    $timestamp = Get-Date -Format 'o'
    $entry = [ordered]@{
        timestamp = $timestamp
        level     = $Level
        message   = $Message
    }
    if ($Data) {
        $entry.data = $Data
    }

    $line = ($entry | ConvertTo-Json -Compress -Depth 6)
    if ($script:XboxOSLogFile) {
        Add-Content -LiteralPath $script:XboxOSLogFile -Value $line -Encoding UTF8
    }

    switch ($Level) {
        'Warning' { Write-Warning $Message }
        'Error' {
            # Avoid Write-Error here: callers often use $ErrorActionPreference='Stop'.
            Write-Host "[Error] $Message" -ForegroundColor Red
        }
        default { Write-Host "[$Level] $Message" }
    }
}

function ConvertTo-XboxOSSafeFileName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $invalid = [regex]::Escape([string]::Join('', [System.IO.Path]::GetInvalidFileNameChars()))
    return ($Name -replace "[$invalid]", '_')
}

function Test-XboxOSArchitectureSupported {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Architecture
    )

    $normalized = $Architecture.ToLowerInvariant()
    return @('amd64', 'x64', 'arm64') -contains $normalized
}

function Get-XboxOSFileHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [ValidateSet('SHA256', 'SHA1', 'MD5')]
        [string]$Algorithm = 'SHA256'
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "File not found for hashing: $Path"
    }

    $hash = Get-FileHash -LiteralPath $Path -Algorithm $Algorithm
    return [pscustomobject]@{
        Path      = $Path
        Algorithm = $Algorithm
        Hash      = $hash.Hash
    }
}

function Assert-XboxOSBuildSafety {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory)]
        [string]$RepoRoot
    )

    $workspaceFull = [System.IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\')
    $repoFull = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\')
    $systemRoot = [System.IO.Path]::GetFullPath($env:SystemRoot).TrimEnd('\')

    if ($workspaceFull -eq $systemRoot -or $workspaceFull.StartsWith("$systemRoot\", [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to use Windows system directory as workspace: $workspaceFull"
    }

    $forbidden = @(
        $env:SystemDrive + '\'
        Join-Path $env:SystemDrive 'Windows'
        Join-Path $env:SystemDrive 'Program Files'
        Join-Path $env:SystemDrive 'Program Files (x86)'
        Join-Path $env:SystemDrive 'Users'
    ) | ForEach-Object { [System.IO.Path]::GetFullPath($_).TrimEnd('\') }

    foreach ($path in $forbidden) {
        if ($workspaceFull -eq $path) {
            throw "Refusing unsafe workspace root: $workspaceFull"
        }
    }

    if ($workspaceFull -eq $repoFull) {
        throw 'Workspace root must not be the repository root. Use artifacts/workspace or another isolated directory.'
    }

    return $true
}

function Test-XboxOSDryRunGuard {
    [CmdletBinding()]
    param(
        [switch]$DryRun,
        [string]$Action = 'modify image state'
    )

    if ($DryRun) {
        Write-XboxOSLog -Level Information -Message "DryRun: skipping $Action"
        return $true
    }

    return $false
}

function New-XboxOSBuildContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigurationPath,

        [Parameter(Mandatory)]
        [string]$SourceISO,

        [string]$OutputDirectory,

        [switch]$DryRun
    )

    $config = Get-XboxOSBuildConfiguration -Path $ConfigurationPath
    $buildId = Get-Date -Format 'yyyyMMdd-HHmmss'
    $workspaceRoot = Resolve-XboxOSPath -Path ([string]$config.Raw.workspace.root) -BasePath $config.RepoRoot
    if ($OutputDirectory) {
        $outputRoot = Resolve-XboxOSPath -Path $OutputDirectory -BasePath $config.RepoRoot
    }
    else {
        $outputRoot = Resolve-XboxOSPath -Path ([string]$config.Raw.workspace.output) -BasePath $config.RepoRoot
    }

    $null = Assert-XboxOSBuildSafety -WorkspaceRoot $workspaceRoot -RepoRoot $config.RepoRoot

    $paths = [ordered]@{
        Workspace      = New-XboxOSDirectory -Path (Join-Path $workspaceRoot $buildId)
        SourceCopy     = $null
        Mount          = $null
        WorkingWim     = $null
        Logs           = New-XboxOSDirectory -Path (Resolve-XboxOSPath -Path ([string]$config.Raw.workspace.logs) -BasePath $config.RepoRoot)
        Cache          = New-XboxOSDirectory -Path (Resolve-XboxOSPath -Path ([string]$config.Raw.workspace.cache) -BasePath $config.RepoRoot)
        Temp           = New-XboxOSDirectory -Path (Resolve-XboxOSPath -Path ([string]$config.Raw.workspace.temp) -BasePath $config.RepoRoot)
        Output         = New-XboxOSDirectory -Path $outputRoot
        Reports        = $null
    }

    $paths.SourceCopy = New-XboxOSDirectory -Path (Join-Path $paths.Workspace 'source')
    $paths.Mount = New-XboxOSDirectory -Path (Join-Path $paths.Workspace 'mount')
    $paths.WorkingWim = Join-Path $paths.Workspace 'install.wim'
    $paths.Reports = New-XboxOSDirectory -Path (Join-Path $paths.Workspace 'reports')

    $logFile = New-XboxOSLogger -LogDirectory $paths.Logs -BuildId $buildId -Level ([string]$config.Raw.logging.level)

    $context = [pscustomobject]@{
        BuildId           = $buildId
        DryRun            = [bool]$DryRun
        Configuration     = $config
        SourceISO         = (Resolve-XboxOSPath -Path $SourceISO)
        Paths             = [pscustomobject]$paths
        LogFile           = $logFile
        SourceMeta        = $null
        MountedImagePath  = $null
        MountedIsoPath    = $null
        InventoryBefore   = $null
        InventoryAfter    = $null
        Validation        = $null
        PhaseResults      = New-Object System.Collections.ArrayList
        StartedUtc        = (Get-Date).ToUniversalTime()
        CompletedUtc      = $null
        Success           = $false
    }

    Write-XboxOSLog -Level Information -Message "Build context created" -Data @{
        buildId = $buildId
        dryRun  = [bool]$DryRun
        workspace = $paths.Workspace
    }

    # Unary comma prevents PowerShell from enumerating/unwrapping the context object.
    return , $context
}

function Save-XboxOSBuildReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Context
    )

    $Context.CompletedUtc = (Get-Date).ToUniversalTime()
    $report = [ordered]@{
        project       = $Context.Configuration.Raw.project
        version       = $Context.Configuration.Raw.version
        buildId       = $Context.BuildId
        success       = $Context.Success
        dryRun        = $Context.DryRun
        startedUtc    = $Context.StartedUtc
        completedUtc  = $Context.CompletedUtc
        sourceIso     = $Context.SourceISO
        sourceMeta    = $Context.SourceMeta
        phases        = $Context.PhaseResults
        validation    = $Context.Validation
        logFile       = $Context.LogFile
        output        = $Context.Paths.Output
    }

    $jsonPath = Join-Path $Context.Paths.Reports 'BuildReport.json'
    $txtPath = Join-Path $Context.Paths.Reports 'BuildReport.txt'
    ($report | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $jsonPath -Encoding UTF8

    $lines = @(
        "XboxOS11 Build Report"
        "BuildId: $($Context.BuildId)"
        "Success: $($Context.Success)"
        "DryRun: $($Context.DryRun)"
        "SourceISO: $($Context.SourceISO)"
        "Log: $($Context.LogFile)"
        ''
        'Phases:'
    )
    foreach ($phase in $Context.PhaseResults) {
        $lines += " - $($phase.Name): $($phase.Status) ($($phase.Message))"
    }

    $lines | Set-Content -LiteralPath $txtPath -Encoding UTF8

    $publicJson = Join-Path $Context.Paths.Output ("BuildReport-{0}.json" -f $Context.BuildId)
    Copy-Item -LiteralPath $jsonPath -Destination $publicJson -Force

    Write-XboxOSLog -Level Information -Message "Build report saved" -Data @{ json = $jsonPath; text = $txtPath }
    return [pscustomobject]@{ Json = $jsonPath; Text = $txtPath; PublicJson = $publicJson }
}

function Invoke-XboxOSDism {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$ArgumentList,

        [string]$DismPath,

        [switch]$DryRun
    )

    if (-not $DismPath) {
        $DismPath = Find-XboxOSDism
    }
    if (-not $DismPath) {
        throw 'DISM was not found on this system.'
    }

    $display = "$DismPath $($ArgumentList -join ' ')"
    Write-XboxOSLog -Level Information -Message "DISM: $display"

    if (Test-XboxOSDryRunGuard -DryRun:$DryRun -Action $display) {
        return [pscustomobject]@{
            ExitCode = 0
            Output   = @("DryRun: $display")
            Command  = $display
            DryRun   = $true
        }
    }

    $output = & $DismPath @ArgumentList 2>&1
    $exitCode = $LASTEXITCODE
    $text = @($output | ForEach-Object { "$_" })

    foreach ($line in $text) {
        Write-XboxOSLog -Level Debug -Message $line
    }

    if ($exitCode -ne 0) {
        throw "DISM failed with exit code $exitCode. Command: $display`n$($text -join "`n")"
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $text
        Command  = $display
        DryRun   = $false
    }
}

function Get-XboxOSImageInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ImagePath,

        [string]$DismPath
    )

    if (-not (Test-Path -LiteralPath $ImagePath)) {
        throw "Image not found: $ImagePath"
    }

    if (-not $DismPath) {
        $DismPath = Find-XboxOSDism
    }

    $result = Invoke-XboxOSDism -DismPath $DismPath -ArgumentList @('/Get-ImageInfo', "/ImageFile:$ImagePath")
    $images = New-Object System.Collections.Generic.List[object]
    $current = $null

    foreach ($line in $result.Output) {
        if ($line -match '^\s*Index\s*:\s*(\d+)') {
            if ($current) { $images.Add([pscustomobject]$current) | Out-Null }
            $current = [ordered]@{ Index = [int]$Matches[1]; Name = $null; Description = $null; Size = $null; Architecture = $null }
        }
        elseif ($current) {
            if ($line -match '^\s*Name\s*:\s*(.+)$') { $current.Name = $Matches[1].Trim() }
            elseif ($line -match '^\s*Description\s*:\s*(.+)$') { $current.Description = $Matches[1].Trim() }
            elseif ($line -match '^\s*Size\s*:\s*(.+)$') { $current.Size = $Matches[1].Trim() }
            elseif ($line -match '^\s*Architecture\s*:\s*(.+)$') { $current.Architecture = $Matches[1].Trim() }
        }
    }
    if ($current) { $images.Add([pscustomobject]$current) | Out-Null }

    return $images.ToArray()
}

function Get-XboxOSProtectedAppxPatterns {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$CompatibilityManifest
    )

    return @($CompatibilityManifest.protectedAppxPatterns)
}

function Test-XboxOSPackageProtected {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PackageName,

        [Parameter(Mandatory)]
        [string[]]$ProtectedPatterns
    )

    foreach ($pattern in $ProtectedPatterns) {
        if ($PackageName -like $pattern) {
            return $true
        }
    }

    return $false
}

function Resolve-XboxOSPackageMatches {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Patterns,

        [Parameter(Mandatory)]
        [string[]]$AvailablePackages,

        [switch]$RejectAmbiguous
    )

    $resolvedPackages = New-Object System.Collections.Generic.List[string]
    foreach ($pattern in $Patterns) {
        $hit = @($AvailablePackages | Where-Object { $_ -like $pattern } | Select-Object -Unique)
        if ($hit.Count -eq 0) {
            continue
        }
        if ($RejectAmbiguous -and $hit.Count -gt 1 -and ($pattern.Contains('*') -or $pattern.Contains('?'))) {
            throw "Ambiguous package match for pattern '$pattern': $($hit -join ', ')"
        }
        foreach ($item in $hit) {
            if (-not $resolvedPackages.Contains($item)) {
                $resolvedPackages.Add($item) | Out-Null
            }
        }
    }

    return [string[]]$resolvedPackages.ToArray()
}

function Resolve-XboxOSFeatureMatches {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$FeatureNames,

        [Parameter(Mandatory)]
        [string[]]$AvailableFeatures
    )

    $resolved = New-Object System.Collections.Generic.List[object]
    foreach ($name in $FeatureNames) {
        $exact = @($AvailableFeatures | Where-Object { $_ -eq $name })
        if ($exact.Count -eq 1) {
            $resolved.Add([pscustomobject]@{ Requested = $name; Resolved = $exact[0]; Status = 'Exact' }) | Out-Null
        }
        else {
            $resolved.Add([pscustomobject]@{ Requested = $name; Resolved = $null; Status = 'Absent' }) | Out-Null
        }
    }

    return $resolved.ToArray()
}

function Test-XboxOSFeatureProtected {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FeatureName,

        [string[]]$NeverDisable = @()
    )

    foreach ($pattern in $NeverDisable) {
        if ($FeatureName -like $pattern) {
            return $true
        }
    }

    $core = @(
        'Microsoft-Windows-Subsystem*'
        'NetFx*'
        'MediaPlayback'
        'WindowsMediaPlayer'
        'DirectPlay'
        'Containers*'
        'HypervisorPlatform'
        'VirtualMachinePlatform'
    )
    foreach ($pattern in $core) {
        if ($FeatureName -like $pattern) {
            return $true
        }
    }

    return $false
}

function Find-XboxOSDriverPackages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DriverDirectory,

        [object]$DriversManifest,

        [switch]$Recursive
    )

    if (-not (Test-Path -LiteralPath $DriverDirectory)) {
        return @()
    }

    $recurse = $Recursive -or ($DriversManifest -and $DriversManifest.recursive)
    $files = Get-ChildItem -LiteralPath $DriverDirectory -Filter '*.inf' -File -Recurse:$recurse -ErrorAction SilentlyContinue
    $reject = @()
    if ($DriversManifest -and $DriversManifest.rejectPatterns) {
        $reject = @($DriversManifest.rejectPatterns)
    }

    $packages = New-Object System.Collections.Generic.List[object]
    foreach ($file in $files) {
        $rejected = $false
        foreach ($pattern in $reject) {
            if ($file.FullName -like $pattern -or $file.Name -like $pattern) {
                $rejected = $true
                break
            }
        }

        $content = Get-Content -LiteralPath $file.FullName -TotalCount 40 -ErrorAction SilentlyContinue
        $looksLikeInf = $false
        foreach ($line in $content) {
            if ($line -match '\[Version\]' -or $line -match 'Signature\s*=' -or $line -match 'ClassGuid\s*=') {
                $looksLikeInf = $true
                break
            }
        }

        $packages.Add([pscustomobject]@{
            Path       = $file.FullName
            Name       = $file.Name
            ValidInf   = $looksLikeInf
            Rejected   = $rejected
            Reason     = $(if ($rejected) { 'Matched rejectPatterns / installer package' } elseif (-not $looksLikeInf) { 'Does not look like a driver INF' } else { 'OK' })
        }) | Out-Null
    }

    return $packages.ToArray()
}

function Find-XboxOSUpdatePackages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$UpdateDirectory
    )

    if (-not (Test-Path -LiteralPath $UpdateDirectory)) {
        return @()
    }

    $files = Get-ChildItem -LiteralPath $UpdateDirectory -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @('.cab', '.msu') }

    $packages = foreach ($file in $files) {
        $kind = if ($file.Name -match 'SSU|ServicingStack') { 'ServicingStack'
        } elseif ($file.Name -match 'LCU|Cumulative') { 'Cumulative'
        } elseif ($file.Name -match 'DotNet|NDP') { 'DotNet'
        } elseif ($file.Name -match 'SafeOS|WinRE') { 'SafeOS'
        } else { 'Other' }

        [pscustomobject]@{
            Path     = $file.FullName
            Name     = $file.Name
            Extension = $file.Extension
            Kind     = $kind
            SizeBytes = $file.Length
        }
    }

    return @($packages)
}

function Get-XboxOSOrderedUpdatePackages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Packages
    )

    $rank = @{
        ServicingStack = 0
        SafeOS         = 1
        Cumulative     = 2
        DotNet         = 3
        Other          = 4
    }

    return @(
        $Packages | Sort-Object @{ Expression = { $rank[$_.Kind] } }, Name
    )
}

function New-XboxOSIsoBootData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourceTree
    )

    $etfsboot = Join-Path $SourceTree 'boot\etfsboot.com'
    $efisys = Join-Path $SourceTree 'efi\microsoft\boot\efisys.bin'

    if (-not (Test-Path -LiteralPath $etfsboot)) {
        throw "Missing BIOS/UEFI hybrid boot file: $etfsboot"
    }
    if (-not (Test-Path -LiteralPath $efisys)) {
        throw "Missing UEFI boot file: $efisys"
    }

    return "-bootdata:2#p0,e,b$etfsboot#pEF,e,b$efisys"
}

function Clear-XboxOSWorkspace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WorkspacePath,

        [switch]$PreserveReports
    )

    if (-not (Test-Path -LiteralPath $WorkspacePath)) {
        return
    }

    Assert-XboxOSBuildSafety -WorkspaceRoot $WorkspacePath -RepoRoot (Get-XboxOSRepoRoot)

    if ($PreserveReports) {
        Get-ChildItem -LiteralPath $WorkspacePath -Force |
            Where-Object { $_.Name -ne 'reports' } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    else {
        Remove-Item -LiteralPath $WorkspacePath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-XboxOSMountCleanup {
    [CmdletBinding()]
    param(
        [string]$MountPath,
        [string]$DismPath,
        [switch]$Discard,
        [switch]$DryRun
    )

    if (-not $MountPath -or -not (Test-Path -LiteralPath $MountPath)) {
        return
    }

    $hasContent = @(Get-ChildItem -LiteralPath $MountPath -Force -ErrorAction SilentlyContinue).Count -gt 0
    if (-not $hasContent) {
        return
    }

    $args = @('/Unmount-Image', "/MountDir:$MountPath")
    if ($Discard) {
        $args += '/Discard'
    }
    else {
        $args += '/Commit'
    }

    try {
        Invoke-XboxOSDism -DismPath $DismPath -ArgumentList $args -DryRun:$DryRun | Out-Null
    }
    catch {
        Write-XboxOSLog -Level Warning -Message "Mount cleanup failed: $($_.Exception.Message)"
        try {
            Invoke-XboxOSDism -DismPath $DismPath -ArgumentList @('/Cleanup-Mountpoints') -DryRun:$DryRun | Out-Null
        }
        catch {
            Write-XboxOSLog -Level Warning -Message "Cleanup-Mountpoints failed: $($_.Exception.Message)"
        }
    }
}

Export-ModuleMember -Function *
