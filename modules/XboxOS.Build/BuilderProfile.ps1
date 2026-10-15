# Milestone 7 - Builder backend: presets, reusable build profiles, validation, component review,
# safe unattend generation, effective build configuration, and a JSON event protocol for the
# native XboxOS11 Builder frontend. Profiles can express only supported, documented customization:
# there are no fields for TPM/Secure Boot/RAM bypasses, network-requirement bypasses, security
# feature removal, product keys, or automatic disk wiping.

$script:XboxOSBuilderEngineVersion = '7.0.0'
$script:XboxOSBuildProfileSchemaVersion = 'xboxos-build-profile-v1'
$script:XboxOSBuilderPresetSchemaVersion = 'xboxos-builder-preset-v1'
$script:XboxOSBuilderEventPrefix = 'XBOXOS-EVENT '
$script:XboxOSBuilderLaunchers = @('Xbox', 'Steam', 'BattleNet', 'EA', 'Ubisoft', 'Epic')
$script:XboxOSBuilderForbiddenSettingPattern = '(?i)tpm|secureboot|bypass|labconfig|nro|ramcheck|storagecheck|cpucheck|defender|smartscreen|uac|productkey|diskconfiguration|wipedisk|activation'

$script:XboxOSBuildProfileShape = [ordered]@{
    ''                 = @('schemaVersion', 'name', 'description', 'presetId', 'source', 'apps', 'features', 'drivers', 'updates', 'setup', 'output')
    'source'           = @('isoPath', 'editionPattern', 'imageIndex')
    'apps'             = @('remove')
    'features'         = @('disable')
    'drivers'          = @('enabled', 'directory')
    'updates'          = @('enabled', 'directory')
    'setup'            = @('unattend', 'uiLanguage', 'inputLocale', 'systemLocale', 'userLocale', 'timeZone', 'hideEula', 'privacy', 'startupToGamingHome', 'postInstall')
    'setup.postInstall' = @('enabled', 'gameMode', 'hardwareAcceleratedGpuScheduling', 'launchers')
    'output'           = @('directory', 'isoLabel')
}

# Keys added after v1 shipped: accepted when present, never required, so older v1 profiles stay valid.
$script:XboxOSBuildProfileOptionalKeys = @{
    'setup.postInstall' = @('optimizations')
}

function Get-XboxOSBuilderEngineVersion { return $script:XboxOSBuilderEngineVersion }
function Get-XboxOSBuildProfileSchemaVersion { return $script:XboxOSBuildProfileSchemaVersion }
function Get-XboxOSBuilderEventPrefix { return $script:XboxOSBuilderEventPrefix }
function Get-XboxOSBuilderLauncherCatalog { return [string[]]$script:XboxOSBuilderLaunchers }

function Write-XboxOSBuilderEvent {
    <#
    .SYNOPSIS
      Emits one machine-readable progress event line (prefix + compact JSON) for the Builder frontend.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('started', 'validation', 'phase', 'log', 'completed', 'failed')][string]$Type,
        [hashtable]$Data = @{}
    )

    $doc = [ordered]@{ type = $Type; utc = [datetime]::UtcNow.ToString('o') }
    foreach ($k in ($Data.Keys | Sort-Object)) { $doc[$k] = $Data[$k] }
    $line = $script:XboxOSBuilderEventPrefix + ($doc | ConvertTo-Json -Compress -Depth 8)
    Write-Host $line
    return $line
}

function ConvertFrom-XboxOSBuilderEventLine {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)

    if (-not $Line.StartsWith($script:XboxOSBuilderEventPrefix)) { return $null }
    return ($Line.Substring($script:XboxOSBuilderEventPrefix.Length) | ConvertFrom-Json)
}

#region Gaming optimizations catalog

function Get-XboxOSGamingTweakCatalog {
    [CmdletBinding()]
    param([string]$RepoRoot = $null)

    if (-not $RepoRoot) { $RepoRoot = Get-XboxOSRepoRoot }
    $catalog = Get-Content -LiteralPath (Join-Path $RepoRoot 'config\gaming-tweaks.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$catalog.schemaVersion -ne 'xboxos-gaming-tweaks-v1') {
        throw ("Unsupported gaming tweak catalog '{0}'." -f $catalog.schemaVersion)
    }
    return $catalog
}

#endregion

#region Presets

function Get-XboxOSBuilderPreset {
    [CmdletBinding()]
    param(
        [string]$Id = '',
        [string]$RepoRoot = $null
    )

    if (-not $RepoRoot) { $RepoRoot = Get-XboxOSRepoRoot }
    $dir = Join-Path $RepoRoot 'config\presets'
    $presets = New-Object System.Collections.Generic.List[object]
    foreach ($file in @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File | Sort-Object Name)) {
        $p = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$p.schemaVersion -ne $script:XboxOSBuilderPresetSchemaVersion) {
            throw ("Preset {0} has unexpected schema '{1}'." -f $file.Name, $p.schemaVersion)
        }
        [void]$presets.Add($p)
    }
    $ordered = @($presets.ToArray() | Sort-Object -Property @{ Expression = { [int]$_.order } }, id)
    if ($Id) {
        $match = @($ordered | Where-Object { [string]$_.id -eq $Id })
        if ($match.Count -ne 1) { throw ("Unknown builder preset '{0}'." -f $Id) }
        return $match[0]
    }
    return $ordered
}

#endregion

#region Profile creation, import/export

function Copy-XboxOSJsonObject {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Value)
    return ($Value | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
}

