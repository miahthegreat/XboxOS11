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

function Get-XboxOSCanonicalPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'Path cannot be empty.'
    }

    $full = [System.IO.Path]::GetFullPath($Path)
    return $full.TrimEnd('\', '/')
}

function Test-XboxOSPathEqualsOrUnder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$ParentPath
    )

    $child = Get-XboxOSCanonicalPath -Path $Path
    $parent = Get-XboxOSCanonicalPath -Path $ParentPath

    if ($child.Equals($parent, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    $prefix = $parent + [System.IO.Path]::DirectorySeparatorChar
    return $child.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-XboxOSCloudSynchronizedPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $canonical = Get-XboxOSCanonicalPath -Path $Path
    $cloudRoots = New-Object System.Collections.Generic.List[string]

    foreach ($envName in @('OneDrive', 'OneDriveConsumer', 'OneDriveCommercial')) {
        $value = [Environment]::GetEnvironmentVariable($envName)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            try {
                $cloudRoots.Add((Get-XboxOSCanonicalPath -Path $value)) | Out-Null
            }
            catch {
                Write-Verbose "Ignoring invalid cloud root from $envName : $($_.Exception.Message)"
            }
        }
    }

    foreach ($root in ($cloudRoots | Select-Object -Unique)) {
        if (Test-XboxOSPathEqualsOrUnder -Path $canonical -ParentPath $root) {
            return $true
        }
    }

    # Path-segment heuristics for common sync roots when env vars are absent.
    $segments = $canonical -split '[\\/]'
    $cloudSegmentNames = @(
        'OneDrive'
        'Dropbox'
        'Google Drive'
        'GoogleDrive'
        'iCloudDrive'
        'Box'
        'Box Sync'
    )
    foreach ($segment in $segments) {
        foreach ($name in $cloudSegmentNames) {
            if ($segment.Equals($name, [System.StringComparison]::OrdinalIgnoreCase) -or
                $segment.StartsWith('OneDrive - ', [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
    }

    return $false
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

    # Absolute paths are independent of the process working directory.
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return Get-XboxOSCanonicalPath -Path $Path
    }

    return Get-XboxOSCanonicalPath -Path (Join-Path $BasePath $Path)
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
            else {
                $overlap = Assert-XboxOSDisableFeaturesManifestConsistency -Configuration $Configuration
                if (-not $overlap.Valid) {
                    foreach ($err in @($overlap.Errors)) {
                        $errors.Add($err) | Out-Null
                    }
                }
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

function Get-XboxOSIsoReleaseTag {
    <#
    .SYNOPSIS
        Derives an ISO release tag only from verified metadata.
    .NOTES
        Never infers 24H2/25H2 solely from an ISO filename such as 26300.9457.
    #>
    [CmdletBinding()]
    param(
        [string]$DisplayVersion,
        [string]$BuildNumber,
        [string]$ConfiguredRelease,
        [string]$UnverifiedFallback = 'buildunknown'
    )

    if (-not [string]::IsNullOrWhiteSpace($DisplayVersion) -and $DisplayVersion -match '^\d{2}H\d$') {
        return $DisplayVersion.ToUpperInvariant()
    }

    if (-not [string]::IsNullOrWhiteSpace($BuildNumber) -and $BuildNumber -match '^(\d+)(?:\.(\d+))?$') {
        $tag = "build$($Matches[1])"
        if ($Matches[2]) { $tag += ".$($Matches[2])" }
        return $tag
    }

    if (-not [string]::IsNullOrWhiteSpace($ConfiguredRelease) -and
        $ConfiguredRelease -notmatch '(?i)^(unverified|unknown|tbd|todo)$' -and
        $ConfiguredRelease -match '^\d{2}H\d$') {
        return $ConfiguredRelease.ToUpperInvariant()
    }

    return $UnverifiedFallback
}

function Get-XboxOSIsoFileName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Configuration,

        [string]$DisplayVersion,
        [string]$BuildNumber,
        [string]$Edition
    )

    $iso = $Configuration.iso
    if ($iso.PSObject.Properties.Name -contains 'fileName' -and -not [string]::IsNullOrWhiteSpace([string]$iso.fileName)) {
        return ConvertTo-XboxOSSafeFileName -Name ([string]$iso.fileName)
    }

    $fallback = 'buildunknown'
    if ($iso.PSObject.Properties.Name -contains 'unverifiedReleaseFallback' -and $iso.unverifiedReleaseFallback) {
        $fallback = [string]$iso.unverifiedReleaseFallback
    }

    $configuredRelease = $null
    if ($Configuration.PSObject.Properties.Name -contains 'target' -and
        $Configuration.target.PSObject.Properties.Name -contains 'release') {
        $configuredRelease = [string]$Configuration.target.release
    }

    $releaseTag = Get-XboxOSIsoReleaseTag -DisplayVersion $DisplayVersion -BuildNumber $BuildNumber -ConfiguredRelease $configuredRelease -UnverifiedFallback $fallback
    $template = 'XboxOS11-Win11Pro-{releaseTag}.iso'
    if ($iso.PSObject.Properties.Name -contains 'fileNameTemplate' -and $iso.fileNameTemplate) {
        $template = [string]$iso.fileNameTemplate
    }

    $editionTag = 'Win11Pro'
    if (-not [string]::IsNullOrWhiteSpace($Edition)) {
        if ($Edition -match 'Pro') { $editionTag = 'Win11Pro' }
        elseif ($Edition -match 'Home') { $editionTag = 'Win11Home' }
        elseif ($Edition -match 'Enterprise') { $editionTag = 'Win11Enterprise' }
    }

    $name = $template.Replace('{releaseTag}', $releaseTag).Replace('{editionTag}', $editionTag)
    return ConvertTo-XboxOSSafeFileName -Name $name
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
        [string]$RepoRoot,

        [string[]]$AdditionalPaths = @(),

        [switch]$AllowCloudSynchronizedPaths,

        [switch]$AllowRepositoryPaths
    )

    $repoFull = Get-XboxOSCanonicalPath -Path $RepoRoot
    $systemRoot = Get-XboxOSCanonicalPath -Path $env:SystemRoot
    $pathsToValidate = @($WorkspaceRoot) + @($AdditionalPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    $exactForbidden = @(
        (Get-XboxOSCanonicalPath -Path ($env:SystemDrive + '\'))
        (Get-XboxOSCanonicalPath -Path (Join-Path $env:SystemDrive 'Windows'))
        (Get-XboxOSCanonicalPath -Path (Join-Path $env:SystemDrive 'Program Files'))
        (Get-XboxOSCanonicalPath -Path (Join-Path $env:SystemDrive 'Program Files (x86)'))
        (Get-XboxOSCanonicalPath -Path (Join-Path $env:SystemDrive 'Users'))
    )

    foreach ($candidate in $pathsToValidate) {
        $full = Get-XboxOSCanonicalPath -Path $candidate

        if (Test-XboxOSPathEqualsOrUnder -Path $full -ParentPath $systemRoot) {
            throw "Refusing to use Windows system directory for build artifacts: $full"
        }

        foreach ($forbidden in $exactForbidden) {
            if ($full.Equals($forbidden, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Refusing unsafe build path root: $full"
            }
        }

        if (-not $AllowRepositoryPaths -and (Test-XboxOSPathEqualsOrUnder -Path $full -ParentPath $repoFull)) {
            throw "Refusing build path inside the Git repository ('$repoFull'): $full. Use an external workspace such as C:\XboxOS\Work."
        }

        if (-not $AllowCloudSynchronizedPaths -and (Test-XboxOSCloudSynchronizedPath -Path $full)) {
            throw "Refusing build path inside a cloud-synchronized folder (OneDrive/Dropbox/etc.): $full. Use a local non-synced path such as C:\XboxOS\Work."
        }
    }

    return $true
}

function Assert-XboxOSServicingPathSafety {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [string]$Purpose = 'image servicing'
    )

    $full = Get-XboxOSCanonicalPath -Path $Path
    if (Test-XboxOSPathEqualsOrUnder -Path $full -ParentPath $RepoRoot) {
        throw "Refusing $Purpose inside the Git repository: $full"
    }
    if (Test-XboxOSCloudSynchronizedPath -Path $full) {
        throw "Refusing $Purpose inside a cloud-synchronized folder: $full"
    }

    return $true
}

function Get-XboxOSInventoryAvailability {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Unknown', 'Empty', 'Available')]
        [string]$State,

        [AllowEmptyCollection()]
        [string[]]$Items = @()
    )

    switch ($State) {
        'Unknown' {
            return [pscustomobject]@{
                State       = 'Unknown'
                Items       = @()
                IsKnown     = $false
                CanEvaluate = $false
            }
        }
        'Empty' {
            return [pscustomobject]@{
                State       = 'Empty'
                Items       = @()
                IsKnown     = $true
                CanEvaluate = $true
            }
        }
        default {
            return [pscustomobject]@{
                State       = 'Available'
                Items       = @($Items)
                IsKnown     = $true
                CanEvaluate = $true
            }
        }
    }
}

function Assert-XboxOSPhaseOutcome {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Result,

        [Parameter(Mandatory)]
        [string]$PhaseName
    )

    if ($null -eq $Result) {
        return $true
    }

    $failed = @()
    if ($Result.PSObject.Properties.Name -contains 'Results' -and $null -ne $Result.Results) {
        $failed = @($Result.Results | Where-Object { $_.Status -eq 'Failed' })
    }
    elseif ($Result -is [System.Collections.IEnumerable] -and -not ($Result -is [string])) {
        $failed = @($Result | Where-Object { $_ -and ($_.PSObject.Properties.Name -contains 'Status') -and $_.Status -eq 'Failed' })
    }

    if ($failed.Count -gt 0) {
        $details = ($failed | ForEach-Object {
                $target = if ($_.PSObject.Properties.Name -contains 'Package' -and $_.Package) { $_.Package }
                elseif ($_.PSObject.Properties.Name -contains 'Feature' -and $_.Feature) { $_.Feature }
                elseif ($_.PSObject.Properties.Name -contains 'Candidate' -and $_.Candidate) { $_.Candidate }
                else { 'item' }
                "$target => $($_.Message)"
            }) -join '; '
        throw "Phase '$PhaseName' reported $($failed.Count) failed operation(s): $details"
    }

    if ($Result.PSObject.Properties.Name -contains 'Success' -and $Result.Success -eq $false) {
        $message = if ($Result.PSObject.Properties.Name -contains 'Message') { $Result.Message } else { 'Success=false' }
        throw "Phase '$PhaseName' reported failure: $message"
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

    $logsRoot = Resolve-XboxOSPath -Path ([string]$config.Raw.workspace.logs) -BasePath $config.RepoRoot
    $cacheRoot = Resolve-XboxOSPath -Path ([string]$config.Raw.workspace.cache) -BasePath $config.RepoRoot
    $tempRoot = Resolve-XboxOSPath -Path ([string]$config.Raw.workspace.temp) -BasePath $config.RepoRoot

    $null = Assert-XboxOSBuildSafety -WorkspaceRoot $workspaceRoot -RepoRoot $config.RepoRoot -AdditionalPaths @(
        $logsRoot
        $cacheRoot
        $tempRoot
        $outputRoot
    )

    $paths = [ordered]@{
        Workspace      = New-XboxOSDirectory -Path (Join-Path $workspaceRoot $buildId)
        SourceCopy     = $null
        Mount          = $null
        WorkingWim     = $null
        Logs           = New-XboxOSDirectory -Path $logsRoot
        Cache          = New-XboxOSDirectory -Path $cacheRoot
        Temp           = New-XboxOSDirectory -Path $tempRoot
        Output         = New-XboxOSDirectory -Path $outputRoot
        Reports        = $null
    }

    $paths.SourceCopy = New-XboxOSDirectory -Path (Join-Path $paths.Workspace 'source')
    $paths.Mount = New-XboxOSDirectory -Path (Join-Path $paths.Workspace 'mount')
    $paths.WorkingWim = Join-Path $paths.Workspace 'install.wim'
    $paths.Reports = New-XboxOSDirectory -Path (Join-Path $paths.Workspace 'reports')

    $null = Assert-XboxOSServicingPathSafety -Path $paths.Mount -RepoRoot $config.RepoRoot -Purpose 'WIM mount directory'
    $null = Assert-XboxOSServicingPathSafety -Path $paths.WorkingWim -RepoRoot $config.RepoRoot -Purpose 'working WIM path'

    $logFile = New-XboxOSLogger -LogDirectory $paths.Logs -BuildId $buildId -Level ([string]$config.Raw.logging.level)

    $context = [pscustomobject]@{
        BuildId               = $buildId
        DryRun                = [bool]$DryRun
        Configuration         = $config
        SourceISO             = (Resolve-XboxOSPath -Path $SourceISO)
        Paths                 = [pscustomobject]$paths
        LogFile               = $logFile
        SourceMeta            = $null
        MountedImagePath      = $null
        ImageMounted          = $false
        MountedIsoPath        = $null
        InventoryBefore       = $null
        InventoryAfter        = $null
        AppxInventoryState    = 'Unknown'
        FeatureInventoryState = 'Unknown'
        AppxInventory         = $null
        FeatureInventory      = $null
        Validation            = $null
        PhaseResults          = New-Object System.Collections.ArrayList
        StartedUtc            = (Get-Date).ToUniversalTime()
        CompletedUtc          = $null
        Success               = $false
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

    # Capture native exit code immediately; never treat a missing/nonzero code as success.
    $output = & $DismPath @ArgumentList 2>&1
    $exitCode = $LASTEXITCODE
    $text = @($output | ForEach-Object { "$_" })

    foreach ($line in $text) {
        Write-XboxOSLog -Level Debug -Message $line
    }

    if ($null -eq $exitCode) {
        throw "DISM did not return an exit code. Command: $display`n$($text -join "`n")"
    }

    if ([int]$exitCode -ne 0) {
        throw "DISM failed with exit code $exitCode. Command: $display`n$($text -join "`n")"
    }

    return [pscustomobject]@{
        ExitCode = [int]$exitCode
        Output   = $text
        Command  = $display
        DryRun   = $false
    }
}

function Assert-XboxOSDisableFeaturesManifestConsistency {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Configuration
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $never = @()
    if ($Configuration.PSObject.Properties['neverDisable'] -and $Configuration.neverDisable) {
        $never = @($Configuration.neverDisable | ForEach-Object { [string]$_ })
    }

    foreach ($candidate in @($Configuration.candidates)) {
        if (-not $candidate) { continue }
        $enabled = $true
        if ($candidate.PSObject.Properties['enabled']) {
            $enabled = [bool]$candidate.enabled
        }
        if (-not $enabled) { continue }

        foreach ($featureName in @($candidate.featureNames)) {
            $name = [string]$featureName
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            foreach ($pattern in $never) {
                if ($name -like $pattern) {
                    $errors.Add(("Enabled disable candidate '{0}' includes feature '{1}' which is also covered by neverDisable pattern '{2}'." -f $candidate.id, $name, $pattern)) | Out-Null
                }
            }
        }
    }

    return [pscustomobject]@{
        Valid  = ($errors.Count -eq 0)
        Errors = $errors.ToArray()
    }
}

function ConvertFrom-XboxOSDismPackageListOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Output
    )

    $packages = New-Object System.Collections.Generic.List[object]
    $current = $null
    foreach ($line in @($Output)) {
        if ($null -eq $line) { continue }
        $text = "$line"
        if ([string]::IsNullOrWhiteSpace($text)) { continue }

        if ($text -match '^\s*Package Identity\s*:\s*(.+)$') {
            if ($current) { $packages.Add([pscustomobject]$current) | Out-Null }
            $current = [ordered]@{
                Identity    = $Matches[1].Trim()
                State       = $null
                ReleaseType = $null
            }
            continue
        }

        if ($current) {
            if ($text -match '^\s*State\s*:\s*(.+)$') {
                $current.State = $Matches[1].Trim()
            }
            elseif ($text -match '^\s*Release Type\s*:\s*(.+)$') {
                $current.ReleaseType = $Matches[1].Trim()
            }
        }
    }
    if ($current) { $packages.Add([pscustomobject]$current) | Out-Null }

    return $packages.ToArray()
}

function ConvertFrom-XboxOSDismFeatureListOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Output
    )

    $features = New-Object System.Collections.Generic.List[object]
    $current = $null
    foreach ($line in @($Output)) {
        if ($null -eq $line) { continue }
        $text = "$line"
        if ([string]::IsNullOrWhiteSpace($text)) { continue }

        if ($text -match '^\s*Feature Name\s*:\s*(.+)$') {
            if ($current) { $features.Add([pscustomobject]$current) | Out-Null }
            $current = [ordered]@{
                Name  = $Matches[1].Trim()
                State = $null
            }
            continue
        }

        if ($current -and $text -match '^\s*State\s*:\s*(.+)$') {
            $current.State = $Matches[1].Trim()
        }
    }
    if ($current) { $features.Add([pscustomobject]$current) | Out-Null }

    return $features.ToArray()
}

function ConvertFrom-XboxOSDismProvisionedAppxListOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Output
    )

    $packages = New-Object System.Collections.Generic.List[object]
    $current = $null
    foreach ($line in @($Output)) {
        if ($null -eq $line) { continue }
        $text = "$line"
        if ([string]::IsNullOrWhiteSpace($text)) { continue }

        if ($text -match '^\s*DisplayName\s*:\s*(.+)$') {
            if ($current -and -not [string]::IsNullOrWhiteSpace([string]$current.PackageName)) {
                $packages.Add([pscustomobject]$current) | Out-Null
            }
            $current = [ordered]@{
                DisplayName  = $Matches[1].Trim()
                PackageName  = $null
                Version      = $null
                Architecture = $null
            }
            continue
        }

        if ($current) {
            if ($text -match '^\s*PackageName\s*:\s*(.+)$') {
                $current.PackageName = $Matches[1].Trim()
            }
            elseif ($text -match '^\s*Version\s*:\s*(.+)$') {
                $current.Version = $Matches[1].Trim()
            }
            elseif ($text -match '^\s*Architecture\s*:\s*(.+)$') {
                $current.Architecture = $Matches[1].Trim()
            }
        }
    }
    if ($current -and -not [string]::IsNullOrWhiteSpace([string]$current.PackageName)) {
        $packages.Add([pscustomobject]$current) | Out-Null
    }

    return $packages.ToArray()
}

