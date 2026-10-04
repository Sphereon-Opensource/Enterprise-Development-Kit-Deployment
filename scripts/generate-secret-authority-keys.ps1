<#
.SYNOPSIS
  Mints one fresh Ed25519 secret-authority key window for customer Compose.

.DESCRIPTION
  The platform receives the central permit-signing private key and every
  workload assertion public key. Each satellite receives only its own
  assertion private key and the central permit public key. Ordinary output is
  confined to compose/.secret-authority. For an independently owned diagnostic
  environment, -ExternalOutputRoot selects an explicit existing owned root;
  -OutputDirectory must be an absolute, nonexistent child of that root.
  External mode never deletes or adopts an existing destination.
  Private key material must never be committed.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$OutputDirectory,
  [string]$ExternalOutputRoot,
  [string[]]$Workload = @(
    'service-platform',
    'service-crypto',
    'service-data',
    'service-blob',
    'service-tenant-as',
    'service-oid4vci',
    'service-oid4vp'
  )
)

$ErrorActionPreference = 'Stop'

$openssl = @(
  'C:\Program Files\Git\mingw64\bin\openssl.exe',
  'C:\Program Files\OpenSSL-Win64\bin\openssl.exe'
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($openssl)) {
  $openssl = Get-Command openssl.exe -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty Source
}
if ([string]::IsNullOrWhiteSpace($openssl)) {
  throw 'A Windows-native openssl.exe is required to mint Ed25519 secret-authority keys.'
}

$resolvedOutput = [System.IO.Path]::GetFullPath($OutputDirectory)
$externalOutput = $PSBoundParameters.ContainsKey('ExternalOutputRoot')
if ($externalOutput) {
  $absolutePath = '^(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+(?:[\\/]|$))'
  if ($OutputDirectory -notmatch $absolutePath -or $ExternalOutputRoot -notmatch $absolutePath) {
    throw 'External authority output and its owned root must be absolute filesystem paths.'
  }
  $allowedRoot = [System.IO.Path]::GetFullPath($ExternalOutputRoot).TrimEnd('\', '/')
  if ($allowedRoot -eq [System.IO.Path]::GetPathRoot($allowedRoot).TrimEnd('\', '/')) {
    throw 'External authority owned root cannot be a filesystem root.'
  }
  if (-not (Test-Path -LiteralPath $allowedRoot -PathType Container)) {
    throw 'External authority output requires an existing owned root directory.'
  }
} else {
  $allowedRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\compose\.secret-authority'))
}
if (-not $resolvedOutput.StartsWith(
    $allowedRoot + [System.IO.Path]::DirectorySeparatorChar,
    [System.StringComparison]::OrdinalIgnoreCase
  )) {
  throw "Secret-authority output must be contained by ${allowedRoot}: $resolvedOutput"
}
# Check every existing ancestor before creating output or removing an ordinary
# customer window. A junction must not redirect either operation outside its root.
$scanPath = $resolvedOutput
while ($scanPath) {
  if (Test-Path -LiteralPath $scanPath) {
    $entry = Get-Item -LiteralPath $scanPath -Force
    if ($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
      throw "Secret-authority output cannot traverse a reparse point: $scanPath"
    }
  }
  $parentPath = Split-Path -Parent $scanPath
  if ($parentPath -eq $scanPath) { break }
  $scanPath = $parentPath
}
if ($externalOutput) {
  if (Test-Path -LiteralPath $resolvedOutput) {
    throw 'External authority output requires a fresh nonexistent destination.'
  }
  # Do not use Force: a concurrent creator must not turn this into adoption.
  New-Item -ItemType Directory -Path $resolvedOutput -ErrorAction Stop | Out-Null
} elseif (Test-Path -LiteralPath $resolvedOutput) {
  Remove-Item -LiteralPath $resolvedOutput -Recurse -Force
}
foreach ($directory in @('central', 'public', 'workload')) {
  New-Item -ItemType Directory -Force -Path (Join-Path $resolvedOutput $directory) | Out-Null
}

function New-Ed25519KeyPair {
  param(
    [Parameter(Mandatory = $true)][string]$PrivatePath,
    [Parameter(Mandatory = $true)][string]$PublicPath
  )
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $PrivatePath) | Out-Null
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $PublicPath) | Out-Null
  & $openssl genpkey -algorithm ED25519 -out $PrivatePath 2>$null
  if ($LASTEXITCODE -ne 0) { throw "OpenSSL failed to generate $PrivatePath." }
  & $openssl pkey -in $PrivatePath -pubout -out $PublicPath 2>$null
  if ($LASTEXITCODE -ne 0) { throw "OpenSSL failed to derive $PublicPath." }
}

$centralPrivate = Join-Path $resolvedOutput 'central\permit-signing.pem'
$centralPublic = Join-Path $resolvedOutput 'public\central-permit.pub.pem'
New-Ed25519KeyPair -PrivatePath $centralPrivate -PublicPath $centralPublic
foreach ($workloadId in $Workload) {
  if ([string]::IsNullOrWhiteSpace($workloadId) -or $workloadId -notmatch '^[a-z0-9-]+$') {
    throw "Invalid secret-authority workload id '$workloadId'."
  }
  New-Ed25519KeyPair `
    -PrivatePath (Join-Path $resolvedOutput "workload\$workloadId\assertion.pem") `
    -PublicPath (Join-Path $resolvedOutput "public\$workloadId-assertion.pub.pem")
}

$nowMillis = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$fromMillis = $nowMillis - 3600000L
$untilMillis = $nowMillis + 315360000000L
$keyId = "secret-authority-$nowMillis"
$mountRoot = '/app/secret-authority'
$centralVerificationKeys = @(
  foreach ($workloadId in $Workload) {
    "$keyId|$workloadId|1|$fromMillis|$untilMillis|$mountRoot/public/$workloadId-assertion.pub.pem"
  }
) -join ','
$window = @(
  "SECRET_AUTHORITY_KEY_ID=$keyId"
  "SECRET_AUTHORITY_ACTIVE_FROM_MILLIS=$fromMillis"
  "SECRET_AUTHORITY_ACTIVE_UNTIL_MILLIS=$untilMillis"
  "SECRET_AUTHORITY_WORKLOADS=$($Workload -join ' ')"
  "SECRET_AUTHORITY_CENTRAL_PERMIT_SIGNING_KEY=$keyId|$fromMillis|$untilMillis|$mountRoot/central/permit-signing.pem"
  "SECRET_AUTHORITY_CENTRAL_ASSERTION_VERIFICATION_KEYS=$centralVerificationKeys"
  "SECRET_AUTHORITY_SATELLITE_ASSERTION_SIGNING_KEY=$keyId|$fromMillis|$untilMillis|$mountRoot/workload/assertion.pem"
  "SECRET_AUTHORITY_SATELLITE_PERMIT_VERIFICATION_KEYS=$keyId|$fromMillis|$untilMillis|$mountRoot/public/central-permit.pub.pem"
) -join "`n"
[System.IO.File]::WriteAllText(
  (Join-Path $resolvedOutput 'window.env'),
  "$window`n",
  [System.Text.UTF8Encoding]::new($false)
)
Write-Host "secret-authority key material written to $resolvedOutput for $($Workload.Count) workloads"
