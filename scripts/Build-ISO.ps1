#Requires -Version 5.1
<#
.SYNOPSIS
    XboxOS11 main entry point: builds a customized Windows 11 gaming installation ISO.
.EXAMPLE
    .\scripts\Build-ISO.ps1 -SourceISO 'C:\ISOs\Win11.iso' -Configuration '.\config\build.json' -OutputDirectory 'C:\XboxOS\Output' -DryRun
.EXAMPLE
    .\scripts\Build-ISO.ps1 -SourceISO 'C:\ISOs\Win11.iso' -Configuration '.\config\build.json' -OutputDirectory 'C:\XboxOS\Output'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SourceISO,

    [string]$Configuration = (Join-Path $PSScriptRoot '..\config\build.json'),

    [string]$OutputDirectory,

    [switch]$DryRun,

    [switch]$SkipPrerequisites,

    [switch]$KeepWorkspaceOnSuccess
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$modulePath = Join-Path $PSScriptRoot '..\modules\XboxOS.Build\XboxOS.Build.psd1'
Import-Module $modulePath -Force

function Invoke-Phase {
    param(
        [Parameter(Mandatory)][object]$Context,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Script
    )

    Write-Host ''
    Write-Host "=== Phase: $Name ===" -ForegroundColor Cyan
    Write-XboxOSLog -Level Information -Message "Starting phase: $Name"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $result = & $Script
        $sw.Stop()
        $Context.PhaseResults.Add([pscustomobject]@{
            Name     = $Name
            Status   = 'Succeeded'
            Message  = "Completed in $([int]$sw.Elapsed.TotalSeconds)s"
            Duration = $sw.Elapsed
            Result   = $result
        }) | Out-Null
        Write-XboxOSLog -Level Information -Message "Phase succeeded: $Name"
        return $result
    }
    catch {
        $sw.Stop()
        $Context.PhaseResults.Add([pscustomobject]@{
            Name     = $Name
            Status   = 'Failed'
            Message  = $_.Exception.Message
            Duration = $sw.Elapsed
            Result   = $null
        }) | Out-Null
        Write-XboxOSLog -Level Error -Message "Phase failed: $Name - $($_.Exception.Message)"
        throw
    }
}

$Context = $null
$dismPath = $null
$commitImage = $false
$buildFailed = $false