function Get-XboxOSDismListedValues {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Output,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Label
    )

    $values = New-Object System.Collections.Generic.List[string]
    $pattern = '^\s*{0}\s*:\s*(.+)$' -f [regex]::Escape($Label)
    foreach ($line in @($Output)) {
        if ($null -eq $line) { continue }
        if ("$line" -match $pattern) {
            $values.Add($Matches[1].Trim()) | Out-Null
        }
    }

    # Emit to pipeline so callers can recollect with @() without nested arrays.
    return $values.ToArray()
}

function Test-XboxOSFeatureStateDisabled {
    [CmdletBinding()]
    param(
        [string]$State
    )

    if ([string]::IsNullOrWhiteSpace($State)) {
        return $false
    }

    # DISM uses "Disabled" and variants such as "Disabled with Payload Removed".
    return ($State -eq 'Disabled') -or ($State -like 'Disabled *')
}

function Get-XboxOSFeatureStateSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Features
    )

    $list = @($Features)
    $byState = [ordered]@{}
    $accounted = 0
    foreach ($feature in $list) {
        if ($null -eq $feature) { continue }
        $state = $null
        if ($feature -is [string]) {
            $state = '(name-only)'
        }
        elseif ($feature.PSObject.Properties['State']) {
            $state = [string]$feature.State
        }

        if ([string]::IsNullOrWhiteSpace($state)) {
            $state = '(unspecified)'
        }

        if (-not $byState.Contains($state)) {
            $byState[$state] = 0
        }
        $byState[$state] = [int]$byState[$state] + 1
        $accounted++
    }

    return [pscustomobject]@{
        Total     = $list.Count
        Accounted = $accounted
        Complete  = ($accounted -eq $list.Count)
        ByState   = [pscustomobject]$byState
    }
}