function New-XboxOSBuildProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$PresetId = 'gaming-balanced',
        [string]$SourceIso = '',
        [string]$OutputDirectory = '',
        [string]$RepoRoot = $null
    )

    $preset = Get-XboxOSBuilderPreset -Id $PresetId -RepoRoot $RepoRoot
    $BuildProfile = Copy-XboxOSJsonObject -Value $preset.profile
    $BuildProfile | Add-Member -NotePropertyName schemaVersion -NotePropertyValue $script:XboxOSBuildProfileSchemaVersion -Force
    $BuildProfile | Add-Member -NotePropertyName name -NotePropertyValue $Name -Force
    $BuildProfile | Add-Member -NotePropertyName description -NotePropertyValue ([string]$preset.description) -Force
    $BuildProfile | Add-Member -NotePropertyName presetId -NotePropertyValue ([string]$preset.id) -Force
    if ($SourceIso) { $BuildProfile.source.isoPath = $SourceIso }
    if ($OutputDirectory) { $BuildProfile.output.directory = $OutputDirectory }
    return ConvertTo-XboxOSOrderedBuildProfile -BuildProfile $BuildProfile
}

function ConvertTo-XboxOSOrderedBuildProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$BuildProfile)

    $o = [ordered]@{}
    foreach ($k in $script:XboxOSBuildProfileShape['']) {
        if ($BuildProfile.PSObject.Properties[$k]) { $o[$k] = $BuildProfile.$k }
    }
    return ([pscustomobject]$o | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
}

function Export-XboxOSBuildProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$BuildProfile,
        [Parameter(Mandatory)][string]$Path
    )

    $check = Test-XboxOSBuildProfile -BuildProfile $BuildProfile
    if (-not $check.valid) {
        throw ("Refusing to save an invalid build profile:`n - " + ($check.errors -join "`n - "))
    }
    $full = [System.IO.Path]::GetFullPath($Path)
    $dir = Split-Path -Parent $full
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    ((ConvertTo-XboxOSOrderedBuildProfile -BuildProfile $BuildProfile) | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $full -Encoding UTF8
    return $full
}

function Import-XboxOSBuildProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { throw "Build profile not found: $Path" }
    try {
        return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        throw ("Build profile is not valid JSON: {0}" -f $_.Exception.Message)
    }
}

function Get-XboxOSBuildProfileHash {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$BuildProfile)
    return Get-XboxOSUtf8Sha256Hex -Text (ConvertTo-XboxOSCanonicalJson -Value (ConvertTo-XboxOSOrderedBuildProfile -BuildProfile $BuildProfile))
}

#endregion

#region Validation and review

function Get-XboxOSBuilderManifestSet {
    [CmdletBinding()]
    param([string]$RepoRoot = $null)

    if (-not $RepoRoot) { $RepoRoot = Get-XboxOSRepoRoot }
    return [pscustomobject]@{
        RepoRoot        = $RepoRoot
        Build           = Import-XboxOSManifest -Path (Join-Path $RepoRoot 'config\build.json')
        RemoveApps      = Import-XboxOSManifest -Path (Join-Path $RepoRoot 'config\remove-apps.json')
        DisableFeatures = Import-XboxOSManifest -Path (Join-Path $RepoRoot 'config\disable-features.json')
        Drivers         = Import-XboxOSManifest -Path (Join-Path $RepoRoot 'config\drivers.json')
        Compatibility   = Import-XboxOSManifest -Path (Join-Path $RepoRoot 'config\compatibility.json')
    }
}

function Test-XboxOSAppCandidateProtected {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Candidate, [Parameter(Mandatory)][string[]]$ProtectedPatterns)

    foreach ($pattern in @($Candidate.patterns)) {
        $probe = ([string]$pattern).TrimEnd('*')
        foreach ($protectedPattern in $ProtectedPatterns) {
            if ($probe -like $protectedPattern -or $protectedPattern.TrimEnd('*') -like ([string]$pattern)) { return $true }
        }
    }
    return $false
}

