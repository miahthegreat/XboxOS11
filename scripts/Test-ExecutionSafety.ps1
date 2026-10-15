#Requires -Version 5.1
<#
.SYNOPSIS
    Milestone 3 execution-safety validation (simulation only).
.DESCRIPTION
    Builds or loads a plan, evaluates approval/drift/dependency contracts, and runs a
    mock transaction. Never enables real DISM mutation.
#>
[CmdletBinding()]
param(
    [string]$CompatJsonPath = 'C:\XboxOS\Logs\DISM-Compatibility-20261014-2.json',
    [string]$RepoRoot,
    [string]$OutputDirectory = 'C:\XboxOS\Logs',
    [string]$OutputStem = 'XboxOS11-execution-safety-m3',
    [string]$OperatorId = 'operator-sim',
    [switch]$SimulateHappyPath,
    [ValidateSet('Success', 'DismFailure', 'UnmountInterrupted', 'VerificationFailure', 'CommitRejected', 'PreparationInterrupted')]
    [string]$FailureMode = 'Success'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$modulePath = Join-Path $PSScriptRoot '..\modules\XboxOS.Build\XboxOS.Build.psd1'
Import-Module $modulePath -Force

if (-not $RepoRoot) {
    $RepoRoot = Get-XboxOSRepoRoot
}

$null = Assert-XboxOSServicingPathSafety -Path $OutputDirectory -RepoRoot $RepoRoot -Purpose 'execution safety reports'

Write-Host '=== XboxOS11 Milestone 3 execution safety (simulation) ===' -ForegroundColor Cyan
Write-Host ("Safety engine: {0}" -f (Get-XboxOSExecutionSafetyEngineVersion))
Write-Host ("Real DISM enabled: {0}" -f (Get-XboxOSRealDismExecutionEnabled))
Write-Host 'No modifying DISM commands will be invoked.'

$inventory = Import-XboxOSInventoryFromCompatReport -Path $CompatJsonPath
$removeApps = Import-XboxOSManifest -Path (Join-Path $RepoRoot 'config\remove-apps.json')
$disableFeatures = Import-XboxOSManifest -Path (Join-Path $RepoRoot 'config\disable-features.json')
$compatibility = Import-XboxOSManifest -Path (Join-Path $RepoRoot 'config\compatibility.json')

$plan = New-XboxOSServicingPlan `
    -Inventory $inventory `
    -RemoveAppsManifest $removeApps `
    -DisableFeaturesManifest $disableFeatures `
    -CompatibilityManifest $compatibility

$dependencyEvidence = @()
if ($SimulateHappyPath) {
    $dependencyEvidence = @(
        $plan.operations |
            Where-Object status -eq 'Eligible' |
            ForEach-Object {
                [pscustomobject]@{
                    operationId    = $_.operationId
                    targetIdentity = $_.targetIdentity
                    outcome        = 'Verified'
                    evidenceHash   = Get-XboxOSUtf8Sha256Hex -Text ("dep:{0}:{1}" -f $_.operationId, $_.targetIdentity)
                }
            }
    )
}

$backend = New-XboxOSMockServicingBackend -FailureMode $FailureMode
$tx = New-XboxOSServicingTransaction `
    -Plan $plan `
    -FreshInventory $inventory `
    -CompatibilityManifest $compatibility `
    -DependencyEvidence $dependencyEvidence `
    -Backend $backend

$tx = Invoke-XboxOSTransactionPreflight -Transaction $tx
Write-Host ("After preflight: state={0} drift={1} deps={2}" -f $tx.state, $(if ($tx.driftResult) { $tx.driftResult.result } else { 'n/a' }), $(if ($tx.dependencyResult) { $tx.dependencyResult.aggregateOutcome } else { 'n/a' }))

if ($tx.state -eq 'AwaitingApproval' -and $SimulateHappyPath) {
    $eligibleIds = @($plan.operations | Where-Object status -eq 'Eligible' | ForEach-Object { $_.operationId })
    $approval = New-XboxOSApprovalRecord `
        -Plan $plan `
        -ApprovedOperationIds $eligibleIds `
        -OperatorId $OperatorId `
        -Scope simulation `
        -IntendedEnvironment 'disposable-workspace-simulation' `
        -DecisionNotes 'Milestone 3 simulated approval; does not authorize real DISM.'
    $null = Save-XboxOSApprovalRecord -Approval $approval -OutputDirectory $OutputDirectory -Stem ($OutputStem + '-approval')
    $tx = Invoke-XboxOSTransactionApplyApproval -Transaction $tx -Approval $approval
    if ($tx.state -eq 'ApprovedForPreparation') {
        $tx = Invoke-XboxOSTransactionSimulate -Transaction $tx
        if ($tx.state -eq 'RecoveryRequired') {
            $tx = Invoke-XboxOSTransactionRecover -Transaction $tx
        }
    }
}

$paths = Save-XboxOSExecutionSafetyReport -Transaction $tx -OutputDirectory $OutputDirectory -Stem $OutputStem

Write-Host ''
Write-Host ("Transaction:     {0}" -f $tx.transactionId)
Write-Host ("State:           {0}" -f $tx.state)
Write-Host ("Plan hash:       {0}" -f $plan.contentHash)
Write-Host ("Sim auth:        {0}" -f $tx.simulatedAuthorizationResult)
Write-Host ("Exec authorized: {0}" -f $tx.executionAuthorized)
Write-Host ("ModifyingCmds:   {0}" -f $tx.modifyingCommandsInvoked)
Write-Host ("RealDismEnabled: {0}" -f (Get-XboxOSRealDismExecutionEnabled))
Write-Host ("JSON:            {0}" -f $paths.Json)
Write-Host ("Markdown:        {0}" -f $paths.Markdown)

if ($tx.modifyingCommandsInvoked -or (Get-XboxOSRealDismExecutionEnabled)) {
    throw 'Safety violation: modifying DISM must remain disabled.'
}

$exitCode = if ($tx.state -eq 'Completed' -and $SimulateHappyPath) { 0 } elseif ($tx.state -in @('Failed', 'Aborted', 'Recovered')) { 2 } else { 0 }
exit $exitCode