function New-XboxOSCompatibilityMatrix {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$AppxPackages,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Features,

        [Parameter(Mandatory)]
        [object]$RemoveAppsManifest,

        [Parameter(Mandatory)]
        [object]$DisableFeaturesManifest,

        [Parameter(Mandatory)]
        [object]$CompatibilityManifest
    )

    $protectedAppx = @(Get-XboxOSProtectedAppxPatterns -CompatibilityManifest $CompatibilityManifest)
    $neverDisable = @()
    if ($DisableFeaturesManifest.PSObject.Properties['neverDisable'] -and $DisableFeaturesManifest.neverDisable) {
        $neverDisable = @($DisableFeaturesManifest.neverDisable | ForEach-Object { [string]$_ })
    }
    $protectedFeaturePatterns = @()
    if ($CompatibilityManifest.PSObject.Properties['protectedFeatureNamePatterns'] -and $CompatibilityManifest.protectedFeatureNamePatterns) {
        $protectedFeaturePatterns = @($CompatibilityManifest.protectedFeatureNamePatterns | ForEach-Object { [string]$_ })
    }

    $featureNames = @(
        foreach ($feature in @($Features)) {
            if ($null -eq $feature) { continue }
            if ($feature -is [string]) { $feature }
            elseif ($feature.PSObject.Properties['Name']) { [string]$feature.Name }
        }
    )

    $appxRows = New-Object System.Collections.Generic.List[object]
    foreach ($candidate in @($RemoveAppsManifest.candidates)) {
        $enabled = $true
        if ($candidate.PSObject.Properties['enabled']) { $enabled = [bool]$candidate.enabled }
        $patterns = @($candidate.patterns | ForEach-Object { [string]$_ })

        $matchError = $null
        $matched = @()
        try {
            $matched = @(Resolve-XboxOSPackageMatches -Patterns $patterns -AvailablePackages @($AppxPackages) -RejectAmbiguous)
        }
        catch {
            $matchError = $_.Exception.Message
        }

        $status = 'Absent'
        $detail = 'No provisioned AppX identity matched the candidate patterns.'
        if ($matchError) {
            $status = 'Ambiguous'
            $detail = $matchError
        }
        elseif ($matched.Count -gt 0) {
            $protectedHits = @($matched | Where-Object { Test-XboxOSPackageProtected -PackageName $_ -ProtectedPatterns $protectedAppx })
            if ($protectedHits.Count -gt 0) {
                $status = 'Protected'
                $detail = 'Matched identities are protected; removal is not authorized from package-name prefixes alone.'
            }
            elseif (-not $enabled) {
                $status = 'Present'
                $detail = 'Present in inventory but candidate is disabled in remove-apps manifest.'
            }
            else {
                $status = 'Eligible'
                $detail = 'Present, unprotected, and enabled for consideration after explicit review.'
            }
        }

        $appxRows.Add([pscustomobject]@{
            Kind       = 'AppX'
            Candidate  = [string]$candidate.id
            Enabled    = $enabled
            Status     = $status
            Patterns   = $patterns
            Matches    = $matched
            Detail     = $detail
        }) | Out-Null
    }

    $featureRows = New-Object System.Collections.Generic.List[object]
    $overlap = Assert-XboxOSDisableFeaturesManifestConsistency -Configuration $DisableFeaturesManifest
    foreach ($err in @($overlap.Errors)) {
        $featureRows.Add([pscustomobject]@{
            Kind      = 'Feature'
            Candidate = 'ManifestConsistency'
            Enabled   = $true
            Status    = 'Conflicting'
            Feature   = $null
            State     = $null
            Detail    = $err
        }) | Out-Null
    }

    foreach ($candidate in @($DisableFeaturesManifest.candidates)) {
        $enabled = $true
        if ($candidate.PSObject.Properties['enabled']) { $enabled = [bool]$candidate.enabled }
        $resolved = @(Resolve-XboxOSFeatureMatches -FeatureNames @($candidate.featureNames) -AvailableFeatures $featureNames)

        foreach ($item in $resolved) {
            $state = $null
            if ($item.Resolved) {
                $hit = @($Features | Where-Object {
                        if ($_ -is [string]) { $_ -eq $item.Resolved }
                        else { $_.Name -eq $item.Resolved }
                    } | Select-Object -First 1)
                if ($hit.Count -eq 1 -and $hit[0] -isnot [string] -and $hit[0].PSObject.Properties['State']) {
                    $state = [string]$hit[0].State
                }
            }

            $status = 'Absent'
            $detail = 'Feature not present in inventory.'
            if ($item.Status -eq 'Exact' -and $item.Resolved) {
                $isNever = Test-XboxOSFeatureProtected -FeatureName $item.Resolved -NeverDisable $neverDisable
                $isCompatProtected = $false
                foreach ($pattern in $protectedFeaturePatterns) {
                    if ($item.Resolved -like $pattern) { $isCompatProtected = $true; break }
                }

                if ($isNever -or $isCompatProtected) {
                    if ($enabled) {
                        $status = 'Conflicting'
                        $detail = 'Present and listed as an enabled disable candidate while also protected/neverDisable.'
                    }
                    else {
                        $status = 'Protected'
                        $detail = 'Present and protected by neverDisable / compatibility policy.'
                    }
                }
                elseif (-not $enabled) {
                    $status = 'Present'
                    $detail = 'Present in inventory but candidate is disabled in disable-features manifest.'
                }
                elseif (Test-XboxOSFeatureStateDisabled -State $state) {
                    $status = 'AlreadyDisabled'
                    $detail = 'Configured disable candidate is already satisfied; future servicing should skip this feature.'
                }
                elseif ($state -eq 'Enabled') {
                    $status = 'Eligible'
                    $detail = 'Present, enabled, unprotected, and actionable for a future disable operation after explicit review.'
                }
                else {
                    $status = 'Present'
                    $detail = ("Present with DISM state '{0}'; not classified as an actionable disable without review." -f $(if ($state) { $state } else { '(unspecified)' }))
                }
            }

            $featureRows.Add([pscustomobject]@{
                Kind      = 'Feature'
                Candidate = [string]$candidate.id
                Enabled   = $enabled
                Status    = $status
                Feature   = $(if ($item.Resolved) { $item.Resolved } else { $item.Requested })
                State     = $state
                Detail    = $detail
            }) | Out-Null
        }
    }

    $rows = @($appxRows.ToArray() + $featureRows.ToArray())
    $summary = [ordered]@{
        present          = @($rows | Where-Object Status -eq 'Present').Count
        absent           = @($rows | Where-Object Status -eq 'Absent').Count
        protected        = @($rows | Where-Object Status -eq 'Protected').Count
        eligible         = @($rows | Where-Object Status -eq 'Eligible').Count
        alreadyDisabled  = @($rows | Where-Object Status -eq 'AlreadyDisabled').Count
        ambiguous        = @($rows | Where-Object Status -eq 'Ambiguous').Count
        conflicting      = @($rows | Where-Object Status -eq 'Conflicting').Count
    }

    return [pscustomobject]@{
        generatedUtc = (Get-Date).ToUniversalTime()
        summary      = [pscustomobject]$summary
        rows         = $rows
    }
}