function Test-XboxOSBuildProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$BuildProfile,
        [string]$RepoRoot = $null,
        [switch]$ForBuild
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $m = Get-XboxOSBuilderManifestSet -RepoRoot $RepoRoot

    # Shape: required sections present, unknown keys rejected (so unsupported bypass settings cannot be expressed).
    foreach ($section in $script:XboxOSBuildProfileShape.Keys) {
        $node = $BuildProfile
        if ($section) {
            foreach ($part in $section.Split('.')) {
                $node = if ($null -ne $node -and $node.PSObject.Properties[$part]) { $node.$part } else { $null }
            }
        }
        $label = if ($section) { $section } else { '(root)' }
        if ($null -eq $node -or $node -isnot [pscustomobject]) {
            [void]$errors.Add(("Profile section '{0}' is missing or not an object." -f $label))
            continue
        }
        $allowed = $script:XboxOSBuildProfileShape[$section]
        $optional = @()
        if ($script:XboxOSBuildProfileOptionalKeys.ContainsKey($section)) { $optional = @($script:XboxOSBuildProfileOptionalKeys[$section]) }
        foreach ($p in $node.PSObject.Properties) {
            if ($allowed -notcontains $p.Name -and $optional -notcontains $p.Name) {
                if ($p.Name -match $script:XboxOSBuilderForbiddenSettingPattern) {
                    [void]$errors.Add(("Unsupported setting '{0}.{1}': XboxOS11 never bypasses Windows requirements, security features, activation, or disk selection." -f $label, $p.Name))
                }
                else {
                    [void]$errors.Add(("Unknown profile setting '{0}.{1}'." -f $label, $p.Name))
                }
            }
        }
        foreach ($req in $allowed) {
            if (-not $node.PSObject.Properties[$req]) { [void]$errors.Add(("Profile setting '{0}.{1}' is required." -f $label, $req)) }
        }
    }
    if ($errors.Count -gt 0) {
        return [pscustomobject]@{ valid = $false; errors = [string[]]@($errors.ToArray()); warnings = [string[]]@($warnings.ToArray()) }
    }

    if ([string]$BuildProfile.schemaVersion -ne $script:XboxOSBuildProfileSchemaVersion) {
        [void]$errors.Add(("Profile schemaVersion must be '{0}'." -f $script:XboxOSBuildProfileSchemaVersion))
    }
    if ([string]$BuildProfile.name -notmatch '^[A-Za-z0-9][A-Za-z0-9 _.\-]{0,63}$') {
        [void]$errors.Add('Profile name must be 1-64 characters: letters, digits, space, underscore, dot, or hyphen.')
    }

    # Source
    $iso = [string]$BuildProfile.source.isoPath
    if ($ForBuild -and [string]::IsNullOrWhiteSpace($iso)) {
        [void]$errors.Add('Select a Windows 11 ISO (source.isoPath).')
    }
    if (-not [string]::IsNullOrWhiteSpace($iso)) {
        if ([System.IO.Path]::GetExtension($iso) -ne '.iso') { [void]$errors.Add('source.isoPath must be an .iso file.') }
        elseif ($ForBuild -and -not (Test-Path -LiteralPath $iso -PathType Leaf)) { [void]$errors.Add(("Source ISO not found: {0}" -f $iso)) }
    }
    if ([string]::IsNullOrWhiteSpace([string]$BuildProfile.source.editionPattern)) {
        [void]$errors.Add('source.editionPattern is required (for example *Pro*).')
    }
    elseif ([string]$BuildProfile.source.editionPattern -notmatch '(?i)pro') {
        [void]$warnings.Add('XboxOS11 is validated against Windows 11 Pro; other editions are untested.')
    }
    if ($null -ne $BuildProfile.source.imageIndex -and ([string]$BuildProfile.source.imageIndex -notmatch '^[1-9][0-9]?$')) {
        [void]$errors.Add('source.imageIndex must be null or an integer 1-99.')
    }

    # Apps
    $protected = Get-XboxOSProtectedAppxPatterns -CompatibilityManifest $m.Compatibility
    $appIds = @($m.RemoveApps.candidates | ForEach-Object { [string]$_.id })
    $selectedApps = @($BuildProfile.apps.remove)
    if (@($selectedApps | Select-Object -Unique).Count -ne $selectedApps.Count) { [void]$errors.Add('apps.remove contains duplicates.') }
    foreach ($id in $selectedApps) {
        if ($appIds -notcontains [string]$id) { [void]$errors.Add(("Unknown app removal candidate '{0}'." -f $id)); continue }
        $cand = @($m.RemoveApps.candidates | Where-Object { [string]$_.id -eq [string]$id })[0]
        if (Test-XboxOSAppCandidateProtected -Candidate $cand -ProtectedPatterns $protected) {
            [void]$errors.Add(("App '{0}' is a protected gaming/platform dependency and cannot be removed." -f $id))
        }
        if ([string]$id -eq 'Copilot') { [void]$warnings.Add('Removing Copilot consumer packages: verify Store and Xbox app behavior after installation.') }
    }

    # Features
    $featureIds = @($m.DisableFeatures.candidates | ForEach-Object { [string]$_.id })
    $selectedFeatures = @($BuildProfile.features.disable)
    if (@($selectedFeatures | Select-Object -Unique).Count -ne $selectedFeatures.Count) { [void]$errors.Add('features.disable contains duplicates.') }
    foreach ($id in $selectedFeatures) {
        if ($featureIds -notcontains [string]$id) { [void]$errors.Add(("Unknown feature candidate '{0}'." -f $id)); continue }
        $cand = @($m.DisableFeatures.candidates | Where-Object { [string]$_.id -eq [string]$id })[0]
        foreach ($fn in @($cand.featureNames)) {
            foreach ($never in @($m.DisableFeatures.neverDisable)) {
                if ([string]$fn -like [string]$never) { [void]$errors.Add(("Feature '{0}' is protected and cannot be disabled." -f $fn)) }
            }
        }
    }

    # Drivers / updates
    foreach ($kind in @('drivers', 'updates')) {
        $node = $BuildProfile.$kind
        if ($node.enabled -isnot [bool]) { [void]$errors.Add(("{0}.enabled must be true or false." -f $kind)) }
        if ([bool]$node.enabled) {
            $dir = [string]$node.directory
            if ([string]::IsNullOrWhiteSpace($dir)) { [void]$errors.Add(("{0}.directory is required when enabled." -f $kind)) }
            elseif ($ForBuild -and -not (Test-Path -LiteralPath $dir -PathType Container)) { [void]$errors.Add(("{0} directory not found: {1}" -f $kind, $dir)) }
        }
    }
    if ([bool]$BuildProfile.drivers.enabled -and $ForBuild -and (Test-Path -LiteralPath ([string]$BuildProfile.drivers.directory) -PathType Container)) {
        $installers = @(Get-ChildItem -LiteralPath ([string]$BuildProfile.drivers.directory) -Recurse -File -Include '*.exe', '*.msi' -ErrorAction SilentlyContinue)
        if ($installers.Count -gt 0) {
            [void]$warnings.Add(('{0} installer executable(s) in the driver folder will be ignored; only extracted INF packages are integrated. Install AMD Adrenalin after Windows Setup.' -f $installers.Count))
        }
    }

    # Setup / unattend
    $setup = $BuildProfile.setup
    foreach ($b in @('unattend', 'hideEula', 'startupToGamingHome')) {
        if ($setup.$b -isnot [bool]) { [void]$errors.Add(("setup.{0} must be true or false." -f $b)) }
    }
    foreach ($loc in @('uiLanguage', 'inputLocale', 'systemLocale', 'userLocale')) {
        $v = [string]$setup.$loc
        try {
            $ci = [System.Globalization.CultureInfo]::GetCultureInfo($v)
            if ([string]::IsNullOrWhiteSpace($v) -or $ci.Name -ne $v) { throw 'not canonical' }
        }
        catch { [void]$errors.Add(("setup.{0} '{1}' is not a valid culture name (for example en-US)." -f $loc, $v)) }
    }
    try { [void][System.TimeZoneInfo]::FindSystemTimeZoneById([string]$setup.timeZone) }
    catch { [void]$errors.Add(("setup.timeZone '{0}' is not a Windows time zone ID." -f $setup.timeZone)) }
    if ([string]$setup.privacy -notin @('Minimal', 'Recommended')) {
        [void]$errors.Add("setup.privacy must be 'Minimal' or 'Recommended'.")
    }
    if ([bool]$setup.startupToGamingHome) {
        [void]$warnings.Add('StartupToGamingHome is an OEM unattend setting documented for gaming handhelds; on desktops verify Xbox mode after installation (Settings > Gaming > Xbox mode).')
        if (-not [bool]$setup.unattend) { [void]$errors.Add('setup.startupToGamingHome requires setup.unattend=true.') }
    }
    $post = $setup.postInstall
    foreach ($b in @('enabled', 'gameMode', 'hardwareAcceleratedGpuScheduling')) {
        if ($post.$b -isnot [bool]) { [void]$errors.Add(("setup.postInstall.{0} must be true or false." -f $b)) }
    }
    foreach ($l in @($post.launchers)) {
        if ($script:XboxOSBuilderLaunchers -notcontains [string]$l) { [void]$errors.Add(("Unknown launcher '{0}'." -f $l)) }
    }
    if ($post.PSObject.Properties['optimizations']) {
        $tweaks = @((Get-XboxOSGamingTweakCatalog -RepoRoot $m.RepoRoot).tweaks)
        $selectedTweaks = @($post.optimizations)
        if (@($selectedTweaks | Select-Object -Unique).Count -ne $selectedTweaks.Count) { [void]$errors.Add('setup.postInstall.optimizations contains duplicates.') }
        foreach ($o in $selectedTweaks) {
            $t = @($tweaks | Where-Object { [string]$_.id -eq [string]$o })
            if ($t.Count -ne 1) { [void]$errors.Add(("Unknown optimization '{0}'." -f $o)); continue }
            if ($t[0].PSObject.Properties['profileField']) {
                [void]$errors.Add(("Optimization '{0}' is controlled by setup.postInstall.{1}." -f $o, $t[0].profileField))
            }
        }
        if ($selectedTweaks.Count -gt 0 -and -not [bool]$post.enabled) {
            [void]$warnings.Add('Optimizations are selected but first sign-in setup is off; they will not be applied.')
        }
    }
    if ([bool]$post.enabled -and -not [bool]$setup.unattend) {
        [void]$errors.Add('setup.postInstall requires setup.unattend=true (it runs from FirstLogonCommands).')
    }
    if ([bool]$post.hardwareAcceleratedGpuScheduling) {
        [void]$warnings.Add('Hardware-accelerated GPU scheduling depends on the GPU driver; it takes effect after the AMD driver is installed and the PC restarts.')
    }

    # Output
    $out = [string]$BuildProfile.output.directory
    if ([string]::IsNullOrWhiteSpace($out)) { [void]$errors.Add('output.directory is required.') }
    else {
        try {
            $full = [System.IO.Path]::GetFullPath($out)
            if (Test-XboxOSPathEqualsOrUnder -Path $full -ParentPath $m.RepoRoot) { [void]$errors.Add('output.directory must not be inside the XboxOS11 repository.') }
            elseif ($full -match '(?i)[\\/]OneDrive' -or (Test-XboxOSCloudSynchronizedPath -Path $full)) { [void]$errors.Add('output.directory must not be in a cloud-synchronized folder (OneDrive).') }
        }
        catch { [void]$errors.Add(("output.directory is not a valid path: {0}" -f $out)) }
    }
    if ([string]$BuildProfile.output.isoLabel -notmatch '^[A-Za-z0-9_]{1,32}$') {
        [void]$errors.Add('output.isoLabel must be 1-32 letters, digits, or underscores.')
    }

    return [pscustomobject]@{
        valid    = [bool]($errors.Count -eq 0)
        errors   = [string[]]@($errors.ToArray())
        warnings = [string[]]@($warnings.ToArray())
    }
}

