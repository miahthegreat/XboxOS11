# Milestone 4 disposable-image read-only preflight. Dotted into XboxOS.Build.psm1.
# Live DISM mounts/exports are gated; CI uses mocks/fixtures only.

$script:XboxOSPreflightEngineVersion = '4.1.0'
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
    ExportImage                 = [ordered]@{ Class = 'DisposablePreparation'; Template = @('/English', '/Export-Image', '/SourceImageFile:{SourceImageFile}', '/SourceIndex:{SourceIndex}', '/DestinationImageFile:{DestinationImageFile}', '/Compress:max', '/CheckIntegrity') }
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

function Test-XboxOSDismArgumentListMatchesAllowlist {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$ArgumentList
    )

    foreach ($operation in @($script:XboxOSReadOnlyDismOperations.Keys)) {
        $template = @($script:XboxOSReadOnlyDismOperations[$operation].Template)
        if ($template.Count -ne @($ArgumentList).Count) {
            continue
        }
        $matched = $true
        for ($i = 0; $i -lt $template.Count; $i++) {
            $token = [string]$template[$i]
            $actual = [string]$ArgumentList[$i]
            if ($token -match '^(?<prefix>.+):\{[A-Za-z]+\}$') {
                $prefix = $Matches['prefix'] + ':'
                if (-not $actual.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $matched = $false
                    break
                }
                $value = $actual.Substring($prefix.Length)
                if ([string]::IsNullOrWhiteSpace($value) -or (Test-XboxOSPathContainsTraversal -Path $value)) {
                    $matched = $false
                    break
                }
            }
            elseif ($token -match '\{[A-Za-z]+\}') {
                if ([string]::IsNullOrWhiteSpace($actual) -or (Test-XboxOSPathContainsTraversal -Path $actual)) {
                    $matched = $false
                    break
                }
            }
            elseif (-not [string]::Equals($token, $actual, [System.StringComparison]::OrdinalIgnoreCase)) {
                $matched = $false
                break
            }
        }
        if ($matched) {
            return [pscustomobject]@{
                Allowed   = $true
                Reason    = "Matched allowlisted operation '$operation'."
                Class     = [string]$script:XboxOSReadOnlyDismOperations[$operation].Class
                Operation = $operation
            }
        }
    }

    return [pscustomobject]@{
        Allowed   = $false
        Reason    = 'Argument list does not match any readonly-dism-v1 operation template.'
        Class     = 'Prohibited'
        Operation = $null
    }
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

    $shape = Test-XboxOSDismArgumentListMatchesAllowlist -ArgumentList @($ArgumentList)
    if (-not $shape.Allowed) {
        return $shape
    }

    return [pscustomobject]@{
        Allowed   = $true
        Reason    = $shape.Reason
        Class     = $shape.Class
        Operation = $shape.Operation
    }
}

function Test-XboxOSContinuousIntegrationEnvironment {
    [CmdletBinding()]
    param()

    return [bool](
        ($env:GITHUB_ACTIONS -eq 'true') -or
        ($env:CI -eq 'true') -or
        ($env:TF_BUILD -eq 'True')
    )
}

function Assert-XboxOSInventoryCompletenessForPreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Inventory
    )

    if ($Inventory.verificationStatus -ne 'Authoritative') {
        throw ("Fresh inventory verificationStatus must be Authoritative; was '{0}'." -f $Inventory.verificationStatus)
    }
    $pkgCount = @($Inventory.packages).Count
    $appxCount = @($Inventory.appxPackages).Count
    $featCount = @($Inventory.features).Count
    if ($pkgCount -lt 1) { throw 'Incomplete inventory: no DISM packages captured.' }
    if ($appxCount -lt 1) { throw 'Incomplete inventory: no provisioned AppX packages captured.' }
    if ($featCount -lt 1) { throw 'Incomplete inventory: no optional features captured.' }
    if ($null -ne $Inventory.advertisedPackageCount -and [int]$Inventory.advertisedPackageCount -ne $pkgCount) {
        throw 'Contradictory package inventory counts.'
    }
    if ($null -ne $Inventory.advertisedAppxCount -and [int]$Inventory.advertisedAppxCount -ne $appxCount) {
        throw 'Contradictory AppX inventory counts.'
    }
    if ($null -ne $Inventory.advertisedFeatureCount -and [int]$Inventory.advertisedFeatureCount -ne $featCount) {
        throw 'Contradictory feature inventory counts.'
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
            $Parameters = $null
        )
        if ($null -eq $Parameters) { $Parameters = @{} }
        elseif ($Parameters -isnot [hashtable]) { $Parameters = [hashtable]$Parameters }
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
        [object[]]$ExistingMounts = @(),
        [scriptblock]$HashProvider = $null
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
    if ($IsoPath -match '(?i)OneDrive') {
        $errors.Add('Source ISO path must not be under OneDrive.') | Out-Null
    }
    if (Test-XboxOSPathContainsTraversal -Path $IsoPath) {
        $errors.Add("Source ISO path contains traversal segments: $IsoPath") | Out-Null
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
        $actualSha = Get-XboxOSSourceIsoSha256ForPreflight -IsoPath $IsoPath -HashProvider $HashProvider
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

function Test-XboxOSPathContainsTraversal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    return [bool]($Path -match '(^|[\\/])\.\.([\\/]|$)')
}

function Test-XboxOSPathIsReparsePoint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }
    $item = Get-Item -LiteralPath $Path -Force
    return [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
}

function Assert-XboxOSPathOwnedAndSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CandidatePath,
        [Parameter(Mandatory)][string]$WorkspaceRoot
    )

    if (Test-XboxOSPathContainsTraversal -Path $CandidatePath) {
        throw "Refusing path with traversal segments: $CandidatePath"
    }
    $full = Get-XboxOSCanonicalPath -Path $CandidatePath
    $root = Get-XboxOSCanonicalPath -Path $WorkspaceRoot
    if (-not (Test-XboxOSPathEqualsOrUnder -Path $full -ParentPath $root)) {
        throw "Refusing path outside owned workspace. path=$full workspace=$root"
    }
    if (Test-XboxOSPathIsReparsePoint -Path $full) {
        throw "Refusing reparse point (symlink/junction) path: $full"
    }
    # Walk parents within workspace for reparse redirection.
    $cursor = $full
    while ($cursor -and (Test-XboxOSPathEqualsOrUnder -Path $cursor -ParentPath $root)) {
        if (($cursor -ne $root) -and (Test-Path -LiteralPath $cursor) -and (Test-XboxOSPathIsReparsePoint -Path $cursor)) {
            throw "Refusing reparse point in owned path chain: $cursor"
        }
        $parent = Split-Path -Parent $cursor
        if (-not $parent -or $parent -eq $cursor) { break }
        $cursor = $parent
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
        Assert-XboxOSPathOwnedAndSafe -CandidatePath $CandidateMountDir -WorkspaceRoot $Workspace.workspacePath
    }
}

function ConvertFrom-XboxOSMountedImageInfoOutput {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]]$Output = @()
    )

    # Avoid [string[]] binding coercing a single string into a char[].
    $lines = New-Object System.Collections.ArrayList
    if ($Output -is [string]) {
        foreach ($part in @($Output -split '\r?\n')) { $null = $lines.Add([string]$part) }
    }
    else {
        foreach ($item in @($Output)) {
            if ($null -eq $item) { continue }
            $null = $lines.Add([string]$item)
        }
    }

    $mounts = New-Object System.Collections.ArrayList
    $current = $null
    foreach ($text in @($lines)) {
        if ($text -match '^\s*Mount Dir\s*:\s*(.+?)\s*$') {
            if ($null -ne $current) {
                $null = $mounts.Add([pscustomobject]@{
                        MountDir  = [string]$current.MountDir
                        Status    = $current.Status
                        ReadOnly  = $current.ReadOnly
                        ImageFile = $current.ImageFile
                    })
            }
            $current = [pscustomobject]@{
                MountDir  = $Matches[1].Trim()
                Status    = $null
                ReadOnly  = $null
                ImageFile = $null
            }
        }
        elseif ($null -ne $current -and $text -match '^\s*Status\s*:\s*(.+?)\s*$') {
            $current.Status = $Matches[1].Trim()
        }
        elseif ($null -ne $current -and $text -match '^\s*Read Only\s*:\s*(.+?)\s*$') {
            $current.ReadOnly = $Matches[1].Trim()
        }
        elseif ($null -ne $current -and $text -match '^\s*Image File\s*:\s*(.+?)\s*$') {
            $current.ImageFile = $Matches[1].Trim()
        }
    }
    if ($null -ne $current) {
        $null = $mounts.Add($current)
    }
    return @($mounts.ToArray())
}

function Invoke-XboxOSNativeDismCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DismPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ArgumentList,
        [scriptblock]$Runner = $null
    )

    if ([string]::IsNullOrWhiteSpace($DismPath)) {
        throw 'DismPath is required for native DISM invocation.'
    }
    $scan = Test-XboxOSDismArgumentListAllowed -ArgumentList @($ArgumentList)
    if (-not $scan.Allowed) {
        throw ("Native DISM invocation rejected: {0}" -f $scan.Reason)
    }

    $display = "$DismPath $($ArgumentList -join ' ')"
    if ($Runner) {
        $result = & $Runner -DismPath $DismPath -ArgumentList @($ArgumentList)
        $exitCode = 0
        $output = @()
        if ($result -is [hashtable] -or $result -is [System.Collections.IDictionary]) {
            if ($result.ContainsKey('ExitCode')) { $exitCode = [int]$result.ExitCode }
            if ($result.ContainsKey('Output')) { $output = @($result.Output) }
        }
        else {
            if ($result.PSObject.Properties['ExitCode']) { $exitCode = [int]$result.ExitCode }
            if ($result.PSObject.Properties['Output']) { $output = @($result.Output) }
        }
        if ($exitCode -ne 0) {
            throw ("Injected DISM runner failed with exit code {0}. Command: {1}" -f $exitCode, $display)
        }
        return [pscustomobject]@{
            ExitCode     = $exitCode
            Output       = @($output)
            Command      = $display
            InvokedNative = $true
            UsedRunner   = $true
        }
    }

    if (-not (Test-Path -LiteralPath $DismPath)) {
        throw "DISM executable not found: $DismPath"
    }
    $output = & $DismPath @ArgumentList 2>&1
    $exitCode = $LASTEXITCODE
    $text = @($output | ForEach-Object { "$_" })
    if ($null -eq $exitCode) {
        throw "DISM did not return an exit code. Command: $display"
    }
    if ([int]$exitCode -ne 0) {
        throw ("DISM failed with exit code {0}. Command: {1}`n{2}" -f $exitCode, $display, ($text -join "`n"))
    }
    return [pscustomobject]@{
        ExitCode      = [int]$exitCode
        Output        = $text
        Command       = $display
        InvokedNative = $true
        UsedRunner    = $false
    }
}