function Format-XboxOSInventorySampleLines {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Items,

        [int]$Take = 25
    )

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Items | Select-Object -First $Take)) {
        if ($null -eq $item) { continue }
        if ($item -is [string]) {
            $lines.Add($item) | Out-Null
        }
        elseif ($item.PSObject.Properties['PackageName']) {
            $lines.Add([string]$item.PackageName) | Out-Null
        }
        elseif ($item.PSObject.Properties['Identity']) {
            $state = if ($item.PSObject.Properties['State'] -and $item.State) { " ($($item.State))" } else { '' }
            $lines.Add(('{0}{1}' -f $item.Identity, $state)) | Out-Null
        }
        elseif ($item.PSObject.Properties['Name']) {
            $state = if ($item.PSObject.Properties['State'] -and $item.State) { " ($($item.State))" } else { '' }
            $lines.Add(('{0}{1}' -f $item.Name, $state)) | Out-Null
        }
        else {
            $lines.Add([string]$item) | Out-Null
        }
    }
    return [string[]]$lines.ToArray()
}

function Get-XboxOSDismVersionFromOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Output,

        [Parameter(Mandatory)]
        [int]$ExitCode
    )

    if ($ExitCode -ne 0) {
        throw ("DISM version probe failed with exit code {0}." -f $ExitCode)
    }

    $versions = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($Output)) {
        if ($null -eq $line) { continue }
        $text = "$line"
        if ($text -match '^\s*Version\s*:\s*(\d+(?:\.\d+)+)\s*$') {
            $versions.Add($Matches[1]) | Out-Null
        }
    }

    if ($versions.Count -eq 0) {
        throw 'DISM version could not be reliably determined from command output.'
    }

    $unique = @($versions | Select-Object -Unique)
    if ($unique.Count -gt 1) {
        throw ("DISM version output is ambiguous; found multiple Version values: {0}" -f ($unique -join ', '))
    }

    return [string]$unique[0]
}

