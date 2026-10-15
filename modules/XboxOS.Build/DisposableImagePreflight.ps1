# Milestone 4 disposable-image read-only preflight. Dotted into XboxOS.Build.psm1.
# Live DISM mounts/exports are gated; CI uses mocks/fixtures only.

$script:XboxOSPreflightEngineVersion = '4.0.0'
$script:XboxOSReadOnlyDismAdapterVersion = 'readonly-dism-v1'
$script:XboxOSDisposableWorkspaceSchemaVersion = 'workspace-v1'
$script:XboxOSImageIntegritySchemaVersion = 'image-integrity-v1'
$script:XboxOSApprovalAuthSchemaVersion = 'approval-auth-v1'
$script:XboxOSExpectedIsoSha256 = 'BD4307DF32BC8AF33B39CCECB1174AEB345386630F89A2B86C7A4E36B55EA650'
$script:XboxOSExpectedEditionName = 'Windows 11 Pro'
$script:XboxOSExpectedBuildNumber = '26300.9457'
$script:XboxOSExpectedDisplayVersion = '26H2'

$script:XboxOSReadOnlyDismOperations = [ordered]@{
    GetDismVersion              = [ordered]@{ Class = 'PureInspection'; Template = @('/English', '/?') }
    GetImageInfo                = [ordered]@{ Class = 'PureInspection'; Template = @('/English', '/Get-ImageInfo', '/ImageFile:{ImageFile}') }
    ExportImage                 = [ordered]@{ Class = 'DisposablePreparation'; Template = @('/English', '/Export-Image', '/SourceImageFile:{SourceImageFile}', '/SourceIndex:{SourceIndex}', '/DestinationImageFile:{DestinationImageFile}', '/Compress:max') }
    GetExportedImageInfo        = [ordered]@{ Class = 'PureInspection'; Template = @('/English', '/Get-ImageInfo', '/ImageFile:{ImageFile}') }
    MountImageReadOnly          = [ordered]@{ Class = 'DisposablePreparation'; Template = @('/English', '/Mount-Image', '/ImageFile:{ImageFile}', '/Index:{Index}', '/MountDir:{MountDir}', '/ReadOnly') }
    GetPackages                 = [ordered]@{ Class = 'PureInspection'; Template = @('/English', '/Image:{MountDir}', '/Get-Packages') }
    GetProvisionedAppxPackages  = [ordered]@{ Class = 'PureInspection'; Template = @('/English', '/Image:{MountDir}', '/Get-ProvisionedAppxPackages') }
    GetFeatures                 = [ordered]@{ Class = 'PureInspection'; Template = @('/English', '/Image:{MountDir}', '/Get-Features') }
    GetMountedImageInfo         = [ordered]@{ Class = 'PureInspection'; Template = @('/English', '/Get-MountedImageInfo') }
    UnmountDiscard              = [ordered]@{ Class = 'Cleanup'; Template = @('/English', '/Unmount-Image', '/MountDir:{MountDir}', '/Discard') }
}

$script:XboxOSProhibitedDismTokens = @(
    '/Commit', '/Remove-ProvisionedAppxPackage', '/Disable-Feature', '/Enable-Feature',
    '/Add-Driver', '/Add-Package', '/Apply-Image', '/Capture-Image', '/Cleanup-Mountpoints',
    '/Remount-Image', '/Set-ProductKey', '/ScratchDir'
)

function Get-XboxOSPreflightEngineVersion {
    [CmdletBinding()]
    param()
    return $script:XboxOSPreflightEngineVersion
}

function Get-XboxOSReadOnlyDismAdapterVersion {
    [CmdletBinding()]
    param()
    return $script:XboxOSReadOnlyDismAdapterVersion
}

function Get-XboxOSExpectedSourceIsoSha256 {
    [CmdletBinding()]
    param()
    return $script:XboxOSExpectedIsoSha256
}

function Test-XboxOSDismArgumentListAllowed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$ArgumentList
    )

    $joined = ($ArgumentList -join ' ')
    foreach ($token in $script:XboxOSProhibitedDismTokens) {
        if ($joined -match [regex]::Escape($token)) {
            return [pscustomobject]@{
                Allowed = $false
                Reason  = "Prohibited DISM token detected: $token"
                Class   = 'Prohibited'
            }
        }
    }

    # Writable mount without /ReadOnly is prohibited.
    if ($joined -match '/Mount-Image' -and $joined -notmatch '/ReadOnly') {
        return [pscustomobject]@{
            Allowed = $false
            Reason  = 'Mount-Image without /ReadOnly is prohibited.'
            Class   = 'Prohibited'
        }
    }

    return [pscustomobject]@{
        Allowed = $true
        Reason  = 'No prohibited tokens detected in raw scan.'
        Class   = 'Unknown'
    }
}

function Resolve-XboxOSReadOnlyDismArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ $script:XboxOSReadOnlyDismOperations.Keys -contains $_ })]
        [string]$Operation,

        [hashtable]$Parameters = @{}
    )

    $spec = $script:XboxOSReadOnlyDismOperations[$Operation]
    $args = foreach ($part in @($spec.Template)) {
        $resolved = [string]$part
        foreach ($key in @($Parameters.Keys)) {
            $token = '{' + [string]$key + '}'
            $resolved = $resolved.Replace($token, [string]$Parameters[$key])
        }
        if ($resolved -match '\{[A-Za-z]+\}') {
            throw "Unresolved DISM template parameter in operation '${Operation}': ${resolved}"
        }
        $resolved
    }

    $scan = Test-XboxOSDismArgumentListAllowed -ArgumentList @($args)
    if (-not $scan.Allowed) {
        throw ("Allowlist build produced prohibited arguments for '{0}': {1}" -f $Operation, $scan.Reason)
    }

    return [pscustomobject]@{
        Operation   = $Operation
        Class       = [string]$spec.Class
        ArgumentList = @($args)
        AdapterVersion = Get-XboxOSReadOnlyDismAdapterVersion
    }
}

function Assert-XboxOSReadOnlyDismOperationAllowed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Operation,
        [hashtable]$Parameters = @{}
    )

    if ($script:XboxOSReadOnlyDismOperations.Keys -notcontains $Operation) {
        throw ("DISM operation '{0}' is not in the readonly-dism-v1 allowlist." -f $Operation)
    }
    $built = Resolve-XboxOSReadOnlyDismArguments -Operation $Operation -Parameters $Parameters
    return $built
}

function New-XboxOSMockReadOnlyDismAdapter {
    [CmdletBinding()]
    param(
        [ValidateSet('Success', 'ExportInterrupted', 'MountFailed', 'UnmountFailed', 'CorruptWim', 'VersionProbeFailed')]
        [string]$FailureMode = 'Success',

        [string]$FixtureRoot = ''
    )

    if (-not $FixtureRoot) {
        $FixtureRoot = Join-Path (Get-XboxOSRepoRoot) 'tests\Fixtures'
    }

    $ctx = [pscustomobject]@{
        Kind                     = 'mock-readonly-dism'
        FailureMode              = $FailureMode
        FixtureRoot              = $FixtureRoot
        Commands                 = [System.Collections.ArrayList]@()
        MountOwned               = $false
        MountDir                 = $null
        SourceIsoModified        = $false
        ModifyingCommandsInvoked = $false
        RealDismExecutionEnabled = $false
    }

    $adapter = New-Object psobject
    Add-Member -InputObject $adapter -NotePropertyName Ctx -NotePropertyValue $ctx
    Add-Member -InputObject $adapter -MemberType ScriptMethod -Name InvokeOperation -Value {
        param(
            [string]$Operation,
            [hashtable]$Parameters
        )
        $built = Assert-XboxOSReadOnlyDismOperationAllowed -Operation $Operation -Parameters $Parameters
        $null = $this.Ctx.Commands.Add([pscustomobject]@{
                utc        = [datetime]::UtcNow
                operation  = $Operation
                class      = $built.Class
                arguments  = $built.ArgumentList
                exitCode   = 0
            })

        if ($this.Ctx.FailureMode -eq 'VersionProbeFailed' -and $Operation -eq 'GetDismVersion') {
            throw 'Simulated DISM version probe failure'
        }
        if ($this.Ctx.FailureMode -eq 'ExportInterrupted' -and $Operation -eq 'ExportImage') {
            throw 'Simulated disposable WIM export interrupted'
        }
        if ($this.Ctx.FailureMode -eq 'MountFailed' -and $Operation -eq 'MountImageReadOnly') {
            throw 'Simulated read-only mount failure'
        }
        if ($this.Ctx.FailureMode -eq 'CorruptWim' -and $Operation -eq 'GetExportedImageInfo') {
            throw 'Simulated corrupt disposable WIM'
        }
        if ($this.Ctx.FailureMode -eq 'UnmountFailed' -and $Operation -eq 'UnmountDiscard') {
            throw 'Simulated unmount discard failure'
        }

        $output = @('Mock DISM OK', "Operation=$Operation")
        switch ($Operation) {
            'GetDismVersion' {
                $output = @('Deployment Image Servicing and Management tool', 'Version: 10.0.26100.1')
            }
            'GetImageInfo' {
                $output = @(
                    'Index : 1',
                    'Name : Windows 11 Home',
                    'Index : 6',
                    'Name : Windows 11 Pro',
                    'Description : Windows 11 Pro',
                    "Version : $($script:XboxOSExpectedBuildNumber)"
                )
            }
            'GetExportedImageInfo' {
                $output = @(
                    'Index : 1',
                    'Name : Windows 11 Pro',
                    "Version : $($script:XboxOSExpectedBuildNumber)"
                )
            }
            'MountImageReadOnly' {
                $this.Ctx.MountOwned = $true
                $this.Ctx.MountDir = [string]$Parameters.MountDir
                $output = @('Mounting image', 'The operation completed successfully.')
            }
            'GetPackages' {
                $path = Join-Path $this.Ctx.FixtureRoot 'dism-get-packages-26300.9457.txt'
                if (Test-Path -LiteralPath $path) { $output = @(Get-Content -LiteralPath $path) }
            }
            'GetProvisionedAppxPackages' {
                $path = Join-Path $this.Ctx.FixtureRoot 'dism-get-appx-26300.9457.txt'
                if (Test-Path -LiteralPath $path) { $output = @(Get-Content -LiteralPath $path) }
            }
            'GetFeatures' {
                $path = Join-Path $this.Ctx.FixtureRoot 'dism-get-features-26300.9457.txt'
                if (Test-Path -LiteralPath $path) { $output = @(Get-Content -LiteralPath $path) }
            }
            'GetMountedImageInfo' {
                if ($this.Ctx.MountOwned) {
                    $output = @("Mount Dir : $($this.Ctx.MountDir)", 'Status : Ok', 'Read Only : Yes')
                }
                else {
                    $output = @('No mounted images found.')
                }
            }
            'UnmountDiscard' {
                $this.Ctx.MountOwned = $false
                $this.Ctx.MountDir = $null
                $output = @('Unmounting image', 'The operation completed successfully.')
            }
            'ExportImage' {
                $dest = [string]$Parameters.DestinationImageFile
                if ($dest) {
                    New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force -ErrorAction SilentlyContinue | Out-Null
                    Set-Content -LiteralPath $dest -Value 'MOCK-DISPOSABLE-WIM' -Encoding ascii
                }
                $output = @('Exporting image', 'The operation completed successfully.')
            }
        }

        $this.Ctx.ModifyingCommandsInvoked = $false
        $this.Ctx.RealDismExecutionEnabled = $false
        $this.Ctx.SourceIsoModified = $false
        return [pscustomobject]@{
            ExitCode                 = 0
            Output                   = $output
            Operation                = $Operation
            Class                    = $built.Class
            ArgumentList             = $built.ArgumentList
            ModifyingCommandsInvoked = $false
            RealDismExecutionEnabled = $false
        }
    }
    return $adapter
}

