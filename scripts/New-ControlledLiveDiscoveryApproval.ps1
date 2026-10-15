#Requires -Version 7.0
<#
.SYNOPSIS
  Milestone 6E: issues one signed, short-lived, single-run HostDiscoveryReal approval for a named host.

.DESCRIPTION
  The approval binds operator, host identity, scope digest, the current clean Git commit, run identity, nonce,
  expiry (max 4 hours), and the operator public key fingerprint. Issuing an approval does not run discovery.

  Host identity comes either from explicit -HostLabel/-WindowsEdition/-BuildNumber/-Architecture values, or from
  -ObserveHostIdentity (a single read-only Win32_OperatingSystem query on this machine).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OperatorId,
    [Parameter(Mandatory)][string]$PrivateKeyPemPath,
    [Parameter(Mandatory)][string]$PublicKeyPemPath,
    [string]$OutputPath = '',
    [string]$HostLabel = '',
    [string]$WindowsEdition = '',
    [string]$BuildNumber = '',
    [string]$Architecture = '',
    [switch]$ObserveHostIdentity,
    [ValidateRange(5, 240)][int]$ValidMinutes = 60,
    [switch]$IncludeDismMountMetadata,
    [string]$WorkspaceRoot = 'C:\XboxOS\Lab\Work'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
Import-Module (Join-Path $repoRoot 'modules\XboxOS.Build\XboxOS.Build.psd1') -Force

$git = Get-XboxOSToolingGitVerificationState -RepoRoot $repoRoot
if ($git.verificationState -ne 'VerifiedClean') {
    throw ("Approvals can only be issued from a clean, verified checkout (state: {0})." -f $git.verificationState)
}

if ($ObserveHostIdentity) {
    $hostId = New-XboxOSObservedHostIdentity
}
else {
    foreach ($p in @('HostLabel', 'WindowsEdition', 'BuildNumber', 'Architecture')) {
        if ([string]::IsNullOrWhiteSpace((Get-Variable -Name $p -ValueOnly))) {
            throw "Supply -$p (or use -ObserveHostIdentity)."
        }
    }
    $hostId = New-XboxOSObservedHostIdentity -OsObservation @{
        hostLabel = $HostLabel; edition = $WindowsEdition; build = $BuildNumber; architecture = $Architecture
    }
}

$scope = New-XboxOSHostDiscoveryScopeForRealHost -WorkspaceRoot $WorkspaceRoot -IncludeDismMountMetadata:$IncludeDismMountMetadata
$runIdentity = 'm6e-run-' + [datetime]::UtcNow.ToString('yyyyMMddHHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$issued = [datetime]::UtcNow
$approval = New-XboxOSAuthorizedHostDiscoveryApprovalRecord -OperatorId $OperatorId -HostIdentity $hostId -DiscoveryScope $scope `
    -GitCommitSha $git.gitCommitSha -ApprovedCategories @($scope.categories) -RunIdentity $runIdentity `
    -PrivateKeyPemPath $PrivateKeyPemPath -PublicKeyPemPath $PublicKeyPemPath -IssuedUtc $issued -ExpiresUtc $issued.AddMinutes($ValidMinutes) `
    -ReadOnlyAcknowledged

if (-not $OutputPath) {
    $OutputPath = Join-Path 'C:\XboxOS\Lab\Auth\approvals' ($runIdentity + '.json')
}
$saved = Export-XboxOSControlledLiveApproval -Approval $approval -Path $OutputPath

Write-Host "Approval written: $saved"
Write-Host "Run identity:     $runIdentity"
Write-Host ("Host identity:    {0}" -f $hostId.hostIdentityKey)
Write-Host ("Git commit:       {0}" -f $git.gitCommitSha)
Write-Host ("Expires (UTC):    {0:o}" -f $approval.expiresUtc)
Write-Host ''
Write-Host 'Operator acknowledgment required at run time (exact text):'
Write-Host ("  {0}" -f (Get-XboxOSControlledLiveOperatorAcknowledgmentText -RunIdentity $runIdentity))