function Get-XboxOSBuildProfileReview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$BuildProfile,
        [string]$RepoRoot = $null
    )

    $m = Get-XboxOSBuilderManifestSet -RepoRoot $RepoRoot
    $protected = Get-XboxOSProtectedAppxPatterns -CompatibilityManifest $m.Compatibility
    $apps = @($m.RemoveApps.candidates | ForEach-Object {
            $isProtected = Test-XboxOSAppCandidateProtected -Candidate $_ -ProtectedPatterns $protected
            [pscustomobject]@{
                id          = [string]$_.id
                displayName = [string]$_.displayName
                patterns    = @($_.patterns)
                reason      = [string]$_.reason
                selected    = [bool](@($BuildProfile.apps.remove) -contains [string]$_.id)
                protected   = [bool]$isProtected
                selectable  = -not [bool]$isProtected
                note        = $(if ($isProtected) { 'Protected: required by Store, Xbox, or gaming services.' } else { $null })
            }
        })
    $features = @($m.DisableFeatures.candidates | ForEach-Object {
            $cand = $_
            $isProtected = [bool](@($cand.featureNames | Where-Object { $n = [string]$_; @($m.DisableFeatures.neverDisable | Where-Object { $n -like [string]$_ }).Count -gt 0 }).Count -gt 0)
            [pscustomobject]@{
                id           = [string]$cand.id
                featureNames = @($cand.featureNames)
                reason       = [string]$cand.reason
                selected     = [bool](@($BuildProfile.features.disable) -contains [string]$cand.id)
                protected    = $isProtected
                selectable   = -not $isProtected
                payloadKept  = -not [bool]$m.DisableFeatures.removePayload
            }
        })
    $check = Test-XboxOSBuildProfile -BuildProfile $BuildProfile -RepoRoot $RepoRoot
    return [pscustomobject]@{
        profileName        = [string]$BuildProfile.name
        presetId           = [string]$BuildProfile.presetId
        profileHash        = Get-XboxOSBuildProfileHash -BuildProfile $BuildProfile
        apps               = $apps
        features           = $features
        protectedAppx      = @($protected)
        protectedFeatures  = @($m.DisableFeatures.neverDisable)
        alwaysPreserved    = @('Microsoft Store', 'Xbox app and identity', 'Gaming Services', 'Game Bar', 'Windows Update', 'Microsoft Defender', 'DirectX / Media Foundation', 'WebView2', 'TPM / Secure Boot / VBS requirements')
        drivers            = $BuildProfile.drivers
        updates            = $BuildProfile.updates
        setup              = $BuildProfile.setup
        summary            = [pscustomobject]@{
            appsRemoved        = @($BuildProfile.apps.remove).Count
            featuresDisabled   = @($BuildProfile.features.disable).Count
            driversIntegrated  = [bool]$BuildProfile.drivers.enabled
            updatesIntegrated  = [bool]$BuildProfile.updates.enabled
            unattendGenerated  = [bool]$BuildProfile.setup.unattend
            postInstallEnabled = [bool]$BuildProfile.setup.postInstall.enabled
        }
        validation         = $check
    }
}