function Test-XboxOSSourceImagePrerequisites {
    [CmdletBinding()]
    param(
        [string]$IsoPath = 'C:\XboxOS\Sources\Windows11_Client_x64_en-us_26300_9457.iso',
        [string]$ExpectedSha256 = '',
        [string]$WorkRoot = 'C:\XboxOS\Work',
        [string]$LogsRoot = 'C:\XboxOS\Logs',
        [long]$MinimumFreeBytes = 20GB,
        [switch]$RequireAdministrator,
        [switch]$RequireIsoPresent,
        [object[]]$ExistingMounts = @()
    )

    if (-not $ExpectedSha256) { $ExpectedSha256 = Get-XboxOSExpectedSourceIsoSha256 }
    $errors = New-Object System.Collections.Generic.List[string]
    $repoRoot = Get-XboxOSRepoRoot

    try { $null = Assert-XboxOSServicingPathSafety -Path $WorkRoot -RepoRoot $repoRoot -Purpose 'disposable work root' }
    catch { $errors.Add([string]$_.Exception.Message) | Out-Null }
    try { $null = Assert-XboxOSServicingPathSafety -Path $LogsRoot -RepoRoot $repoRoot -Purpose 'preflight logs' }
    catch { $errors.Add([string]$_.Exception.Message) | Out-Null }

    if ($WorkRoot -match '(?i)OneDrive' -or $LogsRoot -match '(?i)OneDrive') {
        $errors.Add('Work/Logs paths must not be under OneDrive.') | Out-Null
    }

    if ($RequireAdministrator -and -not (Test-XboxOSAdministrator)) {
        $errors.Add('Administrator elevation is required for live read-only preflight.') | Out-Null
    }

    $isoPresent = Test-Path -LiteralPath $IsoPath
    $actualSha = $null
    if ($RequireIsoPresent -and -not $isoPresent) {
        $errors.Add("Source ISO not found: $IsoPath") | Out-Null
    }
    elseif ($isoPresent -and $RequireIsoPresent) {
        $hashInfo = Get-XboxOSFileHash -Path $IsoPath
        $actualSha = [string]$hashInfo.Hash
        if (-not [string]::Equals($actualSha, [string]$ExpectedSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            $errors.Add("Source ISO SHA256 mismatch. expected=${ExpectedSha256} actual=${actualSha}") | Out-Null
        }
    }

    $drive = [System.IO.Path]::GetPathRoot($WorkRoot)
    if ($drive -and (Test-Path -LiteralPath $drive)) {
        $free = (Get-PSDrive -Name $drive.TrimEnd('\').TrimEnd(':')).Free
        if ($null -ne $free -and [long]$free -lt $MinimumFreeBytes) {
            $errors.Add(("Insufficient free space on {0}: {1} bytes < {2}" -f $drive, $free, $MinimumFreeBytes)) | Out-Null
        }
    }

    $unrelated = @($ExistingMounts | Where-Object { $_ -and $_.MountDir -and $_.MountDir -notlike ($WorkRoot.TrimEnd('\') + '\*') })
    if ($unrelated.Count -gt 0) {
        $errors.Add(('Existing unrelated DISM mounts detected: {0}' -f (($unrelated | ForEach-Object { $_.MountDir }) -join '; '))) | Out-Null
    }

    return [pscustomobject]@{
        imageIntegritySchemaVersion = $script:XboxOSImageIntegritySchemaVersion
        valid                       = ($errors.Count -eq 0)
        errors                      = $errors.ToArray()
        isoPath                     = $IsoPath
        isoPresent                  = $isoPresent
        expectedSha256              = $ExpectedSha256
        actualSha256                = $actualSha
        workRoot                    = $WorkRoot
        logsRoot                    = $LogsRoot
        failClosed                  = ($errors.Count -gt 0)
    }
}

function New-XboxOSDisposableWorkspace {
    [CmdletBinding()]
    param(
        [string]$WorkRoot = 'C:\XboxOS\Work',
        [string]$OwnerId = ''
    )

    $repoRoot = Get-XboxOSRepoRoot
    $null = Assert-XboxOSServicingPathSafety -Path $WorkRoot -RepoRoot $repoRoot -Purpose 'disposable workspace'
    if (-not $OwnerId) { $OwnerId = 'owner-{0}' -f [guid]::NewGuid().ToString('N') }

    $stamp = [datetime]::UtcNow.ToString('yyyyMMddHHmmssfff')
    $workspacePath = Join-Path $WorkRoot ("preflight-{0}" -f $stamp)
    $mountDir = Join-Path $workspacePath 'mount'
    $wimPath = Join-Path $workspacePath 'install-pro-disposable.wim'

    return [pscustomobject]@{
        workspaceSchemaVersion = $script:XboxOSDisposableWorkspaceSchemaVersion
        ownerId                = $OwnerId
        workRoot               = $WorkRoot
        workspacePath          = $workspacePath
        mountDir               = $mountDir
        disposableWimPath      = $wimPath
        createdUtc             = [datetime]::UtcNow
        ownershipToken         = Get-XboxOSUtf8Sha256Hex -Text ("{0}|{1}|{2}" -f $OwnerId, $workspacePath, $wimPath)
        sourceIsoProtected     = $true
    }
}

function Assert-XboxOSDisposableWorkspaceOwnership {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Workspace,
        [Parameter(Mandatory)][string]$OwnershipToken,
        [string]$CandidateMountDir = ''
    )

    $expected = Get-XboxOSUtf8Sha256Hex -Text ("{0}|{1}|{2}" -f $Workspace.ownerId, $Workspace.workspacePath, $Workspace.disposableWimPath)
    if ($OwnershipToken -ne $expected -or $OwnershipToken -ne $Workspace.ownershipToken) {
        throw 'Disposable workspace ownership token mismatch.'
    }
    if ($CandidateMountDir) {
        $root = $Workspace.workspacePath.TrimEnd('\')
        if (-not ($CandidateMountDir.StartsWith($root, [StringComparison]::OrdinalIgnoreCase))) {
            throw ("Refusing cleanup of mount outside owned workspace: {0}" -f $CandidateMountDir)
        }
    }
    return $true
}

function Get-XboxOSDependencyCategoryEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Inventory,
        [Parameter(Mandatory)][object]$CompatibilityManifest
    )

    $protected = @(Get-XboxOSProtectedAppxPatterns -CompatibilityManifest $CompatibilityManifest)
    $appx = @($Inventory.appxPackages | ForEach-Object { [string]$_ })

    $categories = @(
        [ordered]@{ id = 'XboxInfrastructure'; patterns = @('*Xbox*', '*GamingApp*'); required = $true }
        [ordered]@{ id = 'GamingServices'; patterns = @('*GamingServices*', '*XboxGameCallableUI*'); required = $true }
        [ordered]@{ id = 'MicrosoftStore'; patterns = @('*WindowsStore*', '*StorePurchaseApp*', '*SecHealthUI*'); required = $true }
        [ordered]@{ id = 'XboxIdentity'; patterns = @('*XboxIdentityProvider*', '*Xbox.TCUI*'); required = $true }
        [ordered]@{ id = 'GameBar'; patterns = @('*XboxGameOverlay*', '*GameBar*'); required = $true }
        [ordered]@{ id = 'Servicing'; patterns = @(); featureHints = @('NetFx3*', 'Microsoft-Windows-Subsystem-Linux'); required = $true }
        [ordered]@{ id = 'GraphicsAudio'; patterns = @(); featureHints = @(); required = $false }
        [ordered]@{ id = 'MediaPlayback'; patterns = @('*ZuneMusic*', '*ZuneVideo*', '*YourPhone*'); required = $false }
        [ordered]@{ id = 'ControllerSupport'; patterns = @('*XboxSpeechToTextOverlay*', '*Xbox.TCUI*'); required = $false }
        [ordered]@{ id = 'NetworkingSecurity'; patterns = @('*SecHealthUI*'); featureHints = @('SMB1Protocol*'); required = $true }
    )

    $rows = foreach ($cat in $categories) {
        $hits = @()
        foreach ($pattern in @($cat.patterns)) {
            $hits += @($appx | Where-Object { $_ -like $pattern })
        }
        $protectedHits = @($hits | Where-Object { Test-XboxOSPackageProtected -PackageName $_ -ProtectedPatterns $protected })
        $outcome = if ($hits.Count -eq 0 -and $cat.required) {
            'MissingEvidence'
        }
        elseif ($hits.Count -eq 0) {
            'Unknown'
        }
        elseif ($protectedHits.Count -gt 0 -or $cat.required) {
            'Verified'
        }
        else {
            'Unknown'
        }

        [pscustomobject]@{
            category     = [string]$cat.id
            outcome      = $outcome
            evidenceCount = $hits.Count
            protectedHits = $protectedHits.Count
            provenance   = 'inventory+compatibility.protectedAppxPatterns'
            samples      = @($hits | Select-Object -First 3)
            note         = 'Absence from protected patterns alone never proves removal safety.'
        }
    }

    $aggregate = if (@($rows | Where-Object outcome -eq 'MissingEvidence').Count -gt 0) {
        'MissingEvidence'
    }
    elseif (@($rows | Where-Object outcome -eq 'Unknown').Count -gt 0) {
        'Unknown'
    }
    else {
        'Verified'
    }

    return [pscustomobject]@{
        dependencySchemaVersion = 'dependency-v1'
        aggregateOutcome        = $aggregate
        failClosed              = ($aggregate -ne 'Verified')
        approvalCannotOverride  = $true
        categories              = @($rows)
        realDismExecutionEnabled = $false
    }
}

function New-XboxOSApprovalSigningPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$ApprovalBindingDocument,
        [Parameter(Mandatory)][string]$Nonce
    )

    $doc = [ordered]@{
        approvalAuthSchemaVersion = $script:XboxOSApprovalAuthSchemaVersion
        nonce                     = $Nonce
        binding                   = $ApprovalBindingDocument
    }
    return ConvertTo-XboxOSCanonicalJson -Value $doc
}

function New-XboxOSApprovalSignature {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CanonicalPayload,
        [Parameter(Mandatory)][string]$PrivateKeyPemPath
    )

    if (-not (Test-Path -LiteralPath $PrivateKeyPemPath)) {
        throw "Private key PEM not found: $PrivateKeyPemPath"
    }
    $pem = Get-Content -LiteralPath $PrivateKeyPemPath -Raw
    $rsa = [System.Security.Cryptography.RSA]::Create()
    try {
        $rsa.ImportFromPem($pem)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($CanonicalPayload)
        $sig = $rsa.SignData($bytes, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        return [Convert]::ToBase64String($sig)
    }
    finally {
        $rsa.Dispose()
    }
}

function Test-XboxOSApprovalSignature {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CanonicalPayload,
        [Parameter(Mandatory)][string]$SignatureBase64,
        [Parameter(Mandatory)][string]$PublicKeyPemPath
    )

    if (-not (Test-Path -LiteralPath $PublicKeyPemPath)) {
        throw "Public key PEM not found: $PublicKeyPemPath"
    }
    $pem = Get-Content -LiteralPath $PublicKeyPemPath -Raw
    $rsa = [System.Security.Cryptography.RSA]::Create()
    try {
        $rsa.ImportFromPem($pem)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($CanonicalPayload)
        $sig = [Convert]::FromBase64String($SignatureBase64)
        $ok = $rsa.VerifyData($bytes, $sig, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        return [pscustomobject]@{
            approvalAuthSchemaVersion = $script:XboxOSApprovalAuthSchemaVersion
            signatureValid            = [bool]$ok
            grantsRealDismExecution   = $false
            realDismExecutionEnabled  = $false
            executionAuthorized       = $false
            note                      = 'Signature validity never authorizes real DISM mutation.'
        }
    }
    finally {
        $rsa.Dispose()
    }
}

function New-XboxOSDisposableImagePreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][object]$CompatibilityManifest,
        [object]$BaselineInventory = $null,
        [object]$Adapter = $null,
        [ValidateSet('Simulation', 'LiveReadOnly')]
        [string]$Mode = 'Simulation',
        [string]$IsoPath = 'C:\XboxOS\Sources\Windows11_Client_x64_en-us_26300_9457.iso',
        [string]$WorkRoot = 'C:\XboxOS\Work',
        [string]$LogsRoot = 'C:\XboxOS\Logs'
    )

    if (-not $Adapter) {
        $Adapter = New-XboxOSMockReadOnlyDismAdapter
    }

    return [pscustomobject]@{
        preflightId                = ('preflight-{0}' -f [datetime]::UtcNow.ToString('yyyyMMddHHmmssfff'))
        preflightEngineVersion     = Get-XboxOSPreflightEngineVersion
        mode                       = $Mode
        plan                       = $Plan
        baselineInventory          = $BaselineInventory
        compatibilityManifest      = $CompatibilityManifest
        adapter                    = $Adapter
        isoPath                    = $IsoPath
        workRoot                   = $WorkRoot
        logsRoot                   = $LogsRoot
        workspace                  = $null
        prerequisites              = $null
        sourceImage                = $null
        freshInventory             = $null
        driftResult                = $null
        dependencyResult           = $null
        operationDependencyResult  = $null
        recomputedPlan             = $null
        preflightDecision          = 'NotEvaluated'
        transactionState           = 'Created'
        audit                      = [System.Collections.ArrayList]@()
        blockers                   = [System.Collections.ArrayList]@()
        commands                   = [System.Collections.ArrayList]@()
        mountOwned                 = $false
        cleanupStatus              = 'NotStarted'
        modifyingCommandsInvoked   = $false
        realDismExecutionEnabled   = $false
        executionAuthorized        = $false
        sourceIsoProtected         = $true
        liveReadOnlyAuthorized     = $false
    }
}

