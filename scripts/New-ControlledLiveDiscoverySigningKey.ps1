#Requires -Version 7.0
<#
.SYNOPSIS
  Milestone 6E: generates an operator RSA signing key pair for HostDiscoveryReal approvals.

.DESCRIPTION
  Keys are written outside the repository and outside cloud-synchronized folders (default C:\XboxOS\Lab\Keys).
  The private key never belongs in Git, CI secrets for this repository, or the replay store.
  Generating a key does not authorize anything; it only creates an identity an operator can sign with.
#>
[CmdletBinding()]
param(
    [string]$KeyDirectory = 'C:\XboxOS\Lab\Keys',
    [string]$Name = 'operator',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
Import-Module (Join-Path $repoRoot 'modules\XboxOS.Build\XboxOS.Build.psd1') -Force

$full = [System.IO.Path]::GetFullPath($KeyDirectory)
if (Test-XboxOSPathEqualsOrUnder -Path $full -ParentPath $repoRoot) {
    throw "Refusing to write signing keys inside the repository: $full"
}
if ($full -match '(?i)[\\/]OneDrive' -or (Test-XboxOSCloudSynchronizedPath -Path $full)) {
    throw "Refusing to write signing keys inside a cloud-synchronized folder: $full"
}

$priv = Join-Path $full ("{0}-private.pem" -f $Name)
$pub = Join-Path $full ("{0}-public.pem" -f $Name)
if (((Test-Path -LiteralPath $priv) -or (Test-Path -LiteralPath $pub)) -and -not $Force) {
    throw "Key files already exist under $full. Use -Force to replace them (existing approvals signed by the old key stop validating)."
}
New-Item -ItemType Directory -Path $full -Force | Out-Null

$rsa = [System.Security.Cryptography.RSA]::Create(3072)
try {
    Set-Content -LiteralPath $priv -Value $rsa.ExportPkcs8PrivateKeyPem() -Encoding UTF8
    Set-Content -LiteralPath $pub -Value $rsa.ExportSubjectPublicKeyInfoPem() -Encoding UTF8
}
finally {
    $rsa.Dispose()
}

Write-Host "Private key: $priv (keep offline; never commit)"
Write-Host "Public key:  $pub"
Write-Host ("Public key fingerprint: {0}" -f (Get-XboxOSPublicKeyFingerprint -PublicKeyPemPath $pub))