function New-XboxOSRecordingDismRunner {
    [CmdletBinding()]
    param(
        [hashtable]$Responses = @{},
        [string]$FixtureRoot = '',
        [switch]$AutoFixtureResponses
    )

    if (-not $FixtureRoot) {
        $FixtureRoot = Join-Path (Get-XboxOSRepoRoot) 'tests\Fixtures'
    }

    $state = [hashtable]@{
        Calls       = [System.Collections.ArrayList]@()
        Responses   = $Responses
        FixtureRoot = $FixtureRoot
        MountDir    = $null
        MountOwned  = $false
        AutoFixture = [bool]$AutoFixtureResponses
    }

    $runner = {
        param(
            [string]$DismPath,
            [string[]]$ArgumentList
        )
        $null = $state.Calls.Add([pscustomobject]@{
                DismPath     = $DismPath
                ArgumentList = @($ArgumentList)
            })
        $key = ($ArgumentList -join ' ')
        foreach ($pattern in @($state.Responses.Keys)) {
            if ($key -like $pattern -or $key -eq $pattern) {
                return $state.Responses[$pattern]
            }
        }

        if ($state.AutoFixture) {
            if ($key -match '/Export-Image' -and $key -match '/DestinationImageFile:(?<dest>[^\s]+)') {
                $dest = $Matches['dest']
                New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force -ErrorAction SilentlyContinue | Out-Null
                Set-Content -LiteralPath $dest -Value 'MOCK-DISPOSABLE-WIM' -Encoding ascii
                return @{ ExitCode = 0; Output = @('Exporting image', 'The operation completed successfully.') }
            }
            if ($key -match '/Mount-Image' -and $key -match '/MountDir:(?<md>[^\s]+)') {
                $state.MountDir = $Matches['md']
                $state.MountOwned = $true
                return @{ ExitCode = 0; Output = @('Mounting image', 'The operation completed successfully.') }
            }
            if ($key -match '/Unmount-Image') {
                $state.MountOwned = $false
                $state.MountDir = $null
                return @{ ExitCode = 0; Output = @('Unmounting image', 'The operation completed successfully.') }
            }
            if ($key -match '/Get-MountedImageInfo') {
                if ($state.MountOwned -and $state.MountDir) {
                    return @{
                        ExitCode = 0
                        Output   = @(
                            "Mount Dir : $($state.MountDir)"
                            'Status : Ok'
                            'Read Only : Yes'
                            "Image File : disposable.wim"
                        )
                    }
                }
                return @{ ExitCode = 0; Output = @('No mounted images found.') }
            }
            if ($key -match '/\?' -or $key -eq '/English /?') {
                return @{ ExitCode = 0; Output = @('Deployment Image Servicing and Management tool', 'Version: 10.0.26100.1') }
            }
            if ($key -match '/Get-ImageInfo') {
                if ($key -match 'install-pro-disposable\.wim') {
                    return @{
                        ExitCode = 0
                        Output   = @(
                            'Index : 1'
                            'Name : Windows 11 Pro'
                            "Version : $($script:XboxOSExpectedBuildNumber)"
                        )
                    }
                }
                return @{
                    ExitCode = 0
                    Output   = @(
                        'Index : 1'
                        'Name : Windows 11 Home'
                        'Index : 6'
                        'Name : Windows 11 Pro'
                        'Description : Windows 11 Pro'
                        "Version : $($script:XboxOSExpectedBuildNumber)"
                    )
                }
            }
            if ($key -match '/Get-Packages') {
                $path = Join-Path $state.FixtureRoot 'dism-get-packages-26300.9457.txt'
                return @{ ExitCode = 0; Output = @(Get-Content -LiteralPath $path) }
            }
            if ($key -match '/Get-ProvisionedAppxPackages') {
                $path = Join-Path $state.FixtureRoot 'dism-get-appx-26300.9457.txt'
                return @{ ExitCode = 0; Output = @(Get-Content -LiteralPath $path) }
            }
            if ($key -match '/Get-Features') {
                $path = Join-Path $state.FixtureRoot 'dism-get-features-26300.9457.txt'
                return @{ ExitCode = 0; Output = @(Get-Content -LiteralPath $path) }
            }
        }

        return @{
            ExitCode = 0
            Output   = @('Recording runner default OK', "Args=$key")
        }
    }.GetNewClosure()

    return [pscustomobject]@{
        Runner = $runner
        State  = $state
        Calls  = $state.Calls
    }
}