function Invoke-XboxOSDisposableImagePreflightSimulate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Preflight,
        [switch]$SkipWorkspaceFiles
    )

    if ($Preflight.mode -ne 'Simulation') {
        throw 'Invoke-XboxOSDisposableImagePreflightSimulate requires Mode=Simulation.'
    }

    $adapter = $Preflight.adapter
    $null = $Preflight.audit.Add((New-XboxOSAuditEvent -Type 'PreflightStart' -Message 'Simulation preflight started'))

    $Preflight.prerequisites = Test-XboxOSSourceImagePrerequisites `
        -IsoPath $Preflight.isoPath `
        -WorkRoot $Preflight.workRoot `
        -LogsRoot $Preflight.logsRoot `
        -RequireIsoPresent:$false `
        -RequireAdministrator:$false `
        -ExistingMounts @() `
        -MinimumFreeBytes 1KB

    if ($null -eq $Preflight.prerequisites -or -not [bool]$Preflight.prerequisites.valid) {
        foreach ($e in @($Preflight.prerequisites.errors)) { $null = $Preflight.blockers.Add($e) }
        $Preflight.transactionState = 'Failed'
        $Preflight.cleanupStatus = 'NotRequired'
        return $Preflight
    }

    $Preflight.transactionState = 'SourceVerified'
    $ver = $adapter.InvokeOperation('GetDismVersion', @{})
    $null = $Preflight.commands.Add($ver)

    $img = $adapter.InvokeOperation('GetImageInfo', @{ ImageFile = $Preflight.isoPath })
    $null = $Preflight.commands.Add($img)
    $images = @(ConvertFrom-XboxOSDismImageInfoOutput -Output @($img.Output))
    $resolved = Resolve-XboxOSExactImageIndex -Images $images -ExactName $script:XboxOSExpectedEditionName
    $Preflight.sourceImage = [pscustomobject]@{
        editionName    = [string]$resolved.Name
        sourceIndex    = [int]$resolved.Index
        buildNumber    = $script:XboxOSExpectedBuildNumber
        displayVersion = $script:XboxOSExpectedDisplayVersion
        isoSha256      = Get-XboxOSExpectedSourceIsoSha256
        isoPath        = $Preflight.isoPath
    }
    $Preflight.transactionState = 'WorkspacePrepared'

    $Preflight.workspace = New-XboxOSDisposableWorkspace -WorkRoot $Preflight.workRoot
    if (-not $SkipWorkspaceFiles) {
        $null = New-Item -ItemType Directory -Path $Preflight.workspace.workspacePath -Force
        $null = New-Item -ItemType Directory -Path $Preflight.workspace.mountDir -Force
    }

    try {
        $export = $adapter.InvokeOperation('ExportImage', @{
                SourceImageFile      = $Preflight.isoPath
                SourceIndex          = [string]$Preflight.sourceImage.sourceIndex
                DestinationImageFile = $Preflight.workspace.disposableWimPath
            })
        $null = $Preflight.commands.Add($export)
        $Preflight.transactionState = 'DisposableWimExported'

        $expInfo = $adapter.InvokeOperation('GetExportedImageInfo', @{ ImageFile = $Preflight.workspace.disposableWimPath })
        $null = $Preflight.commands.Add($expInfo)

        $mount = $adapter.InvokeOperation('MountImageReadOnly', @{
                ImageFile = $Preflight.workspace.disposableWimPath
                Index     = '1'
                MountDir  = $Preflight.workspace.mountDir
            })
        $null = $Preflight.commands.Add($mount)
        $Preflight.mountOwned = $true
        $Preflight.transactionState = 'ReadOnlyMounted'

        $pkg = $adapter.InvokeOperation('GetPackages', @{ MountDir = $Preflight.workspace.mountDir })
        $appx = $adapter.InvokeOperation('GetProvisionedAppxPackages', @{ MountDir = $Preflight.workspace.mountDir })
        $feat = $adapter.InvokeOperation('GetFeatures', @{ MountDir = $Preflight.workspace.mountDir })
        $null = $Preflight.commands.Add($pkg)
        $null = $Preflight.commands.Add($appx)
        $null = $Preflight.commands.Add($feat)

        $appxNames = @(ConvertFrom-XboxOSDismProvisionedAppxListOutput -Output @($appx.Output) | ForEach-Object { $_.PackageName })
        $features = @(ConvertFrom-XboxOSDismFeatureListOutput -Output @($feat.Output))
        $packages = @(ConvertFrom-XboxOSDismPackageListOutput -Output @($pkg.Output))

        $Preflight.freshInventory = New-XboxOSInventorySnapshot `
            -AppxAvailability Available `
            -FeatureAvailability Available `
            -AppxPackages $appxNames `
            -Features $features `
            -Packages $packages `
            -Source 'mock-readonly-adapter' `
            -VerificationStatus Authoritative `
            -SourceImage $Preflight.sourceImage `
            -AdvertisedAppxCount $appxNames.Count `
            -AdvertisedFeatureCount $features.Count `
            -AdvertisedPackageCount $packages.Count

        $Preflight.transactionState = 'InventoryCaptured'

        $Preflight.driftResult = Test-XboxOSInventoryDrift `
            -Plan $Preflight.plan `
            -FreshInventory $Preflight.freshInventory `
            -CompatibilityManifest $Preflight.compatibilityManifest

        if ($Preflight.freshInventory.inventoryFingerprint -ne $Preflight.plan.inventoryFingerprint) {
            $Preflight.recomputedPlan = New-XboxOSServicingPlan `
                -Inventory $Preflight.freshInventory `
                -RemoveAppsManifest (Import-XboxOSManifest -Path (Join-Path (Get-XboxOSRepoRoot) 'config\remove-apps.json')) `
                -DisableFeaturesManifest (Import-XboxOSManifest -Path (Join-Path (Get-XboxOSRepoRoot) 'config\disable-features.json')) `
                -CompatibilityManifest $Preflight.compatibilityManifest
            $null = $Preflight.blockers.Add('Inventory fingerprint differs from plan; recomputed plan hash recorded; prior approvals are invalid.')
        }

        $Preflight.dependencyResult = Get-XboxOSDependencyCategoryEvidence `
            -Inventory $Preflight.freshInventory `
            -CompatibilityManifest $Preflight.compatibilityManifest

        $depOps = Test-XboxOSDependencySafety -Plan $Preflight.plan -DependencyEvidence @()
        $Preflight.operationDependencyResult = $depOps
        if ($depOps.failClosed) {
            $null = $Preflight.blockers.Add(('Eligible operation dependencies remain {0}; approval cannot override.' -f $depOps.aggregateOutcome))
        }
        if ($Preflight.dependencyResult.failClosed) {
            $null = $Preflight.blockers.Add(('Dependency categories: {0}' -f $Preflight.dependencyResult.aggregateOutcome))
        }
        if ($Preflight.driftResult.failClosed) {
            $null = $Preflight.blockers.Add(('Drift: {0}' -f $Preflight.driftResult.result))
        }

        $Preflight.transactionState = 'DriftEvaluated'

        $null = Assert-XboxOSDisposableWorkspaceOwnership -Workspace $Preflight.workspace -OwnershipToken $Preflight.workspace.ownershipToken -CandidateMountDir $Preflight.workspace.mountDir
        $unmount = $adapter.InvokeOperation('UnmountDiscard', @{ MountDir = $Preflight.workspace.mountDir })
        $null = $Preflight.commands.Add($unmount)
        $Preflight.mountOwned = $false
        $Preflight.transactionState = 'ReadOnlyUnmounted'
        $Preflight.cleanupStatus = 'Succeeded'
        $Preflight.transactionState = 'Completed'
    }
    catch {
        $null = $Preflight.blockers.Add([string]$_.Exception.Message)
        $Preflight.transactionState = 'RecoveryRequired'
        try {
            if ($Preflight.workspace -and $Preflight.mountOwned) {
                $null = Assert-XboxOSDisposableWorkspaceOwnership -Workspace $Preflight.workspace -OwnershipToken $Preflight.workspace.ownershipToken -CandidateMountDir $Preflight.workspace.mountDir
                $null = $adapter.InvokeOperation('UnmountDiscard', @{ MountDir = $Preflight.workspace.mountDir })
                $Preflight.mountOwned = $false
                $Preflight.cleanupStatus = 'Recovered'
                $Preflight.transactionState = 'Aborted'
            }
            else {
                $Preflight.cleanupStatus = 'NotRequired'
                $Preflight.transactionState = 'Failed'
            }
        }
        catch {
            $null = $Preflight.blockers.Add(('Cleanup failure: {0}' -f $_.Exception.Message))
            $Preflight.cleanupStatus = 'Failed'
            $Preflight.transactionState = 'Failed'
        }
    }

    $Preflight.modifyingCommandsInvoked = $false
    $Preflight.realDismExecutionEnabled = $false
    $Preflight.executionAuthorized = $false
    $Preflight.sourceIsoProtected = -not [bool]$adapter.Ctx.SourceIsoModified
    Assert-XboxOSExecutionSafetyInvariants -Transaction ([pscustomobject]@{
            modifyingCommandsInvoked = $Preflight.modifyingCommandsInvoked
            executionAuthorized      = $Preflight.executionAuthorized
            realDismExecutionEnabled = $Preflight.realDismExecutionEnabled
        })

    $lifecycleOk = (
        $Preflight.transactionState -eq 'Completed' -and
        $Preflight.cleanupStatus -eq 'Succeeded' -and
        -not $Preflight.mountOwned
    )
    if (-not $lifecycleOk) {
        $Preflight.preflightDecision = 'Failed'
    }
    elseif (@($Preflight.blockers).Count -gt 0) {
        $Preflight.preflightDecision = 'Blocked'
    }
    else {
        $Preflight.preflightDecision = 'ReadyForReview'
    }

    $null = $Preflight.audit.Add((New-XboxOSAuditEvent -Type 'PreflightEnd' -Message ("state={0} decision={1}" -f $Preflight.transactionState, $Preflight.preflightDecision)))
    return $Preflight
}

function Assert-XboxOSLiveReadOnlyPreflightAuthorization {
    [CmdletBinding()]
    param(
        [switch]$ConfirmLiveReadOnlyPreflight,
        [switch]$AllowLiveReadOnlyPreflight
    )

    if (-not $ConfirmLiveReadOnlyPreflight) {
        throw 'Live read-only preflight requires -ConfirmLiveReadOnlyPreflight.'
    }
    if (-not $AllowLiveReadOnlyPreflight) {
        throw 'Live read-only preflight is implemented but disabled until explicit post-review operator authorization (-AllowLiveReadOnlyPreflight).'
    }
}

function Save-XboxOSDisposableImagePreflightReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Preflight,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [string]$Stem = 'XboxOS11-disposable-preflight'
    )

    if ($OutputDirectory -match '(?i)OneDrive') {
        throw "Refusing to write preflight reports under OneDrive: $OutputDirectory"
    }
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

    if ($Preflight.cleanupStatus -eq 'Failed' -or $Preflight.mountOwned) {
        $null = $Preflight.blockers.Add('Cleanup incomplete or mount ownership still held; cannot report unconditional success.')
    }

    $lifecycleOk = (
        $Preflight.transactionState -eq 'Completed' -and
        $Preflight.cleanupStatus -eq 'Succeeded' -and
        -not $Preflight.mountOwned -and
        -not $Preflight.modifyingCommandsInvoked -and
        -not $Preflight.realDismExecutionEnabled -and
        -not $Preflight.executionAuthorized
    )
    $decision = if (-not $lifecycleOk) {
        'Failed'
    }
    elseif (@($Preflight.blockers).Count -gt 0) {
        'Blocked'
    }
    else {
        'ReadyForReview'
    }
    $Preflight.preflightDecision = $decision
    $success = [bool]($lifecycleOk -and $decision -eq 'ReadyForReview')

    $report = [ordered]@{
        reportType                 = 'disposable-image-preflight'
        generatedUtc               = [datetime]::UtcNow
        preflightEngineVersion     = $Preflight.preflightEngineVersion
        mode                       = $Preflight.mode
        preflightId                = $Preflight.preflightId
        transactionState           = $Preflight.transactionState
        preflightDecision          = $decision
        lifecycleCompleted         = [bool]$lifecycleOk
        success                    = [bool]$success
        sourceImage                = $Preflight.sourceImage
        expectedIsoSha256          = Get-XboxOSExpectedSourceIsoSha256
        prerequisites              = $Preflight.prerequisites
        workspace                  = $(if ($Preflight.workspace) {
                [pscustomobject]@{
                    path           = $Preflight.workspace.workspacePath
                    disposableWim  = $Preflight.workspace.disposableWimPath
                    ownershipToken = $Preflight.workspace.ownershipToken
                }
            } else { $null })
        inventoryFingerprint       = $(if ($Preflight.freshInventory) { $Preflight.freshInventory.inventoryFingerprint } else { $null })
        inventoryTotals            = $(if ($Preflight.freshInventory) {
                [pscustomobject]@{
                    appx     = @($Preflight.freshInventory.appxPackages).Count
                    features = @($Preflight.freshInventory.features).Count
                    packages = @($Preflight.freshInventory.packages).Count
                }
            } else { $null })
        driftResult                = $Preflight.driftResult
        dependencyResult           = $Preflight.dependencyResult
        planContentHash            = $Preflight.plan.contentHash
        recomputedPlanContentHash  = $(if ($Preflight.recomputedPlan) { $Preflight.recomputedPlan.contentHash } else { $null })
        blockers                   = @($Preflight.blockers | ForEach-Object { [string]$_ })
        commands                   = @($Preflight.commands | ForEach-Object {
                [pscustomobject]@{
                    operation  = $_.Operation
                    class      = $_.Class
                    exitCode   = $_.ExitCode
                    arguments  = @($_.ArgumentList)
                }
            })
        mountOwned                 = [bool]$Preflight.mountOwned
        cleanupStatus              = [string]$Preflight.cleanupStatus
        modifyingCommandsInvoked   = $false
        realDismExecutionEnabled   = $false
        executionAuthorized        = $false
        sourceIsoProtected         = [bool]$Preflight.sourceIsoProtected
        notes                      = @(
            'Milestone 4 disposable-image preflight report.'
            'Simulation mode uses mocks/fixtures; live read-only mode remains gated.'
            'Success never authorizes writable DISM servicing.'
        )
    }

    $jsonPath = Join-Path $OutputDirectory ($Stem + '.json')
    $mdPath = Join-Path $OutputDirectory ($Stem + '.md')
    ([pscustomobject]$report | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $jsonPath -Encoding UTF8

    $md = New-Object System.Collections.Generic.List[string]
    $null = $md.Add('# XboxOS11 Disposable Image Preflight (Milestone 4)')
    $null = $md.Add('')
    $null = $md.Add(('- Mode: **{0}**' -f $report.mode))
    $null = $md.Add(('- State: **{0}**' -f $report.transactionState))
    $null = $md.Add(('- Success: **{0}**' -f $report.success))
    $null = $md.Add(('- Plan content hash: `{0}`' -f $report.planContentHash))
    $null = $md.Add(('- Drift: **{0}**' -f $(if ($report.driftResult) { $report.driftResult.result } else { 'n/a' })))
    $null = $md.Add(('- Dependencies: **{0}**' -f $(if ($report.dependencyResult) { $report.dependencyResult.aggregateOutcome } else { 'n/a' })))
    $null = $md.Add(('- Cleanup: **{0}**' -f $report.cleanupStatus))
    $null = $md.Add(('- Mount owned: **{0}**' -f $report.mountOwned))
    $null = $md.Add(('- Modifying commands invoked: **{0}**' -f $report.modifyingCommandsInvoked))
    $null = $md.Add(('- Real DISM execution enabled: **{0}**' -f $report.realDismExecutionEnabled))
    $null = $md.Add(('- Execution authorized: **{0}**' -f $report.executionAuthorized))
    $null = $md.Add(('- Source ISO protected: **{0}**' -f $report.sourceIsoProtected))
    $null = $md.Add('')
    $null = $md.Add('## Blockers')
    $null = $md.Add('')
    if (@($report.blockers).Count -eq 0) { $null = $md.Add('_None_') }
    else { foreach ($b in @($report.blockers)) { $null = $md.Add(('- {0}' -f $b)) } }

    ($md -join [Environment]::NewLine) + [Environment]::NewLine | Set-Content -LiteralPath $mdPath -Encoding UTF8

    return [pscustomobject]@{ Json = $jsonPath; Markdown = $mdPath; Report = [pscustomobject]$report }
}