function Write-XboxOSCompatTestStatusMarker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$StatusPath,

        [Parameter(Mandatory)]
        [bool]$Success,

        [Parameter(Mandatory)]
        [int]$ExitCode,

        [hashtable]$Fields
    )

    $directory = Split-Path -Parent $StatusPath
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($StatusPath)
    $parent = if ([string]::IsNullOrWhiteSpace($directory)) { (Get-Location).Path } else { $directory }
    $succeededPath = Join-Path $parent ($baseName + '.succeeded')
    $failedPath = Join-Path $parent ($baseName + '.failed')
    $legacyDonePath = Join-Path $parent ($baseName + '.done')

    # Never leave a success-implying .done marker from prior runs of this status stem.
    if (Test-Path -LiteralPath $legacyDonePath) {
        Remove-Item -LiteralPath $legacyDonePath -Force
    }
    if (Test-Path -LiteralPath $succeededPath) {
        Remove-Item -LiteralPath $succeededPath -Force
    }
    if (Test-Path -LiteralPath $failedPath) {
        Remove-Item -LiteralPath $failedPath -Force
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $null = $lines.Add(('success={0}' -f $(if ($Success) { 'True' } else { 'False' })))
    $null = $lines.Add(('exitCode={0}' -f $ExitCode))
    $null = $lines.Add(('outcome={0}' -f $(if ($Success) { 'Succeeded' } else { 'Failed' })))
    if ($Fields) {
        foreach ($key in ($Fields.Keys | Sort-Object)) {
            $null = $lines.Add(('{0}={1}' -f $key, $Fields[$key]))
        }
    }

    ($lines -join [Environment]::NewLine) | Set-Content -LiteralPath $StatusPath -Encoding UTF8

    $outcomePath = if ($Success) { $succeededPath } else { $failedPath }
    @(
        ('success={0}' -f $(if ($Success) { 'True' } else { 'False' }))
        ('exitCode={0}' -f $ExitCode)
        ('statusFile={0}' -f $StatusPath)
    ) -join [Environment]::NewLine | Set-Content -LiteralPath $outcomePath -Encoding UTF8

    return [pscustomobject]@{
        StatusPath     = $StatusPath
        OutcomePath    = $outcomePath
        Success        = $Success
        ExitCode       = $ExitCode
        LegacyDonePath = $legacyDonePath
    }
}

