#Requires -Version 5.1
<#
.SYNOPSIS
    Applies or restores XboxOS11 gaming optimizations from gaming-tweaks.json.
.DESCRIPTION
    Every tweak is a documented Windows Settings value. Before the first change to any value, its original
    state (present/absent, kind, data) is captured in a state file, so -Restore returns each value exactly to
    what it was. Machine-scope tweaks are skipped (not elevated) unless running as administrator.

    Never changes the power plan, Xbox Game Bar, security features, Windows Update, or Defender.
    Runs under Windows PowerShell 5.1 - keep syntax 5.1-compatible.
.EXAMPLE
    .\Set-GamingOptimizations.ps1 -List
.EXAMPLE
    .\Set-GamingOptimizations.ps1 -UseDefaults -WhatIf
.EXAMPLE
    .\Set-GamingOptimizations.ps1 -Enable WindowedGameOptimizations, BackgroundRecordingOff
.EXAMPLE
    .\Set-GamingOptimizations.ps1 -Restore
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Apply')]
param(
    [Parameter(ParameterSetName = 'Apply')]
    [string[]]$Enable = @(),

    [Parameter(ParameterSetName = 'Apply')]
    [switch]$UseDefaults,

    [Parameter(ParameterSetName = 'Restore', Mandatory)]
    [switch]$Restore,

    [Parameter(ParameterSetName = 'List', Mandatory)]
    [switch]$List,

    [string]$CatalogPath,

    [string]$StatePath = 'C:\ProgramData\XboxOS11\gaming-state.json',

    # Tests only: redirect HKCU:\ and HKLM:\ under this registry key and skip the elevation check.
    [string]$TestRegistryRoot,

    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $CatalogPath) {
    $CatalogPath = Join-Path $PSScriptRoot 'gaming-tweaks.json'
    if (-not (Test-Path -LiteralPath $CatalogPath)) {
        $CatalogPath = Join-Path $PSScriptRoot '..\config\gaming-tweaks.json'
    }
}
$catalog = Get-Content -LiteralPath $CatalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$catalog.schemaVersion -ne 'xboxos-gaming-tweaks-v1') {
    throw "Unsupported gaming tweak catalog: $($catalog.schemaVersion)"
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$results = New-Object System.Collections.Generic.List[object]

function Resolve-RegistryPath {
    param([Parameter(Mandatory)][string]$Path)
    if (-not $TestRegistryRoot) { return $Path }
    if ($Path -match '^(HKCU|HKLM):\\(.*)$') {
        return (Join-Path (Join-Path $TestRegistryRoot $Matches[1]) $Matches[2])
    }
    throw "Unsupported registry path: $Path"
}

function Get-ValueState {
    param([string]$Path, [string]$Name)
    $p = Resolve-RegistryPath -Path $Path
    if (-not (Test-Path -LiteralPath $p)) {
        return [pscustomobject]@{ existed = $false; kind = $null; data = $null }
    }
    $key = Get-Item -LiteralPath $p
    if ($key.GetValueNames() -notcontains $Name) {
        return [pscustomobject]@{ existed = $false; kind = $null; data = $null }
    }
    return [pscustomobject]@{
        existed = $true
        kind    = [string]$key.GetValueKind($Name)
        data    = $key.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')
    }
}

function Set-Value {
    param([string]$Path, [string]$Name, [string]$Kind, [object]$Data)
    $p = Resolve-RegistryPath -Path $Path
    if (-not (Test-Path -LiteralPath $p)) { New-Item -Path $p -Force | Out-Null }
    New-ItemProperty -LiteralPath $p -Name $Name -PropertyType $Kind -Value $Data -Force | Out-Null
}

function Remove-Value {
    param([string]$Path, [string]$Name)
    $p = Resolve-RegistryPath -Path $Path
    if (Test-Path -LiteralPath $p) {
        Remove-ItemProperty -LiteralPath $p -Name $Name -ErrorAction SilentlyContinue
    }
}

# DirectXUserGlobalSettings holds "Key=Value;" pairs shared by several Settings toggles; edit one key only.
function ConvertFrom-DirectXSettings {
    param([AllowNull()][string]$Text)
    $map = [ordered]@{}
    if ($Text) {
        foreach ($pair in ($Text -split ';')) {
            if ($pair -match '^\s*([^=]+?)\s*=\s*(.*?)\s*$') { $map[$Matches[1]] = $Matches[2] }
        }
    }
    return $map
}

function ConvertTo-DirectXSettings {
    param([System.Collections.IDictionary]$Map)
    $parts = foreach ($k in $Map.Keys) { '{0}={1};' -f $k, $Map[$k] }
    return (@($parts) -join '')
}

function Get-ItemIdentity {
    param([object]$Value)
    $key = ''
    if ($Value.PSObject.Properties['key']) { $key = [string]$Value.key }
    return ('{0}|{1}|{2}' -f $Value.path, $Value.name, $key)
}

function Read-State {
    $state = [pscustomobject]@{
        schemaVersion = 'xboxos-gaming-state-v1'
        captured      = New-Object System.Collections.Generic.List[object]
        history       = New-Object System.Collections.Generic.List[object]
    }
    if (Test-Path -LiteralPath $StatePath) {
        $s = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($c in $s.captured) { if ($null -ne $c) { $state.captured.Add($c) | Out-Null } }
        foreach ($h in $s.history) { if ($null -ne $h) { $state.history.Add($h) | Out-Null } }
    }
    return $state
}

function Save-State {
    param([object]$State)
    $dir = Split-Path -Parent $StatePath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $doc = [ordered]@{ schemaVersion = $State.schemaVersion; captured = $State.captured.ToArray(); history = $State.history.ToArray() }
    ($doc | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $StatePath -Encoding UTF8
}

function Add-Result {
    param([string]$Tweak, [string]$Status, [bool]$RequiresRestart = $false, [string]$Message = '')
    $results.Add([pscustomobject]@{ Tweak = $Tweak; Status = $Status; RequiresRestart = $RequiresRestart; Message = $Message }) | Out-Null
}

if ($List) {
    foreach ($t in @($catalog.tweaks)) {
        Write-Host ('{0,-34} {1,-7} default={2,-5} {3}' -f $t.id, $t.scope, $t.defaultEnabled, $t.settingsPage)
    }
    Write-Host ''
    Write-Host 'Never changed:'
    foreach ($n in @($catalog.neverChange)) { Write-Host (" - {0}: {1}" -f $n.item, $n.reason) }
    if ($PassThru) { return @($catalog.tweaks) }
    return
}

$state = Read-State

if ($Restore) {
    $byTweak = @($state.captured | Group-Object -Property tweakId)
    foreach ($group in $byTweak) {
        $tweakId = [string]$group.Name
        $isMachine = @($group.Group | Where-Object { $_.path -like 'HKLM:*' }).Count -gt 0
        if ($isMachine -and -not $isAdmin -and -not $TestRegistryRoot) {
            Add-Result -Tweak $tweakId -Status 'SkippedRequiresAdministrator' -Message 'Run as administrator to restore machine settings.'
            continue
        }
        if (-not $PSCmdlet.ShouldProcess($tweakId, 'Restore original values')) {
            Add-Result -Tweak $tweakId -Status 'WhatIf'
            continue
        }
        try {
            foreach ($item in $group.Group) {
                if ([string]$item.type -eq 'DirectXSetting') {
                    $cur = Get-ValueState -Path $item.path -Name $item.name
                    $map = ConvertFrom-DirectXSettings -Text $(if ($cur.existed) { [string]$cur.data } else { $null })
                    if ([bool]$item.existed) { $map[[string]$item.key] = [string]$item.data } else { $map.Remove([string]$item.key) }
                    if ($map.Count -eq 0 -and -not [bool]$item.containerExisted) { Remove-Value -Path $item.path -Name $item.name }
                    else { Set-Value -Path $item.path -Name $item.name -Kind 'String' -Data (ConvertTo-DirectXSettings -Map $map) }
                }
                elseif ([bool]$item.existed) {
                    Set-Value -Path $item.path -Name $item.name -Kind ([string]$item.kind) -Data $item.data
                }
                else {
                    Remove-Value -Path $item.path -Name $item.name
                }
            }
            $requiresRestart = [bool](@($catalog.tweaks | Where-Object { $_.id -eq $tweakId -and $_.requiresRestart }).Count)
            Add-Result -Tweak $tweakId -Status 'Restored' -RequiresRestart $requiresRestart
            $remaining = @($state.captured | Where-Object { $_.tweakId -ne $tweakId })
            $state.captured = New-Object System.Collections.Generic.List[object]
            foreach ($r in $remaining) { $state.captured.Add($r) | Out-Null }
        }
        catch {
            Add-Result -Tweak $tweakId -Status 'Failed' -Message $_.Exception.Message
        }
    }
    if ($byTweak.Count -eq 0) { Write-Host 'Nothing to restore: no XboxOS11 gaming changes are recorded.' }
    $state.history.Add([pscustomobject]@{ utc = [datetime]::UtcNow.ToString('o'); action = 'Restore'; tweaks = @($results | ForEach-Object { $_.Tweak }) }) | Out-Null
    if (-not $WhatIfPreference) { Save-State -State $state }
}
else {
    $ids = New-Object System.Collections.Generic.List[string]
    if ($UseDefaults) { foreach ($t in @($catalog.tweaks | Where-Object { $_.defaultEnabled })) { $ids.Add([string]$t.id) | Out-Null } }
    foreach ($e in $Enable) { if ($e -and -not $ids.Contains($e)) { $ids.Add($e) | Out-Null } }

    foreach ($id in $ids) {
        $tweak = @($catalog.tweaks | Where-Object { [string]$_.id -eq $id })
        if ($tweak.Count -ne 1) {
            Add-Result -Tweak $id -Status 'Failed' -Message 'Unknown tweak id.'
            continue
        }
        $tweak = $tweak[0]
        if ([string]$tweak.scope -eq 'Machine' -and -not $isAdmin -and -not $TestRegistryRoot) {
            Add-Result -Tweak $id -Status 'SkippedRequiresAdministrator' -RequiresRestart ([bool]$tweak.requiresRestart) -Message 'Run as administrator to apply machine settings.'
            continue
        }
        try {
            $changed = $false
            foreach ($v in @($tweak.values)) {
                $identity = Get-ItemIdentity -Value $v
                $cur = Get-ValueState -Path $v.path -Name $v.name
                if ([string]$v.type -eq 'DirectXSetting') {
                    $map = ConvertFrom-DirectXSettings -Text $(if ($cur.existed) { [string]$cur.data } else { $null })
                    $had = $map.Contains([string]$v.key)
                    if ($had -and [string]$map[[string]$v.key] -eq [string]$v.data) { continue }
                    if (-not @($state.captured | Where-Object { (Get-ItemIdentity -Value $_) -eq $identity }).Count) {
                        $state.captured.Add([pscustomobject]@{
                                tweakId = $id; path = $v.path; name = $v.name; type = 'DirectXSetting'; key = [string]$v.key
                                existed = $had; containerExisted = $cur.existed; kind = 'String'
                                data = $(if ($had) { [string]$map[[string]$v.key] } else { $null })
                            }) | Out-Null
                    }
                    $map[[string]$v.key] = [string]$v.data
                    if ($PSCmdlet.ShouldProcess("$($v.path)\$($v.name)", "Set $($v.key)=$($v.data)")) {
                        Set-Value -Path $v.path -Name $v.name -Kind 'String' -Data (ConvertTo-DirectXSettings -Map $map)
                    }
                    $changed = $true
                }
                else {
                    if ($cur.existed -and [string]$cur.data -eq [string]$v.data -and [string]$cur.kind -eq [string]$v.type) { continue }
                    if (-not @($state.captured | Where-Object { (Get-ItemIdentity -Value $_) -eq $identity }).Count) {
                        $state.captured.Add([pscustomobject]@{
                                tweakId = $id; path = $v.path; name = $v.name; type = [string]$v.type; key = ''
                                existed = $cur.existed; containerExisted = $true; kind = $cur.kind; data = $cur.data
                            }) | Out-Null
                    }
                    if ($PSCmdlet.ShouldProcess("$($v.path)\$($v.name)", "Set to $($v.data)")) {
                        Set-Value -Path $v.path -Name $v.name -Kind ([string]$v.type) -Data $v.data
                    }
                    $changed = $true
                }
            }
            $status = 'AlreadySet'
            if ($changed) { $status = 'Applied' }
            if ($changed -and $WhatIfPreference) { $status = 'WhatIf' }
            Add-Result -Tweak $id -Status $status -RequiresRestart ([bool]$tweak.requiresRestart -and $changed)
        }
        catch {
            Add-Result -Tweak $id -Status 'Failed' -Message $_.Exception.Message
        }
    }
    $state.history.Add([pscustomobject]@{ utc = [datetime]::UtcNow.ToString('o'); action = 'Apply'; tweaks = $ids.ToArray() }) | Out-Null
    if (-not $WhatIfPreference) { Save-State -State $state }
}

$results | Format-Table -AutoSize | Out-String | Write-Host
if (@($results | Where-Object { $_.RequiresRestart }).Count -gt 0) {
    Write-Host 'Restart Windows for some changes to take effect.'
}
if ($PassThru) { return $results.ToArray() }