#endregion

#region Unattend and post-install payload

function New-XboxOSUnattendXml {
    <#
    .SYNOPSIS
      Builds autounattend.xml from documented Windows Setup components only. Disk selection, edition/product
      key entry, and account creation are left to the interactive Setup/OOBE screens.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$BuildProfile)

    $s = $BuildProfile.setup
    if (-not [bool]$s.unattend) { throw 'setup.unattend is false; no unattend file is generated.' }
    $esc = { param($v) [System.Security.SecurityElement]::Escape([string]$v) }
    $attrs = 'processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"'
    $protect = if ([string]$s.privacy -eq 'Minimal') { 3 } else { 1 }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<?xml version="1.0" encoding="utf-8"?>')
    [void]$sb.AppendLine('<!-- Generated by XboxOS11 Builder. No disk configuration, product key, accounts, or requirement bypasses. -->')
    [void]$sb.AppendLine('<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">')
    [void]$sb.AppendLine('  <settings pass="windowsPE">')
    [void]$sb.AppendLine(('    <component name="Microsoft-Windows-International-Core-WinPE" {0}>' -f $attrs))
    [void]$sb.AppendLine(('      <SetupUILanguage><UILanguage>{0}</UILanguage></SetupUILanguage>' -f (& $esc $s.uiLanguage)))
    [void]$sb.AppendLine(('      <InputLocale>{0}</InputLocale>' -f (& $esc $s.inputLocale)))
    [void]$sb.AppendLine(('      <SystemLocale>{0}</SystemLocale>' -f (& $esc $s.systemLocale)))
    [void]$sb.AppendLine(('      <UILanguage>{0}</UILanguage>' -f (& $esc $s.uiLanguage)))
    [void]$sb.AppendLine(('      <UserLocale>{0}</UserLocale>' -f (& $esc $s.userLocale)))
    [void]$sb.AppendLine('    </component>')
    if ([bool]$s.hideEula) {
        [void]$sb.AppendLine(('    <component name="Microsoft-Windows-Setup" {0}>' -f $attrs))
        [void]$sb.AppendLine('      <UserData><AcceptEula>true</AcceptEula></UserData>')
        [void]$sb.AppendLine('    </component>')
    }
    [void]$sb.AppendLine('  </settings>')
    if ([bool]$s.startupToGamingHome) {
        [void]$sb.AppendLine('  <settings pass="specialize">')
        [void]$sb.AppendLine(('    <component name="Microsoft-Windows-Gaming-Configuration" {0}>' -f $attrs))
        [void]$sb.AppendLine('      <StartupToGamingHome>true</StartupToGamingHome>')
        [void]$sb.AppendLine('    </component>')
        [void]$sb.AppendLine('  </settings>')
    }
    [void]$sb.AppendLine('  <settings pass="oobeSystem">')
    [void]$sb.AppendLine(('    <component name="Microsoft-Windows-International-Core" {0}>' -f $attrs))
    [void]$sb.AppendLine(('      <InputLocale>{0}</InputLocale>' -f (& $esc $s.inputLocale)))
    [void]$sb.AppendLine(('      <SystemLocale>{0}</SystemLocale>' -f (& $esc $s.systemLocale)))
    [void]$sb.AppendLine(('      <UILanguage>{0}</UILanguage>' -f (& $esc $s.uiLanguage)))
    [void]$sb.AppendLine(('      <UserLocale>{0}</UserLocale>' -f (& $esc $s.userLocale)))
    [void]$sb.AppendLine('    </component>')
    [void]$sb.AppendLine(('    <component name="Microsoft-Windows-Shell-Setup" {0}>' -f $attrs))
    [void]$sb.AppendLine(('      <TimeZone>{0}</TimeZone>' -f (& $esc $s.timeZone)))
    [void]$sb.AppendLine('      <OOBE>')
    if ([bool]$s.hideEula) { [void]$sb.AppendLine('        <HideEULAPage>true</HideEULAPage>') }
    [void]$sb.AppendLine(('        <ProtectYourPC>{0}</ProtectYourPC>' -f $protect))
    [void]$sb.AppendLine('      </OOBE>')
    if ([bool]$s.postInstall.enabled) {
        [void]$sb.AppendLine('      <FirstLogonCommands>')
        [void]$sb.AppendLine('        <SynchronousCommand wcm:action="add">')
        [void]$sb.AppendLine('          <Order>1</Order>')
        [void]$sb.AppendLine('          <Description>XboxOS11 post-install gaming setup</Description>')
        [void]$sb.AppendLine('          <CommandLine>powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%WINDIR%\Setup\Scripts\XboxOS11\Invoke-PostInstall.ps1"</CommandLine>')
        [void]$sb.AppendLine('          <RequiresUserInput>false</RequiresUserInput>')
        [void]$sb.AppendLine('        </SynchronousCommand>')
        [void]$sb.AppendLine('      </FirstLogonCommands>')
    }
    [void]$sb.AppendLine('    </component>')
    [void]$sb.AppendLine('  </settings>')
    [void]$sb.AppendLine('</unattend>')

    $xml = $sb.ToString()
    $doc = New-Object System.Xml.XmlDocument
    $doc.LoadXml($xml)
    return $xml
}

