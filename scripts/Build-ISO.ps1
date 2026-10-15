#Requires -Version 5.1
<#
.SYNOPSIS
    XboxOS11 main entry point: builds a customized Windows 11 gaming installation ISO.
.EXAMPLE
    .\scripts\Build-ISO.ps1 -SourceISO 'C:\XboxOS\Sources\Win11.iso' -Configuration '.\config\build.json' -OutputDirectory 'C:\XboxOS\Output' -DryRun
.EXAMPLE
    .\scripts\Build-ISO.ps1 -SourceISO 'C:\XboxOS\Sources\Win11.iso' -Configuration '.\config\build.json' -OutputDirectory 'C:\XboxOS\Output'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SourceISO,

    [string]$Configuration = (Join-Path $PSScriptRoot '..\config\build.json'),

    [string]$OutputDirectory,

    [switch]$DryRun,

    [switch]$SkipPrerequisites,

    [switch]$KeepWorkspaceOnSuccess,

    # Builder: files copied onto the ISO tree before export (autounattend.xml and sources\$OEM$ only).
    [string]$MediaOverlayDirectory,

    # Builder: emit machine-readable XBOXOS-EVENT progress lines for the native frontend.
    [switch]$EmitEvents
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$modulePath = Join-Path $PSScriptRoot '..\modules\XboxOS.Build\XboxOS.Build.psd1'
Import-Module $modulePath -Force

function Invoke-Phase {
    param(
        [Parameter(Mandatory)][object]$BuildContext,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Script
    )

    Write-Host ''
    Write-Host "=== Phase: $Name ===" -ForegroundColor Cyan
    Write-XboxOSLog -Level Information -Message "Starting phase: $Name"
    if ($EmitEvents) { $null = Write-XboxOSBuilderEvent -Type phase -Data @{ name = $Name; status = 'started' } }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $Error.Clear()
    try {
        $result = & $Script

        # Surface nonterminating errors that some native/cmdlet paths may emit.
        if ($Error.Count -gt 0) {
            $messages = @($Error | ForEach-Object { $_.ToString() }) -join '; '
            throw "Phase '$Name' produced nonterminating error(s): $messages"
        }

        Assert-XboxOSPhaseOutcome -Result $result -PhaseName $Name | Out-Null

        $sw.Stop()
        $null = $BuildContext.PhaseResults.Add([pscustomobject]@{
            Name     = $Name
            Status   = 'Succeeded'
            Message  = "Completed in $([int]$sw.Elapsed.TotalSeconds)s"
            Duration = $sw.Elapsed
            Result   = $result
        })
        Write-XboxOSLog -Level Information -Message "Phase succeeded: $Name"
        if ($EmitEvents) { $null = Write-XboxOSBuilderEvent -Type phase -Data @{ name = $Name; status = 'succeeded'; seconds = [int]$sw.Elapsed.TotalSeconds } }
        return $result
    }
    catch {
        $sw.Stop()
        $null = $BuildContext.PhaseResults.Add([pscustomobject]@{
            Name     = $Name
            Status   = 'Failed'
            Message  = $_.Exception.Message
            Duration = $sw.Elapsed
            Result   = $null
        })
        Write-XboxOSLog -Level Error -Message "Phase failed: $Name - $($_.Exception.Message)"
        if ($EmitEvents) { $null = Write-XboxOSBuilderEvent -Type phase -Data @{ name = $Name; status = 'failed'; message = $_.Exception.Message } }
        throw
    }
}

$Context = $null
$dismPath = $null
$buildFailed = $false
$imageCommitted = $false