function ConvertFrom-XboxOSDismImageInfoOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Output
    )

    $images = New-Object System.Collections.Generic.List[object]
    $current = $null
    $sawIndex = $false

    foreach ($line in @($Output)) {
        if ($null -eq $line) { continue }
        $text = "$line"
        if ([string]::IsNullOrWhiteSpace($text)) { continue }

        if ($text -match '^\s*Index\s*:\s*(\d+)\s*$') {
            if ($current) {
                if ([string]::IsNullOrWhiteSpace([string]$current.Name)) {
                    throw 'DISM image metadata could not be reliably parsed: an Index entry is missing a Name.'
                }
                $images.Add([pscustomobject]$current) | Out-Null
            }
            $current = [ordered]@{
                Index        = [int]$Matches[1]
                Name         = $null
                Description  = $null
                Size         = $null
                Architecture = $null
                Version      = $null
            }
            $sawIndex = $true
            continue
        }

        if ($current) {
            if ($text -match '^\s*Name\s*:\s*(.+)$') {
                $current.Name = $Matches[1].Trim()
            }
            elseif ($text -match '^\s*Description\s*:\s*(.+)$') {
                $current.Description = $Matches[1].Trim()
            }
            elseif ($text -match '^\s*Size\s*:\s*(.+)$') {
                $current.Size = $Matches[1].Trim()
            }
            elseif ($text -match '^\s*Architecture\s*:\s*(.+)$') {
                $current.Architecture = $Matches[1].Trim()
            }
            elseif ($text -match '^\s*Version\s*:\s*(.+)$') {
                $current.Version = $Matches[1].Trim()
            }
        }
    }

    if ($current) {
        if ([string]::IsNullOrWhiteSpace([string]$current.Name)) {
            throw 'DISM image metadata could not be reliably parsed: an Index entry is missing a Name.'
        }
        $images.Add([pscustomobject]$current) | Out-Null
    }

    if (-not $sawIndex) {
        throw 'DISM image metadata could not be reliably parsed: no Index entries were found.'
    }

    # Emit images to the pipeline so callers can safely recollect with @().
    return $images.ToArray()
}

