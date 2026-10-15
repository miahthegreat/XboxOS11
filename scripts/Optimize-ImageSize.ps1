#Requires -Version 5.1
<#
.SYNOPSIS
    Cleans up superseded components in the mounted image (DISM /Cleanup-Image /StartComponentCleanup).
.NOTES
    With image.resetBase=true, /ResetBase also runs: updates already integrated into the image become permanent
    (they can't be uninstalled later) in exchange for a smaller image. Future Windows Updates still install normally.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [Alias('Context')]
    [object]$BuildContext,

    [string]$DismPath,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$modulePath = Join-Path $PSScriptRoot '..\modules\XboxOS.Build\XboxOS.Build.psd1'
Import-Module $modulePath -Force

if (-not $DismPath) { $DismPath = Find-XboxOSDism }
$config = $BuildContext.Configuration
$mount = $BuildContext.Paths.Mount
$resetBase = [bool]($config.Raw.PSObject.Properties['image'] -and $config.Raw.image.PSObject.Properties['resetBase'] -and [bool]$config.Raw.image.resetBase)
$dismArgs = Get-XboxOSComponentCleanupArguments -MountDir $mount -ResetBase:$resetBase
$command = "dism.exe $($dismArgs -join ' ')"

if ($DryRun -or -not $BuildContext.ImageMounted) {
    Write-XboxOSLog -Level Information -Message "DryRun: would run $command"
    $status = 'DryRun'
}
else {
    $null = Assert-XboxOSServicingPathSafety -Path $mount -RepoRoot $config.RepoRoot -Purpose 'component store cleanup'
    Invoke-XboxOSDism -DismPath $DismPath -ArgumentList $dismArgs | Out-Null
    $status = 'Cleaned'
}

$reportPath = Join-Path $BuildContext.Paths.Reports 'ComponentCleanup.json'
([ordered]@{ status = $status; resetBase = $resetBase; command = $command } | ConvertTo-Json) | Set-Content -LiteralPath $reportPath -Encoding UTF8
return [pscustomobject]@{ Results = @([pscustomobject]@{ Status = $status }); Report = $reportPath; Success = $true; Message = 'OK'; ResetBase = $resetBase }