try {
    if (-not $SkipPrerequisites) {
        $pre = & (Join-Path $PSScriptRoot 'Test-Prerequisites.ps1') -SourceISO $SourceISO -Configuration $Configuration -PassThru
        if (-not $pre.Passed) {
            $blocking = @($pre.Failed | Where-Object {
                    -not (
                        $DryRun -and $_.Name -in @('WindowsADK', 'Oscdimg', 'SourceISO')
                    )
                })
            if ($blocking.Count -gt 0) {
                throw ("Prerequisite validation failed:`n - " + (($blocking | ForEach-Object { "$($_.Name): $($_.Message)" }) -join "`n - "))
            }
            Write-Warning 'DryRun continuing despite missing ADK/Oscdimg/SourceISO. A real build still requires those tools.'
        }
    }

    $Context = New-XboxOSBuildContext -ConfigurationPath $Configuration -SourceISO $SourceISO -OutputDirectory $OutputDirectory -DryRun:$DryRun
    $dismPath = Find-XboxOSDism
    $phases = $Context.Configuration.Raw.phases

    Write-Host "XboxOS11 build $($Context.BuildId) (DryRun=$DryRun)" -ForegroundColor Green
    Write-Host "Workspace: $($Context.Paths.Workspace)"
    Write-Host "Output:    $($Context.Paths.Output)"
    Write-Host "Log:       $($Context.LogFile)"

    if ($phases.importSource) {
        Invoke-Phase -Context $Context -Name 'ImportSource' -Script {
            & (Join-Path $PSScriptRoot 'Import-Source.ps1') -SourceISO $SourceISO -Context $Context -DismPath $dismPath -DryRun:$DryRun
        } | Out-Null
    }

    if (-not $DryRun) {
        Invoke-Phase -Context $Context -Name 'MountImage' -Script {
            & (Join-Path $PSScriptRoot 'Mount-Image.ps1') -Context $Context -DismPath $dismPath
        } | Out-Null
    }
    else {
        Invoke-Phase -Context $Context -Name 'MountImage' -Script {
            & (Join-Path $PSScriptRoot 'Mount-Image.ps1') -Context $Context -DismPath $dismPath -DryRun
        } | Out-Null
    }

    if ($phases.inventoryBefore) {
        Invoke-Phase -Context $Context -Name 'InventoryBefore' -Script {
            & (Join-Path $PSScriptRoot 'Inventory-Image.ps1') -Context $Context -Stage Before -DismPath $dismPath -DryRun:$DryRun
        } | Out-Null
    }

    if ($phases.removeApps) {
        Invoke-Phase -Context $Context -Name 'RemoveApps' -Script {
            & (Join-Path $PSScriptRoot 'Remove-Apps.ps1') -Context $Context -DismPath $dismPath -DryRun:$DryRun
        } | Out-Null
    }

    if ($phases.disableFeatures) {
        Invoke-Phase -Context $Context -Name 'DisableFeatures' -Script {
            & (Join-Path $PSScriptRoot 'Disable-Features.ps1') -Context $Context -DismPath $dismPath -DryRun:$DryRun
        } | Out-Null
    }

    if ($phases.addDrivers) {
        Invoke-Phase -Context $Context -Name 'AddDrivers' -Script {
            & (Join-Path $PSScriptRoot 'Add-Drivers.ps1') -Context $Context -DismPath $dismPath -DryRun:$DryRun
        } | Out-Null
    }

    if ($phases.addUpdates) {
        Invoke-Phase -Context $Context -Name 'AddUpdates' -Script {
            & (Join-Path $PSScriptRoot 'Add-Updates.ps1') -Context $Context -DismPath $dismPath -DryRun:$DryRun
        } | Out-Null
    }

    if ($phases.inventoryAfter) {
        Invoke-Phase -Context $Context -Name 'InventoryAfter' -Script {
            & (Join-Path $PSScriptRoot 'Inventory-Image.ps1') -Context $Context -Stage After -DismPath $dismPath -DryRun:$DryRun
        } | Out-Null
    }

    # Commit only after successful modification phases.
    $commitImage = -not $DryRun -and -not [bool]$Context.Configuration.Raw.safety.commitOnFailure
    if (-not $DryRun) {
        Invoke-Phase -Context $Context -Name 'DismountCommit' -Script {
            & (Join-Path $PSScriptRoot 'Dismount-Image.ps1') -Context $Context -DismPath $dismPath
        } | Out-Null
        $commitImage = $false
    }

    if ($phases.validate) {
        Invoke-Phase -Context $Context -Name 'Validate' -Script {
            & (Join-Path $PSScriptRoot 'Validate-Image.ps1') -Context $Context -DismPath $dismPath -DryRun:$DryRun
        } | Out-Null
    }

    if ($phases.exportIso) {
        Invoke-Phase -Context $Context -Name 'ExportIso' -Script {
            & (Join-Path $PSScriptRoot 'Export-ISO.ps1') -Context $Context -DryRun:$DryRun
        } | Out-Null
    }

    $Context.Success = $true
    Save-XboxOSBuildReport -Context $Context | Out-Null
    Write-Host ''
    Write-Host "Build succeeded: $($Context.BuildId)" -ForegroundColor Green
    Write-Host "Reports: $($Context.Paths.Reports)"
    if (-not $KeepWorkspaceOnSuccess -and -not $DryRun) {
        Write-XboxOSLog -Level Information -Message 'Cleaning workspace (reports preserved).'
        Clear-XboxOSWorkspace -WorkspacePath $Context.Paths.Workspace -PreserveReports
    }
}
catch {
    $buildFailed = $true
    if ($Context) {
        $Context.Success = $false
        try { Save-XboxOSBuildReport -Context $Context | Out-Null } catch { }
    }
    throw
}
finally {
    if ($Context -and $Context.MountedImagePath -and -not $DryRun) {
        Write-XboxOSLog -Level Warning -Message 'Ensuring mounted image is discarded after failure or incomplete commit.'
        try {
            # Never commit after a failed modification.
            Invoke-XboxOSMountCleanup -MountPath $Context.Paths.Mount -DismPath $dismPath -Discard:(-not $Context.Success)
        }
        catch {
            Write-XboxOSLog -Level Warning -Message "Final mount cleanup error: $($_.Exception.Message)"
        }
    }

    if ($Context -and $Context.MountedIsoPath) {
        try { Dismount-DiskImage -ImagePath $Context.MountedIsoPath -ErrorAction SilentlyContinue | Out-Null } catch { }
    }

    if ($buildFailed -and $Context) {
        Write-Host "Build failed. Diagnostics preserved under $($Context.Paths.Workspace)" -ForegroundColor Yellow
        Write-Host "Log: $($Context.LogFile)" -ForegroundColor Yellow
    }
}