function Resolve-XboxOSExactImageIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Images,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ExactName
    )

    $list = @($Images)
    if ($list.Count -eq 0) {
        throw "No Windows image indexes were available while resolving '$ExactName'."
    }

    foreach ($image in $list) {
        if ($null -eq $image) {
            throw 'DISM image metadata could not be reliably parsed: a null image entry was encountered.'
        }
        if ($null -eq $image.PSObject.Properties['Index'] -or $null -eq $image.Index) {
            throw 'DISM image metadata could not be reliably parsed: an image entry is missing Index.'
        }
        if ($null -eq $image.PSObject.Properties['Name'] -or [string]::IsNullOrWhiteSpace([string]$image.Name)) {
            throw 'DISM image metadata could not be reliably parsed: an image entry is missing Name.'
        }
    }

    $matched = @(
        $list | Where-Object {
            [string]::Equals([string]$_.Name.Trim(), $ExactName.Trim(), [System.StringComparison]::OrdinalIgnoreCase)
        }
    )

    if ($matched.Count -eq 0) {
        $available = ($list | ForEach-Object { '{0}:{1}' -f $_.Index, $_.Name }) -join '; '
        throw ("Exact image name '{0}' was not found among source indexes. Available: {1}" -f $ExactName, $available)
    }

    if ($matched.Count -gt 1) {
        $dupes = ($matched | ForEach-Object { '{0}:{1}' -f $_.Index, $_.Name }) -join '; '
        throw ("Exact image name '{0}' is ambiguous; matched {1} indexes: {2}" -f $ExactName, $matched.Count, $dupes)
    }

    $selected = $matched[0]
    $description = $null
    $size = $null
    $architecture = $null
    $version = $null
    if ($null -ne $selected.PSObject.Properties['Description']) { $description = $selected.Description }
    if ($null -ne $selected.PSObject.Properties['Size']) { $size = $selected.Size }
    if ($null -ne $selected.PSObject.Properties['Architecture']) { $architecture = $selected.Architecture }
    if ($null -ne $selected.PSObject.Properties['Version']) { $version = $selected.Version }

    return [pscustomobject]@{
        Index        = [int]$selected.Index
        Name         = [string]$selected.Name
        Description  = $description
        Size         = $size
        Architecture = $architecture
        Version      = $version
        MatchCount   = 1
        Available    = @(
            $list | ForEach-Object {
                [pscustomobject]@{
                    Index = [int]$_.Index
                    Name  = [string]$_.Name
                }
            }
        )
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
    return @(ConvertFrom-XboxOSDismImageInfoOutput -Output @($result.Output))
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
        [AllowEmptyCollection()]
        [string[]]$Patterns,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
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
        [AllowEmptyCollection()]
        [string[]]$FeatureNames,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
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
        return [object[]]@()
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

    return [object[]]$packages.ToArray()
}