function New-XboxOSRealReadOnlyDismAdapter {
    [CmdletBinding()]
    param(
        [string]$DismPath = '',
        [scriptblock]$NativeRunner = $null
    )

    if (-not $DismPath) {
        $DismPath = Find-XboxOSDism
    }
    if (-not $DismPath -and -not $NativeRunner) {
        throw 'DISM was not found and no NativeRunner was supplied.'
    }
    if (-not $DismPath) {
        $DismPath = 'C:\Windows\System32\dism.exe'
    }

    $ctx = [pscustomobject]@{
        Kind                              = 'real-readonly-dism'
        DismPath                          = $DismPath
        NativeRunner                      = $NativeRunner
        Commands                          = [System.Collections.ArrayList]@()
        MountOwned                        = $false
        MountDir                          = $null
        SourceIsoModified                 = $false
        ModifyingCommandsInvoked          = $false
        RealDismExecutionEnabled          = $false
        RealReadOnlyInspectionOccurred    = $false
        DisposableExportOccurred          = $false
        ReadOnlyMountOccurred             = $false
    }

    $adapter = New-Object psobject
    Add-Member -InputObject $adapter -NotePropertyName Ctx -NotePropertyValue $ctx
    Add-Member -InputObject $adapter -MemberType ScriptMethod -Name InvokeOperation -Value {
        param(
            [string]$Operation,
            $Parameters = $null
        )
        if ($null -eq $Parameters) { $Parameters = @{} }
        elseif ($Parameters -isnot [hashtable]) { $Parameters = [hashtable]$Parameters }
        $built = Assert-XboxOSReadOnlyDismOperationAllowed -Operation $Operation -Parameters $Parameters
        $native = Invoke-XboxOSNativeDismCommand `
            -DismPath $this.Ctx.DismPath `
            -ArgumentList @($built.ArgumentList) `
            -Runner $this.Ctx.NativeRunner

        $null = $this.Ctx.Commands.Add([pscustomobject]@{
                utc        = [datetime]::UtcNow
                operation  = $Operation
                class      = $built.Class
                arguments  = $built.ArgumentList
                exitCode   = $native.ExitCode
                command    = $native.Command
            })

        switch ($Operation) {
            'ExportImage' { $this.Ctx.DisposableExportOccurred = $true }
            'MountImageReadOnly' {
                $this.Ctx.ReadOnlyMountOccurred = $true
                $this.Ctx.MountOwned = $true
                $this.Ctx.MountDir = [string]$Parameters.MountDir
            }
            'UnmountDiscard' {
                $this.Ctx.MountOwned = $false
                $this.Ctx.MountDir = $null
            }
            default {
                if ($built.Class -eq 'PureInspection') {
                    $this.Ctx.RealReadOnlyInspectionOccurred = $true
                }
            }
        }

        $this.Ctx.ModifyingCommandsInvoked = $false
        $this.Ctx.RealDismExecutionEnabled = $false
        $this.Ctx.SourceIsoModified = $false

        return [pscustomobject]@{
            ExitCode                      = [int]$native.ExitCode
            Output                        = @($native.Output)
            Operation                     = $Operation
            Class                         = $built.Class
            ArgumentList                  = $built.ArgumentList
            Command                       = $native.Command
            ModifyingCommandsInvoked      = $false
            RealDismExecutionEnabled      = $false
            RealReadOnlyInspectionOccurred = [bool]$this.Ctx.RealReadOnlyInspectionOccurred
            DisposableExportOccurred      = [bool]$this.Ctx.DisposableExportOccurred
            ReadOnlyMountOccurred         = [bool]$this.Ctx.ReadOnlyMountOccurred
        }
    }
    return $adapter
}

function Mount-XboxOSSourceIsoForReadOnlyPreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$IsoPath,
        [scriptblock]$MountRunner = $null
    )

    if ($MountRunner) {
        return & $MountRunner -IsoPath $IsoPath
    }

    $diskImage = Mount-DiskImage -ImagePath $IsoPath -StorageType ISO -PassThru
    $isoDrive = ($diskImage | Get-Volume).DriveLetter
    if (-not $isoDrive) {
        throw 'ISO mounted but no drive letter was assigned.'
    }
    $isoRoot = "${isoDrive}:\"
    $sourceWim = Join-Path $isoRoot 'sources\install.wim'
    $sourceEsd = Join-Path $isoRoot 'sources\install.esd'
    $sourceImage = $null
    if (Test-Path -LiteralPath $sourceWim) { $sourceImage = $sourceWim }
    elseif (Test-Path -LiteralPath $sourceEsd) { $sourceImage = $sourceEsd }
    else { throw 'Neither install.wim nor install.esd found on ISO.' }

    return [pscustomobject]@{
        IsoPath         = $IsoPath
        DriveLetter     = [string]$isoDrive
        IsoRoot         = $isoRoot
        SourceImageFile = $sourceImage
        DiskImage       = $diskImage
    }
}

function Dismount-XboxOSSourceIsoForReadOnlyPreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$IsoPath,
        [scriptblock]$DismountRunner = $null
    )

    if ($DismountRunner) {
        $null = & $DismountRunner -IsoPath $IsoPath
        return
    }
    Dismount-DiskImage -ImagePath $IsoPath | Out-Null
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
        mountOwned                      = $false
        cleanupStatus                   = 'NotStarted'
        modifyingCommandsInvoked        = $false
        realDismExecutionEnabled        = $false
        executionAuthorized             = $false
        sourceIsoProtected              = $true
        liveReadOnlyAuthorized          = $false
        realReadOnlyInspectionOccurred  = $false
        disposableExportOccurred        = $false
        readOnlyMountOccurred           = $false
        disposableWimSha256             = $null
        postIsoSha256                   = $null
        postIsoIntegrityVerified        = $false
        sourceImageFileFromIso          = $null
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
    $ver = $adapter.InvokeOperation('GetDismVersion')
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
    , $Preflight
}

function Assert-XboxOSLiveReadOnlyPreflightAuthorization {
    [CmdletBinding()]
    param(
        [switch]$ConfirmLiveReadOnlyPreflight,
        [switch]$AllowLiveReadOnlyPreflight,
        [switch]$IUnderstandTemporaryHostState,
        [switch]$AllowCiBypassForUnitTests
    )

    if ((Test-XboxOSContinuousIntegrationEnvironment) -and -not $AllowCiBypassForUnitTests) {
        throw 'Live read-only preflight cannot run in CI (GITHUB_ACTIONS/CI/TF_BUILD).'
    }
    if (-not $ConfirmLiveReadOnlyPreflight) {
        throw 'Live read-only preflight requires -ConfirmLiveReadOnlyPreflight.'
    }
    if (-not $AllowLiveReadOnlyPreflight) {
        throw 'Live read-only preflight requires -AllowLiveReadOnlyPreflight (explicit operator authorization).'
    }
    if (-not $IUnderstandTemporaryHostState) {
        throw 'Live read-only preflight requires -IUnderstandTemporaryHostState acknowledging temporary files, disposable WIM export, and host DISM mount state changes.'
    }
}

function Get-XboxOSSourceIsoSha256ForPreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$IsoPath,
        [scriptblock]$HashProvider = $null
    )

    if ($HashProvider) {
        $result = & $HashProvider -IsoPath $IsoPath
        if ($result -is [string]) { return $result.ToUpperInvariant() }
        if ($null -ne $result -and $result -is [System.Management.Automation.PSObject] -and
            ($result.PSObject.Properties.Name -contains 'Hash')) {
            return ([string]$result.Hash).ToUpperInvariant()
        }
        if ($null -ne $result -and ($result -is [hashtable] -or $result -is [System.Collections.IDictionary]) -and $result.ContainsKey('Hash')) {
            return ([string]$result.Hash).ToUpperInvariant()
        }
        throw 'HashProvider must return a SHA256 string or an object with .Hash.'
    }
    $hashInfo = Get-XboxOSFileHash -Path $IsoPath
    return ([string]$hashInfo.Hash).ToUpperInvariant()
}

function Invoke-XboxOSDisposableImagePreflightLiveReadOnly {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Preflight,
        [switch]$ConfirmLiveReadOnlyPreflight,
        [switch]$AllowLiveReadOnlyPreflight,
        [switch]$IUnderstandTemporaryHostState,
        [switch]$AllowCiBypassForUnitTests,
        [scriptblock]$IsoMountRunner = $null,
        [scriptblock]$IsoDismountRunner = $null,
        [scriptblock]$HashProvider = $null,
        [long]$MinimumFreeBytes = 20GB,
        [switch]$SkipWorkspaceFiles
    )

    if ($Preflight.mode -ne 'LiveReadOnly') {
        throw 'Invoke-XboxOSDisposableImagePreflightLiveReadOnly requires Mode=LiveReadOnly.'
    }

    Assert-XboxOSLiveReadOnlyPreflightAuthorization `
        -ConfirmLiveReadOnlyPreflight:$ConfirmLiveReadOnlyPreflight `
        -AllowLiveReadOnlyPreflight:$AllowLiveReadOnlyPreflight `
        -IUnderstandTemporaryHostState:$IUnderstandTemporaryHostState `
        -AllowCiBypassForUnitTests:$AllowCiBypassForUnitTests

    $Preflight.liveReadOnlyAuthorized = $true
    $adapter = $Preflight.adapter
    if (-not $adapter -or -not $adapter.Ctx -or $adapter.Ctx.Kind -ne 'real-readonly-dism') {
        throw 'Live read-only preflight requires New-XboxOSRealReadOnlyDismAdapter (kind=real-readonly-dism).'
    }

    $null = $Preflight.audit.Add((New-XboxOSAuditEvent -Type 'PreflightStart' -Message 'Live read-only preflight started'))

    $isoMounted = $false
    $isoMountInfo = $null
    $expectedSha = (Get-XboxOSExpectedSourceIsoSha256).ToUpperInvariant()

    try {
        # Probe mounts first (empty when harnessed; real DISM when NativeRunner absent).
        $existingMounts = @()
        try {
            $mountedProbe = $adapter.InvokeOperation('GetMountedImageInfo')
            $null = $Preflight.commands.Add($mountedProbe)
            $existingMounts = @(ConvertFrom-XboxOSMountedImageInfoOutput -Output @($mountedProbe.Output))
        }
        catch {
            $null = $Preflight.blockers.Add(('Mounted-image probe failed: {0}' -f $_.Exception.Message))
            throw
        }

        $requireAdmin = -not [bool]$adapter.Ctx.NativeRunner
        $Preflight.prerequisites = Test-XboxOSSourceImagePrerequisites `
            -IsoPath $Preflight.isoPath `
            -WorkRoot $Preflight.workRoot `
            -LogsRoot $Preflight.logsRoot `
            -RequireIsoPresent `
            -RequireAdministrator:$requireAdmin `
            -ExistingMounts $existingMounts `
            -MinimumFreeBytes $MinimumFreeBytes `
            -HashProvider $HashProvider

        if ($null -eq $Preflight.prerequisites -or -not [bool]$Preflight.prerequisites.valid) {
            foreach ($e in @($Preflight.prerequisites.errors)) { $null = $Preflight.blockers.Add($e) }
            $Preflight.transactionState = 'Failed'
            $Preflight.cleanupStatus = 'NotRequired'
            throw 'Live read-only prerequisites failed.'
        }

        $Preflight.transactionState = 'SourceVerified'
        $ver = $adapter.InvokeOperation('GetDismVersion')
        $null = $Preflight.commands.Add($ver)

        $isoMountInfo = Mount-XboxOSSourceIsoForReadOnlyPreflight -IsoPath $Preflight.isoPath -MountRunner $IsoMountRunner
        $isoMounted = $true
        $Preflight.sourceImageFileFromIso = [string]$isoMountInfo.SourceImageFile
        $null = $Preflight.audit.Add((New-XboxOSAuditEvent -Type 'IsoMounted' -Message ("sourceImage={0}" -f $isoMountInfo.SourceImageFile)))

        $img = $adapter.InvokeOperation('GetImageInfo', @{ ImageFile = $isoMountInfo.SourceImageFile })
        $null = $Preflight.commands.Add($img)
        $images = @(ConvertFrom-XboxOSDismImageInfoOutput -Output @($img.Output))
        $resolved = Resolve-XboxOSExactImageIndex -Images $images -ExactName $script:XboxOSExpectedEditionName
        $Preflight.sourceImage = [pscustomobject]@{
            editionName     = [string]$resolved.Name
            sourceIndex     = [int]$resolved.Index
            buildNumber     = $script:XboxOSExpectedBuildNumber
            displayVersion  = $script:XboxOSExpectedDisplayVersion
            isoSha256       = $expectedSha
            isoPath         = $Preflight.isoPath
            sourceImageFile = [string]$isoMountInfo.SourceImageFile
        }

        $Preflight.workspace = New-XboxOSDisposableWorkspace -WorkRoot $Preflight.workRoot
        if (-not $SkipWorkspaceFiles) {
            $null = New-Item -ItemType Directory -Path $Preflight.workspace.workspacePath -Force
            $null = New-Item -ItemType Directory -Path $Preflight.workspace.mountDir -Force
        }
        $null = Assert-XboxOSPathOwnedAndSafe -CandidatePath $Preflight.workspace.mountDir -WorkspaceRoot $Preflight.workspace.workspacePath
        $null = Assert-XboxOSPathOwnedAndSafe -CandidatePath $Preflight.workspace.disposableWimPath -WorkspaceRoot $Preflight.workspace.workspacePath
        $Preflight.transactionState = 'WorkspacePrepared'

        $export = $adapter.InvokeOperation('ExportImage', @{
                SourceImageFile      = $isoMountInfo.SourceImageFile
                SourceIndex          = [string]$Preflight.sourceImage.sourceIndex
                DestinationImageFile = $Preflight.workspace.disposableWimPath
            })
        $null = $Preflight.commands.Add($export)
        $Preflight.disposableExportOccurred = $true
        $Preflight.transactionState = 'DisposableWimExported'

        Dismount-XboxOSSourceIsoForReadOnlyPreflight -IsoPath $Preflight.isoPath -DismountRunner $IsoDismountRunner
        $isoMounted = $false
        $null = $Preflight.audit.Add((New-XboxOSAuditEvent -Type 'IsoDismounted' -Message 'Source ISO dismounted after export; original ISO unmodified.'))

        $expInfo = $adapter.InvokeOperation('GetExportedImageInfo', @{ ImageFile = $Preflight.workspace.disposableWimPath })
        $null = $Preflight.commands.Add($expInfo)
        $exportMeta = @(ConvertFrom-XboxOSDismImageInfoOutput -Output @($expInfo.Output))
        if ($exportMeta.Count -ne 1) {
            throw ("Expected a single-index exported WIM, found {0} indexes." -f $exportMeta.Count)
        }
        if ([int]$exportMeta[0].Index -ne 1) {
            throw ("Expected exported image index 1, found {0}." -f $exportMeta[0].Index)
        }
        if (-not [string]::Equals([string]$exportMeta[0].Name.Trim(), $script:XboxOSExpectedEditionName, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw ("Exported image name '{0}' does not exactly match '{1}'." -f $exportMeta[0].Name, $script:XboxOSExpectedEditionName)
        }

        if ((Test-Path -LiteralPath $Preflight.workspace.disposableWimPath) -and -not $adapter.Ctx.NativeRunner) {
            $Preflight.disposableWimSha256 = (Get-XboxOSFileHash -Path $Preflight.workspace.disposableWimPath).Hash
        }
        elseif (Test-Path -LiteralPath $Preflight.workspace.disposableWimPath) {
            $Preflight.disposableWimSha256 = Get-XboxOSUtf8Sha256Hex -Text ((Get-Content -LiteralPath $Preflight.workspace.disposableWimPath -Raw -ErrorAction SilentlyContinue))
        }

        $mount = $adapter.InvokeOperation('MountImageReadOnly', @{
                ImageFile = $Preflight.workspace.disposableWimPath
                Index     = '1'
                MountDir  = $Preflight.workspace.mountDir
            })
        $null = $Preflight.commands.Add($mount)
        $Preflight.mountOwned = $true
        $Preflight.readOnlyMountOccurred = $true
        $Preflight.transactionState = 'ReadOnlyMounted'

        $ownedMountProbe = $adapter.InvokeOperation('GetMountedImageInfo')
        $null = $Preflight.commands.Add($ownedMountProbe)
        $ownedMounts = @(ConvertFrom-XboxOSMountedImageInfoOutput -Output @($ownedMountProbe.Output))
        $ownedHit = @($ownedMounts | Where-Object {
                $_.MountDir -and (
                    [string]::Equals(
                        (Get-XboxOSCanonicalPath -Path $_.MountDir),
                        (Get-XboxOSCanonicalPath -Path $Preflight.workspace.mountDir),
                        [System.StringComparison]::OrdinalIgnoreCase
                    )
                )
            })
        if ($ownedHit.Count -lt 1) {
            throw 'Owned read-only mount not present in Get-MountedImageInfo after mount.'
        }

        $pkg = $adapter.InvokeOperation('GetPackages', @{ MountDir = $Preflight.workspace.mountDir })
        $appx = $adapter.InvokeOperation('GetProvisionedAppxPackages', @{ MountDir = $Preflight.workspace.mountDir })
        $feat = $adapter.InvokeOperation('GetFeatures', @{ MountDir = $Preflight.workspace.mountDir })
        $null = $Preflight.commands.Add($pkg)
        $null = $Preflight.commands.Add($appx)
        $null = $Preflight.commands.Add($feat)
        $Preflight.realReadOnlyInspectionOccurred = $true

        $appxNames = @(ConvertFrom-XboxOSDismProvisionedAppxListOutput -Output @($appx.Output) | ForEach-Object { $_.PackageName })
        $features = @(ConvertFrom-XboxOSDismFeatureListOutput -Output @($feat.Output))
        $packages = @(ConvertFrom-XboxOSDismPackageListOutput -Output @($pkg.Output))

        $Preflight.freshInventory = New-XboxOSInventorySnapshot `
            -AppxAvailability Available `
            -FeatureAvailability Available `
            -AppxPackages $appxNames `
            -Features $features `
            -Packages $packages `
            -Source 'live-readonly-adapter' `
            -VerificationStatus Authoritative `
            -SourceImage $Preflight.sourceImage `
            -AdvertisedAppxCount $appxNames.Count `
            -AdvertisedFeatureCount $features.Count `
            -AdvertisedPackageCount $packages.Count

        Assert-XboxOSInventoryCompletenessForPreflight -Inventory $Preflight.freshInventory
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
        if ($Preflight.transactionState -ne 'Failed') {
            $Preflight.transactionState = 'RecoveryRequired'
        }
        try {
            if ($Preflight.workspace -and $Preflight.mountOwned) {
                $null = Assert-XboxOSDisposableWorkspaceOwnership -Workspace $Preflight.workspace -OwnershipToken $Preflight.workspace.ownershipToken -CandidateMountDir $Preflight.workspace.mountDir
                $null = $adapter.InvokeOperation('UnmountDiscard', @{ MountDir = $Preflight.workspace.mountDir })
                $Preflight.mountOwned = $false
                $Preflight.cleanupStatus = 'Recovered'
                $Preflight.transactionState = 'Aborted'
            }
            elseif ($Preflight.cleanupStatus -eq 'NotStarted' -or $Preflight.cleanupStatus -eq 'NotRequired') {
                if ($Preflight.transactionState -eq 'Failed') {
                    $Preflight.cleanupStatus = 'NotRequired'
                }
                else {
                    $Preflight.cleanupStatus = 'NotRequired'
                    if ($Preflight.transactionState -eq 'RecoveryRequired') {
                        $Preflight.transactionState = 'Failed'
                    }
                }
            }
        }
        catch {
            $null = $Preflight.blockers.Add(('Cleanup failure: {0}' -f $_.Exception.Message))
            $Preflight.cleanupStatus = 'Failed'
            $Preflight.transactionState = 'Failed'
        }
    }
    finally {
        if ($isoMounted) {
            try {
                Dismount-XboxOSSourceIsoForReadOnlyPreflight -IsoPath $Preflight.isoPath -DismountRunner $IsoDismountRunner
                $isoMounted = $false
            }
            catch {
                $null = $Preflight.blockers.Add(('ISO dismount failure: {0}' -f $_.Exception.Message))
                if ($Preflight.cleanupStatus -ne 'Failed') {
                    $Preflight.cleanupStatus = 'Failed'
                }
                $Preflight.transactionState = 'Failed'
            }
        }

        # Always re-verify original ISO when accessible.
        try {
            if (Test-Path -LiteralPath $Preflight.isoPath) {
                $Preflight.postIsoSha256 = Get-XboxOSSourceIsoSha256ForPreflight -IsoPath $Preflight.isoPath -HashProvider $HashProvider
                $Preflight.postIsoIntegrityVerified = [string]::Equals(
                    $Preflight.postIsoSha256,
                    $expectedSha,
                    [System.StringComparison]::OrdinalIgnoreCase
                )
                if (-not $Preflight.postIsoIntegrityVerified) {
                    $null = $Preflight.blockers.Add(("Post-run ISO SHA256 mismatch. expected=${expectedSha} actual=$($Preflight.postIsoSha256)"))
                    $Preflight.sourceIsoProtected = $false
                    if ($Preflight.transactionState -eq 'Completed') {
                        $Preflight.transactionState = 'Failed'
                        $Preflight.cleanupStatus = 'Failed'
                    }
                }
                else {
                    $Preflight.sourceIsoProtected = $true
                }
            }
        }
        catch {
            $null = $Preflight.blockers.Add(('Post-run ISO integrity check failed: {0}' -f $_.Exception.Message))
        }
    }

    if ($adapter.Ctx) {
        $Preflight.realReadOnlyInspectionOccurred = [bool]$adapter.Ctx.RealReadOnlyInspectionOccurred -or [bool]$Preflight.realReadOnlyInspectionOccurred
        $Preflight.disposableExportOccurred = [bool]$adapter.Ctx.DisposableExportOccurred -or [bool]$Preflight.disposableExportOccurred
        $Preflight.readOnlyMountOccurred = [bool]$adapter.Ctx.ReadOnlyMountOccurred -or [bool]$Preflight.readOnlyMountOccurred
    }

    $Preflight.modifyingCommandsInvoked = $false
    $Preflight.realDismExecutionEnabled = $false
    $Preflight.executionAuthorized = $false
    Assert-XboxOSExecutionSafetyInvariants -Transaction ([pscustomobject]@{
            modifyingCommandsInvoked = $Preflight.modifyingCommandsInvoked
            executionAuthorized      = $Preflight.executionAuthorized
            realDismExecutionEnabled = $Preflight.realDismExecutionEnabled
        })

    $lifecycleOk = (
        $Preflight.transactionState -eq 'Completed' -and
        $Preflight.cleanupStatus -eq 'Succeeded' -and
        -not $Preflight.mountOwned -and
        [bool]$Preflight.postIsoIntegrityVerified
    )
    if (-not $lifecycleOk) {
        if ($Preflight.cleanupStatus -eq 'Failed' -or $Preflight.mountOwned) {
            $Preflight.transactionState = 'Failed'
            if ($Preflight.mountOwned) {
                $null = $Preflight.blockers.Add('RecoveryRequired: owned mount still held; workspace and logs preserved for manual investigation.')
            }
        }
        $Preflight.preflightDecision = 'Failed'
    }
    elseif (@($Preflight.blockers).Count -gt 0) {
        $Preflight.preflightDecision = 'Blocked'
    }
    else {
        $Preflight.preflightDecision = 'ReadyForReview'
    }

    $null = $Preflight.audit.Add((New-XboxOSAuditEvent -Type 'PreflightEnd' -Message ("state={0} decision={1}" -f $Preflight.transactionState, $Preflight.preflightDecision)))
    , $Preflight
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

    if ($Preflight.mode -eq 'LiveReadOnly' -and $Stem -notmatch '(?i)live') {
        $Stem = $Stem + '-live-readonly'
    }

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
    if ($Preflight.mode -eq 'LiveReadOnly') {
        $lifecycleOk = $lifecycleOk -and [bool]$Preflight.postIsoIntegrityVerified
    }
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

    $reportType = if ($Preflight.mode -eq 'LiveReadOnly') {
        'disposable-image-preflight-live-readonly'
    }
    else {
        'disposable-image-preflight'
    }

    $report = [ordered]@{
        reportType                      = $reportType
        reportNamespace                 = $(if ($Preflight.mode -eq 'LiveReadOnly') { 'm4-live-readonly' } else { 'm4-simulation' })
        generatedUtc                    = [datetime]::UtcNow
        preflightEngineVersion          = $Preflight.preflightEngineVersion
        mode                            = $Preflight.mode
        preflightId                     = $Preflight.preflightId
        runId                           = $Preflight.preflightId
        transactionState                = $Preflight.transactionState
        preflightDecision               = $decision
        lifecycleCompleted              = [bool]$lifecycleOk
        success                         = [bool]$success
        sourceImage                     = $Preflight.sourceImage
        expectedIsoSha256               = Get-XboxOSExpectedSourceIsoSha256
        postIsoSha256                   = $Preflight.postIsoSha256
        postIsoIntegrityVerified        = [bool]$Preflight.postIsoIntegrityVerified
        disposableWimSha256             = $Preflight.disposableWimSha256
        prerequisites                   = $Preflight.prerequisites
        workspace                       = $(if ($Preflight.workspace) {
                [pscustomobject]@{
                    path           = $Preflight.workspace.workspacePath
                    disposableWim  = $Preflight.workspace.disposableWimPath
                    ownershipToken = $Preflight.workspace.ownershipToken
                    ownerId        = $Preflight.workspace.ownerId
                }
            } else { $null })
        inventoryFingerprint            = $(if ($Preflight.freshInventory) { $Preflight.freshInventory.inventoryFingerprint } else { $null })
        inventoryTotals                 = $(if ($Preflight.freshInventory) {
                [pscustomobject]@{
                    appx     = @($Preflight.freshInventory.appxPackages).Count
                    features = @($Preflight.freshInventory.features).Count
                    packages = @($Preflight.freshInventory.packages).Count
                }
            } else { $null })
        driftResult                     = $Preflight.driftResult
        dependencyResult                = $Preflight.dependencyResult
        planContentHash                 = $Preflight.plan.contentHash
        recomputedPlanContentHash       = $(if ($Preflight.recomputedPlan) { $Preflight.recomputedPlan.contentHash } else { $null })
        blockers                        = @($Preflight.blockers | ForEach-Object { [string]$_ })
        commands                        = @($Preflight.commands | ForEach-Object {
                [pscustomobject]@{
                    operation  = $_.Operation
                    class      = $_.Class
                    exitCode   = $_.ExitCode
                    arguments  = @($_.ArgumentList)
                    command    = $(if ($_.PSObject.Properties['Command']) { $_.Command } else { $null })
                }
            })
        mountOwned                      = [bool]$Preflight.mountOwned
        cleanupStatus                   = [string]$Preflight.cleanupStatus
        modifyingCommandsInvoked        = $false
        realDismExecutionEnabled        = $false
        executionAuthorized             = $false
        liveReadOnlyAuthorized          = [bool]$Preflight.liveReadOnlyAuthorized
        realReadOnlyInspectionOccurred  = [bool]$Preflight.realReadOnlyInspectionOccurred
        disposableExportOccurred        = [bool]$Preflight.disposableExportOccurred
        readOnlyMountOccurred           = [bool]$Preflight.readOnlyMountOccurred
        sourceIsoProtected              = [bool]$Preflight.sourceIsoProtected
        notes                           = @(
            'Milestone 4 disposable-image preflight report.'
            'Simulation mode uses mocks/fixtures; live read-only uses allowlisted real adapter after explicit operator authorization.'
            'Success never authorizes writable DISM servicing (realDismExecutionEnabled/modifyingCommandsInvoked/executionAuthorized remain false).'
            'Test RSA approval keys are development fixtures only and are never production-trusted.'
        )
    }

    $jsonPath = Join-Path $OutputDirectory ($Stem + '.json')
    $mdPath = Join-Path $OutputDirectory ($Stem + '.md')
    ([pscustomobject]$report | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $jsonPath -Encoding UTF8

    $md = New-Object System.Collections.Generic.List[string]
    $null = $md.Add('# XboxOS11 Disposable Image Preflight (Milestone 4)')
    $null = $md.Add('')
    $null = $md.Add(('- Report namespace: **{0}**' -f $report.reportNamespace))
    $null = $md.Add(('- Mode: **{0}**' -f $report.mode))
    $null = $md.Add(('- Run ID: `{0}`' -f $report.runId))
    $null = $md.Add(('- State: **{0}**' -f $report.transactionState))
    $null = $md.Add(('- Success: **{0}**' -f $report.success))
    $null = $md.Add(('- Plan content hash: `{0}`' -f $report.planContentHash))
    $null = $md.Add(('- Recomputed plan hash: `{0}`' -f $(if ($report.recomputedPlanContentHash) { $report.recomputedPlanContentHash } else { 'n/a' })))
    $null = $md.Add(('- Drift: **{0}**' -f $(if ($report.driftResult) { $report.driftResult.result } else { 'n/a' })))
    $null = $md.Add(('- Dependencies: **{0}**' -f $(if ($report.dependencyResult) { $report.dependencyResult.aggregateOutcome } else { 'n/a' })))
    $null = $md.Add(('- Cleanup: **{0}**' -f $report.cleanupStatus))
    $null = $md.Add(('- Mount owned: **{0}**' -f $report.mountOwned))
    $null = $md.Add(('- Modifying commands invoked: **{0}**' -f $report.modifyingCommandsInvoked))
    $null = $md.Add(('- Real DISM execution enabled: **{0}**' -f $report.realDismExecutionEnabled))
    $null = $md.Add(('- Execution authorized: **{0}**' -f $report.executionAuthorized))
    $null = $md.Add(('- Live read-only authorized: **{0}**' -f $report.liveReadOnlyAuthorized))
    $null = $md.Add(('- Real read-only inspection occurred: **{0}**' -f $report.realReadOnlyInspectionOccurred))
    $null = $md.Add(('- Disposable export occurred: **{0}**' -f $report.disposableExportOccurred))
    $null = $md.Add(('- Read-only mount occurred: **{0}**' -f $report.readOnlyMountOccurred))
    $null = $md.Add(('- Source ISO protected: **{0}**' -f $report.sourceIsoProtected))
    $null = $md.Add(('- Post-ISO integrity verified: **{0}**' -f $report.postIsoIntegrityVerified))
    $null = $md.Add('')
    $null = $md.Add('## Blockers')
    $null = $md.Add('')
    if (@($report.blockers).Count -eq 0) { $null = $md.Add('_None_') }
    else { foreach ($b in @($report.blockers)) { $null = $md.Add(('- {0}' -f $b)) } }

    ($md -join [Environment]::NewLine) + [Environment]::NewLine | Set-Content -LiteralPath $mdPath -Encoding UTF8

    return [pscustomobject]@{ Json = $jsonPath; Markdown = $mdPath; Report = [pscustomobject]$report }
}