function New-XboxOSPostInstallOptions {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$BuildProfile)

    $p = $BuildProfile.setup.postInstall
    return [ordered]@{
        schemaVersion                    = 'xboxos-postinstall-options-v1'
        profileName                      = [string]$BuildProfile.name
        gameMode                         = [bool]$p.gameMode
        hardwareAcceleratedGpuScheduling = [bool]$p.hardwareAcceleratedGpuScheduling
        launchers                        = @($p.launchers | ForEach-Object { [string]$_ })
        optimizations                    = @($(if ($p.PSObject.Properties['optimizations']) { $p.optimizations | ForEach-Object { [string]$_ } }))
        logPath                          = 'C:\ProgramData\XboxOS11\postinstall.log'
    }
}

#endregion

#region Effective build configuration

function New-XboxOSBuilderEffectiveConfiguration {
    <#
    .SYNOPSIS
      Materializes a validated profile into a derived build.json and manifests outside the repository,
      plus a media overlay (autounattend.xml and $OEM$ post-install payload) copied onto the ISO tree.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$BuildProfile,
        [string]$WorkRoot = 'C:\XboxOS\Work\profiles',
        [string]$RepoRoot = $null,
        [switch]$ForBuild
    )

    $check = Test-XboxOSBuildProfile -BuildProfile $BuildProfile -RepoRoot $RepoRoot -ForBuild:$ForBuild
    if (-not $check.valid) {
        throw ("Build profile is invalid:`n - " + ($check.errors -join "`n - "))
    }
    $m = Get-XboxOSBuilderManifestSet -RepoRoot $RepoRoot
    $hash = Get-XboxOSBuildProfileHash -BuildProfile $BuildProfile
    $safeName = (ConvertTo-XboxOSSafeFileName -Name ([string]$BuildProfile.name)) -replace '\s', '-'
    $dir = Join-Path $WorkRoot ('{0}-{1}' -f $safeName, $hash.Substring(0, 12).ToLowerInvariant())
    $full = [System.IO.Path]::GetFullPath($dir)
    if (Test-XboxOSPathEqualsOrUnder -Path $full -ParentPath $m.RepoRoot) { throw "Effective configuration must be generated outside the repository: $full" }
    if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
    New-Item -ItemType Directory -Path $full -Force | Out-Null

    $apps = Copy-XboxOSJsonObject -Value $m.RemoveApps
    foreach ($c in @($apps.candidates)) { $c.enabled = [bool](@($BuildProfile.apps.remove) -contains [string]$c.id) }
    $features = Copy-XboxOSJsonObject -Value $m.DisableFeatures
    foreach ($c in @($features.candidates)) { $c.enabled = [bool](@($BuildProfile.features.disable) -contains [string]$c.id) }
    $drivers = Copy-XboxOSJsonObject -Value $m.Drivers
    if ([bool]$BuildProfile.drivers.enabled) { $drivers.driverDirectory = [string]$BuildProfile.drivers.directory }

    $appsPath = Join-Path $full 'remove-apps.json'
    $featuresPath = Join-Path $full 'disable-features.json'
    $driversPath = Join-Path $full 'drivers.json'
    ($apps | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $appsPath -Encoding UTF8
    ($features | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $featuresPath -Encoding UTF8
    ($drivers | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $driversPath -Encoding UTF8

    $build = Copy-XboxOSJsonObject -Value $m.Build
    $build.target.imageNamePattern = [string]$BuildProfile.source.editionPattern
    if ([string]$BuildProfile.source.editionPattern -notmatch '[\*\?\[]') {
        # An exact edition name (picked from the ISO) must also replace target.edition, which Import-Source matches first.
        $build.target.edition = [string]$BuildProfile.source.editionPattern
    }
    if ($null -ne $BuildProfile.source.imageIndex) { $build.target.sourceImageIndex = [int]$BuildProfile.source.imageIndex }
    $build.workspace.output = [string]$BuildProfile.output.directory
    $build.iso.label = [string]$BuildProfile.output.isoLabel
    $build.phases.removeApps = [bool](@($BuildProfile.apps.remove).Count -gt 0)
    $build.phases.disableFeatures = [bool](@($BuildProfile.features.disable).Count -gt 0)
    $build.phases.addDrivers = [bool]$BuildProfile.drivers.enabled
    $build.phases.addUpdates = [bool]$BuildProfile.updates.enabled
    $build.paths.removeAppsManifest = $appsPath
    $build.paths.disableFeaturesManifest = $featuresPath
    $build.paths.driversManifest = $driversPath
    $build.paths.servicesManifest = Join-Path $m.RepoRoot 'config\services.json'
    $build.paths.compatibilityManifest = Join-Path $m.RepoRoot 'config\compatibility.json'
    if ([bool]$BuildProfile.drivers.enabled) { $build.paths.driverDirectory = [string]$BuildProfile.drivers.directory }
    if ([bool]$BuildProfile.updates.enabled) { $build.paths.updateDirectory = [string]$BuildProfile.updates.directory }
    $build | Add-Member -NotePropertyName builderProfile -NotePropertyValue ([pscustomobject]@{
            name          = [string]$BuildProfile.name
            presetId      = [string]$BuildProfile.presetId
            profileHash   = $hash
            engineVersion = $script:XboxOSBuilderEngineVersion
        }) -Force
    $buildPath = Join-Path $full 'build.json'
    ($build | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $buildPath -Encoding UTF8

    # Every image carries a build record and recovery tooling (Windows Setup copies sources\$OEM$\$$ to
    # %WINDIR%), so what XboxOS11 changed can always be reviewed and undone on the installed PC.
    $overlay = Join-Path $full 'media-overlay'
    $scriptsRel = 'sources\$OEM$\$$\Setup\Scripts\XboxOS11'
    $scripts = Join-Path $overlay $scriptsRel
    New-Item -ItemType Directory -Path $scripts -Force | Out-Null
    $overlayFiles = @()
    $postFiles = @('Restore-XboxOS11Components.ps1', 'Set-GamingOptimizations.ps1', 'Verify-System.ps1')
    if ([bool]$BuildProfile.setup.unattend -and [bool]$BuildProfile.setup.postInstall.enabled) {
        $postFiles += @('Invoke-PostInstall.ps1', 'Setup-Gaming.ps1', 'Install-Launchers.ps1')
        ((New-XboxOSPostInstallOptions -BuildProfile $BuildProfile) | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $scripts 'postinstall.json') -Encoding UTF8
        $overlayFiles += ($scriptsRel + '\postinstall.json')
    }
    foreach ($f in $postFiles) {
        Copy-Item -LiteralPath (Join-Path $m.RepoRoot ('postinstall\' + $f)) -Destination (Join-Path $scripts $f) -Force
        $overlayFiles += ($scriptsRel + '\' + $f)
    }
    Copy-Item -LiteralPath (Join-Path $m.RepoRoot 'config\gaming-tweaks.json') -Destination (Join-Path $scripts 'gaming-tweaks.json') -Force
    $overlayFiles += ($scriptsRel + '\gaming-tweaks.json')
    ((New-XboxOSBuildRecord -BuildProfile $BuildProfile -ProfileHash $hash -RepoRoot $m.RepoRoot) | ConvertTo-Json -Depth 8) |
        Set-Content -LiteralPath (Join-Path $scripts 'build-record.json') -Encoding UTF8
    $overlayFiles += ($scriptsRel + '\build-record.json')
    if ([bool]$BuildProfile.setup.unattend) {
        Set-Content -LiteralPath (Join-Path $overlay 'autounattend.xml') -Value (New-XboxOSUnattendXml -BuildProfile $BuildProfile) -Encoding UTF8
        $overlayFiles = @('autounattend.xml') + $overlayFiles
    }
    Export-XboxOSBuildProfile -BuildProfile $BuildProfile -Path (Join-Path $full 'profile.json') | Out-Null

    return [pscustomobject]@{
        Directory             = $full
        ConfigurationPath     = $buildPath
        MediaOverlayDirectory = $overlay
        MediaOverlayFiles     = [string[]]$overlayFiles
        ProfileHash           = $hash
        Warnings              = $check.warnings
    }
}

function Get-XboxOSToolkitVersion {
    [CmdletBinding()]
    param([string]$RepoRoot = $null)

    if (-not $RepoRoot) { $RepoRoot = Get-XboxOSRepoRoot }
    $path = Join-Path $RepoRoot 'VERSION'
    if (-not (Test-Path -LiteralPath $path)) { return '0.0.0-dev' }
    return (Get-Content -LiteralPath $path -Raw -Encoding UTF8).Trim()
}

function Test-XboxOSReleaseVersionConsistency {
    <#
    .SYNOPSIS
      VERSION is the single source of truth; the module manifest, .NET props, and app manifest must match it.
    #>
    [CmdletBinding()]
    param([string]$RepoRoot = $null)

    if (-not $RepoRoot) { $RepoRoot = Get-XboxOSRepoRoot }
    $version = Get-XboxOSToolkitVersion -RepoRoot $RepoRoot
    $errors = New-Object System.Collections.Generic.List[string]
    if ($version -notmatch '^\d+\.\d+\.\d+$') { [void]$errors.Add("VERSION '$version' is not MAJOR.MINOR.PATCH.") }

    $psd = Import-PowerShellDataFile -LiteralPath (Join-Path $RepoRoot 'modules\XboxOS.Build\XboxOS.Build.psd1')
    if ([string]$psd.ModuleVersion -ne $version) { [void]$errors.Add("Module manifest ModuleVersion '$($psd.ModuleVersion)' != VERSION '$version'.") }

    foreach ($props in @('src\Directory.Build.props', 'tests\dotnet\Directory.Build.props')) {
        $path = Join-Path $RepoRoot $props
        if (Test-Path -LiteralPath $path) {
            $v = ([xml](Get-Content -LiteralPath $path -Raw)).Project.PropertyGroup.Version
            if ([string]$v -ne $version) { [void]$errors.Add("$props Version '$v' != VERSION '$version'.") }
        }
    }
    $appManifest = Join-Path $RepoRoot 'src\XboxOS11.Builder.App\app.manifest'
    if (Test-Path -LiteralPath $appManifest) {
        $v = ([xml](Get-Content -LiteralPath $appManifest -Raw)).assembly.assemblyIdentity.version
        if ([string]$v -ne "$version.0") { [void]$errors.Add("app.manifest version '$v' != '$version.0'.") }
    }
    return [pscustomobject]@{ version = $version; consistent = [bool]($errors.Count -eq 0); errors = [string[]]@($errors.ToArray()) }
}

function New-XboxOSBuildRecord {
    <#
    .SYNOPSIS
      Describes exactly what an image build changed, for the installed PC's recovery tooling.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$BuildProfile,
        [Parameter(Mandatory)][string]$ProfileHash,
        [string]$RepoRoot = $null
    )

    $m = Get-XboxOSBuilderManifestSet -RepoRoot $RepoRoot
    $apps = @($m.RemoveApps.candidates | Where-Object { @($BuildProfile.apps.remove) -contains [string]$_.id } | ForEach-Object {
            [ordered]@{ id = [string]$_.id; displayName = [string]$_.displayName; patterns = @($_.patterns) }
        })
    $features = @($m.DisableFeatures.candidates | Where-Object { @($BuildProfile.features.disable) -contains [string]$_.id } | ForEach-Object {
            [ordered]@{ id = [string]$_.id; featureNames = @($_.featureNames) }
        })
    $post = $BuildProfile.setup.postInstall
    return [ordered]@{
        schemaVersion     = 'xboxos-build-record-v1'
        toolkitVersion    = Get-XboxOSToolkitVersion -RepoRoot $m.RepoRoot
        builderEngine     = $script:XboxOSBuilderEngineVersion
        profileName       = [string]$BuildProfile.name
        presetId          = [string]$BuildProfile.presetId
        profileHash       = $ProfileHash
        createdUtc        = [datetime]::UtcNow.ToString('o')
        removedApps       = $apps
        disabledFeatures  = $features
        featurePayloadKept = -not [bool]$m.DisableFeatures.removePayload
        driversIntegrated = [bool]$BuildProfile.drivers.enabled
        updatesIntegrated = [bool]$BuildProfile.updates.enabled
        unattend          = [bool]$BuildProfile.setup.unattend
        postInstall       = [ordered]@{
            enabled       = [bool]$post.enabled
            gameMode      = [bool]$post.gameMode
            hardwareAcceleratedGpuScheduling = [bool]$post.hardwareAcceleratedGpuScheduling
            optimizations = @($(if ($post.PSObject.Properties['optimizations']) { $post.optimizations }))
            launchers     = @($post.launchers)
        }
        recovery          = 'Run %WINDIR%\Setup\Scripts\XboxOS11\Restore-XboxOS11Components.ps1 as administrator.'
    }
}

function Test-XboxOSMediaOverlay {
    <#
    .SYNOPSIS
      Overlays may only add autounattend.xml at the media root and files under sources\$OEM$.
      They can never replace boot files, install images, or Setup binaries.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Directory)

    $errors = New-Object System.Collections.Generic.List[string]
    $root = [System.IO.Path]::GetFullPath($Directory).TrimEnd('\') + '\'
    $files = @(Get-ChildItem -LiteralPath $Directory -Recurse -File -Force)
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($root.Length)
        $ok = ($rel -ieq 'autounattend.xml') -or ($rel -like 'sources\$OEM$\*')
        if (-not $ok) { [void]$errors.Add(("Overlay file not permitted: {0}" -f $rel)) }
        if ($f.Extension -in @('.wim', '.esd', '.swm', '.efi', '.sdi')) { [void]$errors.Add(("Overlay may not contain boot or image files: {0}" -f $rel)) }
    }
    return [pscustomobject]@{
        valid  = [bool]($errors.Count -eq 0)
        files  = [string[]]@($files | ForEach-Object { $_.FullName.Substring($root.Length) })
        errors = [string[]]@($errors.ToArray())
    }
}

#endregion