function Find-XboxOSUpdatePackages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$UpdateDirectory
    )

    if (-not (Test-Path -LiteralPath $UpdateDirectory)) {
        return [object[]]@()
    }

    $files = @(Get-ChildItem -LiteralPath $UpdateDirectory -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @('.cab', '.msu') })

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

    return [object[]]@($packages)
}

function Get-XboxOSOrderedUpdatePackages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [object[]]$Packages
    )

    if ($null -eq $Packages -or @($Packages).Count -eq 0) {
        return [object[]]@()
    }

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

    # Cleanup may target an already-validated external workspace; still reject repo/cloud paths.
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

    $dismArgs = @('/Unmount-Image', "/MountDir:$MountPath")
    if ($Discard) {
        $dismArgs += '/Discard'
    }
    else {
        $dismArgs += '/Commit'
    }

    try {
        Invoke-XboxOSDism -DismPath $DismPath -ArgumentList $dismArgs -DryRun:$DryRun | Out-Null
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

. (Join-Path $PSScriptRoot 'ServicingPlan.ps1')
. (Join-Path $PSScriptRoot 'ExecutionSafety.ps1')
. (Join-Path $PSScriptRoot 'DisposableImagePreflight.ps1')
. (Join-Path $PSScriptRoot 'ServicingReadiness.ps1')
. (Join-Path $PSScriptRoot 'DisposableExperimentPlan.ps1')
. (Join-Path $PSScriptRoot 'IsolatedLab.ps1')
. (Join-Path $PSScriptRoot 'HostLabDiscovery.ps1')
. (Join-Path $PSScriptRoot 'AuthorizedHostDiscovery.ps1')
. (Join-Path $PSScriptRoot 'ControlledLiveDiscovery.ps1')
. (Join-Path $PSScriptRoot 'ImageCustomization.ps1')
. (Join-Path $PSScriptRoot 'BuilderProfile.ps1')

Export-ModuleMember -Function *