try {
    if (-not $SkipPrerequisites) {
        $pre = & (Join-Path $PSScriptRoot 'Test-Prerequisites.ps1') -SourceISO $SourceISO -Configuration $Configuration -PassThru
        if (-not $pre.Passed) {
            $blocking = @($pre.Failed | Where-Object {
                    -not (
                        $DryRun -and $_.Name -in @('WindowsADK', 'Oscdimg', 'SourceISO', 'Administrator', 'DiskSpace')
                    )
                })
            if ($blocking.Count -gt 0) {
                throw ("Prerequisite validation failed:`n - " + (($blocking | ForEach-Object { "$($_.Name): $($_.Message)" }) -join "`n - "))
            }
            Write-Warning 'DryRun continuing despite soft prerequisite warnings. A real build still requires elevation, ADK/Oscdimg, and a source ISO.'
        }
    }

    $Context = New-XboxOSBuildContext -ConfigurationPath $Configuration -SourceISO $SourceISO -OutputDirectory $OutputDirectory -DryRun:$DryRun
    if ($MediaOverlayDirectory) {
        $overlayCheck = Test-XboxOSMediaOverlay -Directory $MediaOverlayDirectory
        if (-not $overlayCheck.valid) {
            throw ("Media overlay rejected:`n - " + ($overlayCheck.errors -join "`n - "))
        }
    }
    $Context | Add-Member -NotePropertyName MediaOverlayDirectory -NotePropertyValue $MediaOverlayDirectory -Force
    $dismPath = Find-XboxOSDism
    $phases = $Context.Configuration.Raw.phases

    Write-Host "XboxOS11 build $($Context.BuildId) (DryRun=$DryRun)" -ForegroundColor Green
    Write-Host "Workspace: $($Context.Paths.Workspace)"
    Write-Host "Logs:      $($Context.Paths.Logs)"
    Write-Host "Output:    $($Context.Paths.Output)"
    Write-Host "Log file:  $($Context.LogFile)"

    if ($phases.importSource) {
        Invoke-Phase -BuildContext $Context -Name 'ImportSource' -Script {
            & (Join-Path $PSScriptRoot 'Import-Source.ps1') -SourceISO $SourceISO -Context $Context -DismPath $dismPath -DryRun:$DryRun
        } | Out-Null
    }

    Invoke-Phase -BuildContext $Context -Name 'MountImage' -Script {
        & (Join-Path $PSScriptRoot 'Mount-Image.ps1') -BuildContext $Context -DismPath $dismPath -DryRun:$DryRun
    } | Out-Null

    if ($phases.inventoryBefore) {
        Invoke-Phase -BuildContext $Context -Name 'InventoryBefore' -Script {
            & (Join-Path $PSScriptRoot 'Inventory-Image.ps1') -BuildContext $Context -Stage Before -DismPath $dismPath -DryRun:$DryRun
        } | Out-Null
    }

    if ($phases.removeApps) {
        Invoke-Phase -BuildContext $Context -Name 'RemoveApps' -Script {
            & (Join-Path $PSScriptRoot 'Remove-Apps.ps1') -BuildContext $Context -DismPath $dismPath -DryRun:$DryRun
        } | Out-Null
    }

    if ($phases.disableFeatures) {
        Invoke-Phase -BuildContext $Context -Name 'DisableFeatures' -Script {
            & (Join-Path $PSScriptRoot 'Disable-Features.ps1') -BuildContext $Context -DismPath $dismPath -DryRun:$DryRun
        } | Out-Null
    }

    if ($phases.addDrivers) {
        Invoke-Phase -BuildContext $Context -Name 'AddDrivers' -Script {
            & (Join-Path $PSScriptRoot 'Add-Drivers.ps1') -Context $Context -DismPath $dismPath -DryRun:$DryRun
        } | Out-Null
    }

    if ($phases.addUpdates) {
        Invoke-Phase -BuildContext $Context -Name 'AddUpdates' -Script {
            & (Join-Path $PSScriptRoot 'Add-Updates.ps1') -Context $Context -DismPath $dismPath -DryRun:$DryRun
        } | Out-Null
    }

    if ($phases.inventoryAfter) {
        Invoke-Phase -BuildContext $Context -Name 'InventoryAfter' -Script {
            & (Join-Path $PSScriptRoot 'Inventory-Image.ps1') -BuildContext $Context -Stage After -DismPath $dismPath -DryRun:$DryRun
        } | Out-Null
    }

    if (-not $DryRun -and $Context.ImageMounted) {
        Invoke-Phase -BuildContext $Context -Name 'DismountCommit' -Script {
            & (Join-Path $PSScriptRoot 'Dismount-Image.ps1') -Context $Context -DismPath $dismPath
        } | Out-Null
        $imageCommitted = $true
        $Context.ImageMounted = $false
        $Context.MountedImagePath = $null
    }

    if ($phases.validate) {
        Invoke-Phase -BuildContext $Context -Name 'Validate' -Script {
            & (Join-Path $PSScriptRoot 'Validate-Image.ps1') -Context $Context -DismPath $dismPath -DryRun:$DryRun
        } | Out-Null
    }

    if ($phases.exportIso) {
        Invoke-Phase -BuildContext $Context -Name 'ExportIso' -Script {
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
        try { Save-XboxOSBuildReport -Context $Context | Out-Null } catch {
            Write-Warning "Failed to save failure build report: $($_.Exception.Message)"
        }
    }
    throw
}
finally {
    if ($Context -and -not $DryRun -and -not $imageCommitted -and ($Context.ImageMounted -or $Context.MountedImagePath)) {
        Write-XboxOSLog -Level Warning -Message 'Discarding mounted image after failure or incomplete commit.'
        try {
            Invoke-XboxOSMountCleanup -MountPath $Context.Paths.Mount -DismPath $dismPath -Discard
            $Context.ImageMounted = $false
            $Context.MountedImagePath = $null
        }
        catch {
            Write-XboxOSLog -Level Warning -Message "Final mount cleanup error: $($_.Exception.Message)"
        }
    }

    if ($Context -and $Context.MountedIsoPath) {
        try { Dismount-DiskImage -ImagePath $Context.MountedIsoPath -ErrorAction Stop | Out-Null } catch {
            Write-XboxOSLog -Level Warning -Message "ISO dismount warning: $($_.Exception.Message)"
        }
    }

    if ($buildFailed -and $Context) {
        Write-Host "Build failed. Diagnostics preserved under $($Context.Paths.Workspace)" -ForegroundColor Yellow
        Write-Host "Log: $($Context.LogFile)" -ForegroundColor Yellow
    }
}
