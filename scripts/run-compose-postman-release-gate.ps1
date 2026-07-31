<#
.SYNOPSIS
  Runs the customer Docker Compose topology and its 95-request Postman release gate.

.DESCRIPTION
  This is a non-interactive, fail-closed release gate. Localtest uses the
  literal customer gateway fixture. BehindEdge renders an isolated plain-HTTP
  stack gateway behind the existing shared edge terminator. Both modes verify
  one coherent immutable seven-image release set, perform supported first-run
  setup when required, run the maintained Newman/snapshot runner, and capture
  terminal evidence under an explicit report directory.

  -DryRun performs source/plan validation only. It never calls Docker or HTTP.
#>
[CmdletBinding(DefaultParameterSetName = 'PreProvisioned')]
param(
  [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')][string]$Tag,
  [Parameter(Mandatory = $true)][ValidatePattern('^[a-z0-9][a-z0-9_-]{2,62}$')][string]$ProjectName,
  [Parameter(Mandatory = $true)][string]$ReportDir,
  [Parameter(Mandatory = $true)][ValidateSet('Localtest', 'BehindEdge')][string]$AccessMode,
  [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9.-]+$')][string]$BaseDomain,
  [Parameter(Mandatory = $true)][string]$SourceState,
  [Parameter(Mandatory = $true)][ValidatePattern('^https://')][string]$ExpectedSource,
  [string]$ComposeEnvFile = (Join-Path $PSScriptRoot '..\compose\.env'),
  [string]$PostmanEnvironmentFile = (Join-Path $PSScriptRoot '..\postman\EDK-Enterprise-Deployment.customer.postman_environment.json'),
  [Parameter(Mandatory = $true, ParameterSetName = 'LicenseSetup')][string]$LicenseBundleZipPath,
  [Parameter(Mandatory = $true, ParameterSetName = 'PreProvisioned')][switch]$PreProvisionedSetup,
  [ValidatePattern('^[a-z0-9][a-z0-9-]{1,30}$')][string]$EdgeEnvironment = '',
  [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$')][string]$EdgeNetworkName = 'edge',
  [ValidatePattern('^\d{1,3}(?:\.\d{1,3}){3}/\d{1,2}$')][string]$EdgeTrustedSubnet = '172.16.100.0/24',
  [string]$EdgeTraefikContainer = 'vdx-edge-traefik-1',
  [string]$EdgeRouterDirectory = '',
  [switch]$ResetVolumes,
  [switch]$UseExistingProject,
  [switch]$KeepUp,
  [switch]$RemoveVolumesOnTeardown,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
$customerRoot = (Resolve-Path (Join-Path $scriptDir '..')).Path
$repoRoot = (Resolve-Path (Join-Path $customerRoot '..\..')).Path
if ([string]::IsNullOrWhiteSpace($EdgeRouterDirectory)) {
  $EdgeRouterDirectory = Join-Path $repoRoot 'deploy\edge\dynamic'
}
$composeDir = Join-Path $customerRoot 'compose'
$baseCompose = Join-Path $composeDir 'docker-compose.yml'
$gatewayCompose = Join-Path $composeDir 'docker-compose.gateway.yml'
$gatewayDynamic = Join-Path $composeDir 'gateway\traefik\dynamic.yml'
$behindEdgeComposeTemplate = Join-Path $composeDir 'docker-compose.behind-edge.template.yml'
$behindEdgeStaticTemplate = Join-Path $composeDir 'gateway\traefik\traefik.behind-edge.template.yml'
$behindEdgeDynamicTemplate = Join-Path $composeDir 'gateway\traefik\dynamic.public-cert.template.yml'
$edgeRouterTemplate = Join-Path $composeDir 'gateway\traefik\edge-router.template.yml'
$collectionPath = Join-Path $customerRoot 'postman\EDK-Enterprise-Deployment.postman_collection.json'
$snapshotDir = Join-Path $repoRoot 'deploy\edk\e2e\snapshots'
$runnerPath = Join-Path $repoRoot 'deploy\edk\e2e\runner\run-e2e.js'
$imageVerifier = Join-Path $repoRoot 'deploy\edk\e2e\scripts\verify-enterprise-image-set.mjs'
$setupHelper = Join-Path $scriptDir 'prepare-compose-postman-setup.mjs'
$canaryScanner = Join-Path $scriptDir 'assert-plaintext-canary-absent.mjs'
$supportHelper = Join-Path $scriptDir 'compose-postman-release-gate-support.mjs'
$lifecycleModule = Join-Path $scriptDir 'ComposePostmanReleaseGateLifecycle.psm1'
$localCa = Join-Path $composeDir 'gateway\certs\local-ca.crt'
$dockerCommand = 'docker'
$nodeCommand = 'node'
$releaseImages = @(
  'enterprise-platform',
  'enterprise-tenant-kms',
  'enterprise-did',
  'enterprise-tenant-as',
  'enterprise-issuer',
  'enterprise-verifier',
  'admin-console'
)

function Fail([string]$Message) { throw $Message }
function Require-File([string]$Path, [string]$Label) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Fail "$Label not found: $Path" }
}
function Require-ImmutableTag([string]$Value) {
  if ($Value -match '^(latest|main|master|develop|dev)$' -or
      $Value -match '(?i)snapshot' -or
      $Value -match '(?i)(^|[-_.])stab(?:ilization)?([-.]|$)') {
    Fail "Refusing mutable release tag '$Value'. Supply one immutable seven-image tag."
  }
}
function Assert-Ipv4Cidr([string]$Value, [string]$Label) {
  $parts = $Value.Split('/')
  $address = $null
  $prefix = 0
  if ($parts.Count -ne 2 -or
      -not [System.Net.IPAddress]::TryParse($parts[0], [ref]$address) -or
      $address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork -or
      -not [int]::TryParse($parts[1], [ref]$prefix) -or
      $prefix -lt 0 -or $prefix -gt 32) {
    Fail "$Label must be a valid IPv4 CIDR; got '$Value'."
  }
}
function Write-Utf8NoBom([string]$Path, [string]$Content) {
  [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}
function ConvertTo-ComposeMountPath([string]$Path) {
  return [System.IO.Path]::GetFullPath($Path).Replace('\', '/')
}
function Render-BehindEdgeArtifacts {
  New-Item -ItemType Directory -Path $behindEdgeArtifactDir -Force | Out-Null

  $publicDynamic = Get-Content -LiteralPath $behindEdgeDynamicTemplate -Raw
  $httpMatch = [regex]::Match($publicDynamic, '(?m)^http:\s*$')
  if (-not $httpMatch.Success) { Fail "Behind-edge routing source has no HTTP configuration: $behindEdgeDynamicTemplate" }
  $baseRegex = $BaseDomain.Replace('.', '\.')
  $dynamic = @"
# Generated customer EDK routing for shared-edge mode.
# TLS is terminated by the shared edge; this stack gateway receives plain HTTP.
"@ + $publicDynamic.Substring($httpMatch.Index)
  $dynamic = $dynamic.Replace('__BASE_DOMAIN_REGEX__', $baseRegex).Replace('__BASE_DOMAIN__', $BaseDomain)
  $dynamic = $dynamic.Replace('entryPoints: ["websecure"]', 'entryPoints: ["web"]')
  $dynamic = [regex]::Replace($dynamic, '(?m)^\s+tls:\s+\{\}\r?\n', '')
  Write-Utf8NoBom $selectedGatewayDynamic $dynamic

  $static = Get-Content -LiteralPath $behindEdgeStaticTemplate -Raw
  $static = $static.Replace('__EDGE_TRUSTED_SUBNET__', $EdgeTrustedSubnet)
  Write-Utf8NoBom $selectedGatewayStatic $static

  $compose = Get-Content -LiteralPath $behindEdgeComposeTemplate -Raw
  $compose = $compose.Replace('__BASE_DOMAIN__', $BaseDomain)
  $compose = $compose.Replace('__EDGE_ALIAS__', $edgeAlias)
  $compose = $compose.Replace('__EDGE_NETWORK_NAME__', $EdgeNetworkName)
  $compose = $compose.Replace('__TRAEFIK_STATIC_PATH__', (ConvertTo-ComposeMountPath $selectedGatewayStatic))
  $compose = $compose.Replace('__TRAEFIK_DYNAMIC_PATH__', (ConvertTo-ComposeMountPath $selectedGatewayDynamic))
  Write-Utf8NoBom $selectedGatewayCompose $compose

  $router = Get-Content -LiteralPath $edgeRouterTemplate -Raw
  $router = $router.Replace('__ENV__', $EdgeEnvironment)
  $router = $router.Replace('__BASE_DOMAIN_REGEX__', $baseRegex)
  $router = $router.Replace('__BASE_DOMAIN__', $BaseDomain)
  $router = $router.Replace('__EDGE_ALIAS__', $edgeAlias)
  Write-Utf8NoBom $edgeRouterCandidate $router

  foreach ($artifact in @($selectedGatewayDynamic, $selectedGatewayStatic, $selectedGatewayCompose, $edgeRouterCandidate)) {
    $text = Get-Content -LiteralPath $artifact -Raw
    if ($text -match '__[A-Z][A-Z0-9_]+__') { Fail "Behind-edge artifact retains an unresolved placeholder: $artifact" }
  }
  $composeText = Get-Content -LiteralPath $selectedGatewayCompose -Raw
  if ($composeText -match '(?m)^\s+ports:\s*$' -or
      $composeText -match '(?i)local-ca|local-truststore|gateway/certs') {
    Fail 'Behind-edge Compose overlay must own no host ports and carry no local CA or truststore.'
  }
  $dynamicText = Get-Content -LiteralPath $selectedGatewayDynamic -Raw
  if ($dynamicText -match 'websecure' -or $dynamicText -match '(?m)^\s+tls:') {
    Fail 'Behind-edge stack routing must be plain HTTP; TLS belongs to the shared edge.'
  }
}
function Assert-BehindEdgeMergedCompose([string]$ComposeJson) {
  try {
    $model = $ComposeJson | ConvertFrom-Json -ErrorAction Stop
  } catch {
    Fail "Failed to parse the merged BehindEdge Compose model: $($_.Exception.Message)"
  }
  if ($null -eq $model.services) {
    Fail 'Merged BehindEdge Compose model has no services.'
  }

  foreach ($serviceName in @(
    'enterprise-platform',
    'enterprise-tenant-as',
    'enterprise-did',
    'enterprise-issuer',
    'enterprise-verifier'
  )) {
    $serviceProperty = $model.services.PSObject.Properties[$serviceName]
    if ($null -eq $serviceProperty) {
      Fail "Merged BehindEdge Compose model is missing public workload '$serviceName'."
    }
    $publishedPorts = @($serviceProperty.Value.ports | Where-Object { $null -ne $_ })
    if ($publishedPorts.Count -ne 0) {
      Fail "BehindEdge public workload '$serviceName' must publish no host ports in the merged Compose model."
    }
  }

  foreach ($serviceName in @(
    'platform-postgres',
    'tenant-postgres',
    'otel-collector',
    'jaeger'
  )) {
    $serviceProperty = $model.services.PSObject.Properties[$serviceName]
    if ($null -eq $serviceProperty) {
      Fail "Merged BehindEdge Compose model is missing loopback-only support service '$serviceName'."
    }
    $publishedPorts = @($serviceProperty.Value.ports | Where-Object { $null -ne $_ })
    if ($publishedPorts.Count -eq 0) {
      Fail "BehindEdge support service '$serviceName' must retain its explicit loopback-only observability or database port."
    }
    foreach ($binding in $publishedPorts) {
      if ([string]$binding.host_ip -ne '127.0.0.1') {
        Fail "BehindEdge support service '$serviceName' has a non-loopback host port in the merged Compose model."
      }
    }
  }
}
function Read-PostmanValues([string]$Path) {
  $document = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
  $result = @{}
  foreach ($entry in @($document.values)) {
    if ($null -ne $entry -and -not [string]::IsNullOrWhiteSpace([string]$entry.key) -and $entry.enabled -ne $false) {
      $result[[string]$entry.key] = [string]$entry.value
    }
  }
  return $result
}
function Count-Requests([object[]]$Items) {
  $count = 0
  foreach ($item in @($Items)) {
    if ($null -ne $item.request) { $count++ }
    if ($null -ne $item.item) { $count += Count-Requests @($item.item) }
  }
  return $count
}
function Protect-SensitiveText([string]$Text) {
  $safe = [string]$Text
  if ($null -ne $script:postmanValues) {
    foreach ($key in @($script:postmanValues.Keys)) {
      if ([string]$key -notmatch '(?i)password|secret|token|code.?verifier|private.?key|authorization|credential') {
        continue
      }
      $secret = [string]$script:postmanValues[$key]
      if ([string]::IsNullOrEmpty($secret)) { continue }
      $variants = @(
        $secret,
        ([System.Uri]::EscapeDataString($secret)),
        (($secret | ConvertTo-Json -Compress).Trim('"'))
      ) | Select-Object -Unique
      foreach ($variant in $variants) {
        if (-not [string]::IsNullOrEmpty([string]$variant)) {
          $safe = $safe.Replace([string]$variant, '[REDACTED_CONFIGURED_SECRET]')
        }
      }
    }
  }
  $safe = $safe -replace '(?i)(Bearer\s+)[A-Za-z0-9._~+/=-]{12,}', '$1[REDACTED_BEARER_TOKEN]'
  $safe = $safe -replace '(?i)(Basic\s+)[A-Za-z0-9+/=]{8,}', '$1[REDACTED_BASIC_CREDENTIAL]'
  $safe = $safe -replace '(?im)((?:set-cookie|cookie)\s*:\s*)[^\r\n]+', '$1[REDACTED_COOKIE]'
  return $safe
}
function Invoke-LoggedNative(
  [string]$File,
  [string[]]$Arguments,
  [string]$LogPath,
  [bool]$EchoToConsole = $true
) {
  $lines = @(& $File @Arguments 2>&1 | ForEach-Object { [string]$_ })
  $exitCode = $LASTEXITCODE
  $safeText = Protect-SensitiveText ($lines -join "`n")
  $safeText | Set-Content -LiteralPath $LogPath -Encoding UTF8
  if ($EchoToConsole) {
    foreach ($line in @($safeText -split '\r?\n')) { Write-Host $line }
  }
  if ($exitCode -ne 0) { Fail "$File failed with exit code $exitCode. See $LogPath" }
  return $safeText
}
function Invoke-CapturedNative([string]$File, [string[]]$Arguments, [string]$OutputPath) {
  $lines = @(& $File @Arguments 2>&1 | ForEach-Object { [string]$_ })
  $exitCode = $LASTEXITCODE
  $lines | Set-Content -LiteralPath $OutputPath -Encoding UTF8
  if ($exitCode -ne 0) { Fail "$File failed with exit code $exitCode. See $OutputPath" }
  return ($lines -join "`n")
}
function Invoke-NativeText([string]$File, [string[]]$Arguments, [string]$Label) {
  $lines = @(& $File @Arguments 2>&1 | ForEach-Object { [string]$_ })
  $exitCode = $LASTEXITCODE
  if ($exitCode -ne 0) { Fail "$Label failed with exit code $exitCode." }
  return ($lines -join "`n")
}
function Invoke-Compose([string[]]$Tail, [string]$LogName) {
  return Invoke-LoggedNative $script:dockerCommand ($script:composeArgs + $Tail) (Join-Path $script:resolvedReportDir $LogName)
}
function Split-NonEmptyLines([string]$Text) {
  return @($Text -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}
function Write-Plan {
  $references = @($releaseImages | ForEach-Object { "nexus.sphereon.com/edk-docker/$($_):$Tag" })
  $plan = [ordered]@{
    mode = if ($DryRun) { 'dry-run' } else { 'execute' }
    accessMode = $AccessMode
    projectName = $ProjectName
    reportDir = $resolvedReportDir
    baseDomain = $BaseDomain
    publicOrigin = "https://platform.$BaseDomain"
    composeFiles = @($baseCompose, $selectedGatewayCompose)
    gatewayDynamic = $selectedGatewayDynamic
    requiresLocalCa = $requiresLocalCa
    edgeEnvironment = if ($AccessMode -eq 'BehindEdge') { $EdgeEnvironment } else { $null }
    edgeAlias = if ($AccessMode -eq 'BehindEdge') { $edgeAlias } else { $null }
    edgeNetwork = if ($AccessMode -eq 'BehindEdge') { $EdgeNetworkName } else { $null }
    edgeRouterCandidate = if ($AccessMode -eq 'BehindEdge') { $edgeRouterCandidate } else { $null }
    edgeRouterTarget = if ($AccessMode -eq 'BehindEdge') { $edgeRouterTarget } else { $null }
    composeEnvFile = $resolvedComposeEnv
    collection = $collectionPath
    environment = $resolvedPostmanEnvironment
    requestCount = 95
    immutableTag = $Tag
    sourceState = $resolvedSourceState
    expectedSource = $ExpectedSource
    releaseImages = $references
    resetVolumes = [bool]$ResetVolumes
    useExistingProject = [bool]$UseExistingProject
    setupMode = if ($PreProvisionedSetup) { 'pre-provisioned' } else { 'protected-license-bundle' }
    keepUp = [bool]$KeepUp
    removeVolumesOnTeardown = [bool]$RemoveVolumesOnTeardown
    runner = $runnerPath
    snapshotDir = $snapshotDir
  }
  $plan | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $resolvedReportDir 'release-gate-plan.json') -Encoding UTF8
}
function Invoke-CanaryFileScan([string]$Path, [string]$Label, [string]$EvidencePath) {
  $lines = @(Get-Content -LiteralPath $Path -Raw -ErrorAction Stop |
    & $script:nodeCommand $script:canaryScanner `
      --environment $script:resolvedPostmanEnvironment `
      --canary-key idpClientSecret `
      --label $Label 2>&1 |
    ForEach-Object { [string]$_ })
  $exitCode = $LASTEXITCODE
  if ($exitCode -ne 0) { Fail "Plaintext-canary scan failed for $Label." }
  ($lines -join "`n") | Add-Content -LiteralPath $EvidencePath -Encoding UTF8
}

Require-ImmutableTag $Tag
Assert-Ipv4Cidr $EdgeTrustedSubnet 'EdgeTrustedSubnet'
$commonRequired = @(
  $baseCompose,
  $collectionPath,
  $PostmanEnvironmentFile,
  $runnerPath,
  $imageVerifier,
  $setupHelper,
  $canaryScanner,
  $supportHelper,
  $lifecycleModule
)
$modeRequired =
  if ($AccessMode -eq 'Localtest') {
    @($gatewayCompose, $gatewayDynamic)
  } else {
    @($behindEdgeComposeTemplate, $behindEdgeStaticTemplate, $behindEdgeDynamicTemplate, $edgeRouterTemplate)
  }
foreach ($required in @($commonRequired + $modeRequired)) {
  Require-File $required 'Required release-gate source'
}
if ($AccessMode -eq 'Localtest') {
  if ($BaseDomain -ne 'saas.localtest.me') {
    Fail "Localtest access mode requires the explicit fixture domain 'saas.localtest.me'; got '$BaseDomain'."
  }
  if (-not [string]::IsNullOrWhiteSpace($EdgeEnvironment)) {
    Fail '-EdgeEnvironment is valid only with -AccessMode BehindEdge.'
  }
} else {
  if ([string]::IsNullOrWhiteSpace($EdgeEnvironment)) {
    Fail '-AccessMode BehindEdge requires -EdgeEnvironment.'
  }
  if ($BaseDomain -eq 'saas.localtest.me') {
    Fail 'BehindEdge requires a real edge base domain, not the Localtest fixture.'
  }
}
if ($ResetVolumes -and $PreProvisionedSetup) {
  Fail '-ResetVolumes cannot be combined with -PreProvisionedSetup because the reset removes the pre-provisioned installation.'
}
if ($UseExistingProject -and $ResetVolumes) { Fail '-UseExistingProject and -ResetVolumes are mutually exclusive.' }
if ($UseExistingProject -and $RemoveVolumesOnTeardown) { Fail 'Cannot remove volumes from an adopted existing project.' }

$resolvedReportDir = [System.IO.Path]::GetFullPath($ReportDir)
if (Test-Path -LiteralPath $resolvedReportDir) {
  $existingEvidence = @(Get-ChildItem -LiteralPath $resolvedReportDir -Force)
  if ($existingEvidence.Count -gt 0) {
    Fail "ReportDir must be new or empty so evidence cannot mix with another run: $resolvedReportDir"
  }
}
New-Item -ItemType Directory -Path $resolvedReportDir -Force | Out-Null
$requiresLocalCa = $AccessMode -eq 'Localtest'
$selectedGatewayCompose = $gatewayCompose
$selectedGatewayDynamic = $gatewayDynamic
$selectedGatewayStatic = $null
$behindEdgeArtifactDir = $null
$edgeAlias = $null
$edgeRouterCandidate = $null
$edgeRouterTarget = $null
if ($AccessMode -eq 'BehindEdge') {
  $behindEdgeArtifactDir = Join-Path $resolvedReportDir 'behind-edge'
  $selectedGatewayCompose = Join-Path $behindEdgeArtifactDir 'docker-compose.behind-edge.yml'
  $selectedGatewayDynamic = Join-Path $behindEdgeArtifactDir 'dynamic.behind-edge.generated.yml'
  $selectedGatewayStatic = Join-Path $behindEdgeArtifactDir 'traefik.behind-edge.generated.yml'
  $edgeRouterCandidate = Join-Path $behindEdgeArtifactDir "edge-router.$EdgeEnvironment.yml"
  $edgeAlias = "gw-$EdgeEnvironment"
  $resolvedEdgeRouterDirectory = [System.IO.Path]::GetFullPath($EdgeRouterDirectory)
  $edgeRouterTarget = Join-Path $resolvedEdgeRouterDirectory "$EdgeEnvironment.yml"
  Render-BehindEdgeArtifacts
}
$resolvedComposeEnv = [System.IO.Path]::GetFullPath($ComposeEnvFile)
$resolvedPostmanEnvironment = [System.IO.Path]::GetFullPath($PostmanEnvironmentFile)
$resolvedSourceState = [System.IO.Path]::GetFullPath($SourceState)
Require-File $resolvedComposeEnv 'Compose environment'
Require-File $resolvedPostmanEnvironment 'Postman environment'
Require-File $resolvedSourceState 'Frozen release source-state manifest'
$collection = Get-Content -LiteralPath $collectionPath -Raw | ConvertFrom-Json
$requestCount = Count-Requests @($collection.item)
if ($requestCount -ne 95) { Fail "Customer collection must contain exactly 95 requests; found $requestCount." }
if ($AccessMode -eq 'Localtest') {
  $gatewayRules = Get-Content -LiteralPath $gatewayDynamic -Raw
  if ($gatewayRules -notmatch [regex]::Escape("platform.$BaseDomain")) {
    Fail "The literal Localtest gateway route file does not target platform.$BaseDomain."
  }
}
Write-Plan

if ($DryRun) {
  Write-Host "Dry-run passed: customer $AccessMode topology, immutable seven-image plan, and 95-request collection validated."
  Write-Host "Plan: $(Join-Path $resolvedReportDir 'release-gate-plan.json')"
  exit 0
}

foreach ($tool in @($dockerCommand, $nodeCommand)) {
  if ($null -eq (Get-Command $tool -ErrorAction SilentlyContinue)) { Fail "$tool is required on PATH." }
}
if ($requiresLocalCa) { Require-File $localCa 'Customer gateway local CA' }
if ($PSCmdlet.ParameterSetName -eq 'LicenseSetup') {
  $LicenseBundleZipPath = [System.IO.Path]::GetFullPath($LicenseBundleZipPath)
  Require-File $LicenseBundleZipPath 'Protected license bundle'
}
$postmanValues = Read-PostmanValues $resolvedPostmanEnvironment
foreach ($key in @(
  'tenantSlug',
  'tenantName',
  'operatorEmail',
  'operatorPassword',
  'tenantOwnerPassword',
  'tenantOwnerCodeVerifier',
  'idpClientSecret'
)) {
  $candidate = [string]$postmanValues[$key]
  if ([string]::IsNullOrWhiteSpace($candidate) -or $candidate -match '^(?i)PASTE-|^replace-with-') {
    Fail "Postman environment '$key' must be populated with a non-placeholder value."
  }
}
if ([string]$postmanValues['baseDomain'] -ne $BaseDomain) {
  Fail "Postman baseDomain '$($postmanValues['baseDomain'])' must exactly match -BaseDomain '$BaseDomain'."
}
if ($AccessMode -eq 'Localtest') {
  $tenantAliasPattern = '(?m)^\s*-\s+' + [regex]::Escape([string]$postmanValues['tenantSlug']) + '\.' + [regex]::Escape($BaseDomain) + '\s*$'
  $gatewayOverlayText = Get-Content -LiteralPath $gatewayCompose -Raw
  if ($gatewayOverlayText -notmatch $tenantAliasPattern) {
    Fail "The literal Localtest gateway overlay must contain an active appnet alias for $($postmanValues['tenantSlug']).$BaseDomain so tenant JWKS resolves inside Compose."
  }
}
if ([string]$postmanValues['idpClientSecret'] -notmatch '^[A-Za-z0-9_-]{16,128}$') {
  Fail "idpClientSecret must be an encoding-stable 16-128 character ASCII canary using only letters, digits, '_' or '-'."
}
Import-Module -Name $lifecycleModule -Force

$previousTag = $env:EDK_TAG
$previousDomain = $env:EDK_PLATFORM_BASE_DOMAIN
$previousCa = $env:NODE_EXTRA_CA_CERTS
$env:EDK_TAG = $Tag
$env:EDK_PLATFORM_BASE_DOMAIN = $BaseDomain
$env:NODE_EXTRA_CA_CERTS = if ($requiresLocalCa) { $localCa } else { $null }
$composeArgs = @(
  'compose',
  '--project-name', $ProjectName,
  '--env-file', $resolvedComposeEnv,
  '-f', $baseCompose,
  '-f', $selectedGatewayCompose
)
$projectDisposition = $null
$lifecycle = $null
$gateOwnsProject = $false
$projectMutationAttempted = $false
$workloadPassed = $false
$primaryError = $null
$newmanStageDir = Join-Path $resolvedReportDir ('.newman-sensitive-staging-' + [guid]::NewGuid().ToString('N'))
$edgeRouterInstalledByRun = $false

try {
  Invoke-LoggedNative $dockerCommand @('info') (Join-Path $resolvedReportDir 'docker-info.log') | Out-Null
  if ($AccessMode -eq 'BehindEdge') {
    if (-not (Test-Path -LiteralPath $resolvedEdgeRouterDirectory -PathType Container)) {
      Fail "Shared edge router directory not found: $resolvedEdgeRouterDirectory"
    }
    $edgeRunning = (Invoke-NativeText $dockerCommand @(
      'inspect', '--format', '{{.State.Running}}', $EdgeTraefikContainer
    ) 'Inspect shared edge terminator').Trim()
    if ($edgeRunning -ne 'true') { Fail "Shared edge terminator '$EdgeTraefikContainer' is not running." }
    $edgeContainerNetworks = (Invoke-NativeText $dockerCommand @(
      'inspect', '--format', '{{json .NetworkSettings.Networks}}', $EdgeTraefikContainer
    ) 'Inspect shared edge terminator networks' | ConvertFrom-Json)
    if ($edgeContainerNetworks.PSObject.Properties.Name -notcontains $EdgeNetworkName) {
      Fail "Shared edge terminator '$EdgeTraefikContainer' is not attached to network '$EdgeNetworkName'."
    }
    $edgeMounts = (Invoke-NativeText $dockerCommand @(
      'inspect', '--format', '{{json .Mounts}}', $EdgeTraefikContainer
    ) 'Inspect shared edge terminator mounts' | ConvertFrom-Json)
    $dynamicMount = @($edgeMounts | Where-Object { [string]$_.Destination -eq '/etc/traefik/dynamic' })
    if ($dynamicMount.Count -ne 1 -or [string]$dynamicMount[0].Type -ne 'bind') {
      Fail "Shared edge terminator '$EdgeTraefikContainer' must bind exactly one watched /etc/traefik/dynamic directory."
    }
    $mountedRouterDirectory = [System.IO.Path]::GetFullPath([string]$dynamicMount[0].Source).TrimEnd('\', '/')
    if ($mountedRouterDirectory -ne $resolvedEdgeRouterDirectory.TrimEnd('\', '/')) {
      Fail "EdgeRouterDirectory '$resolvedEdgeRouterDirectory' is not the shared edge's watched directory '$mountedRouterDirectory'."
    }
    $edgeIpam = (Invoke-NativeText $dockerCommand @(
      'network', 'inspect', '--format', '{{json .IPAM.Config}}', $EdgeNetworkName
    ) 'Inspect shared edge network IPAM' | ConvertFrom-Json)
    $edgeSubnets = @($edgeIpam | ForEach-Object { [string]$_.Subnet })
    if ($edgeSubnets -notcontains $EdgeTrustedSubnet) {
      Fail "Shared edge network '$EdgeNetworkName' subnets '$($edgeSubnets -join ', ')' do not include trusted subnet '$EdgeTrustedSubnet'."
    }

    foreach ($routeFile in @(Get-ChildItem -LiteralPath $resolvedEdgeRouterDirectory -File | Where-Object { $_.Extension -in @('.yml', '.yaml') })) {
      if ($routeFile.FullName -eq $edgeRouterTarget) { continue }
      $routeText = Get-Content -LiteralPath $routeFile.FullName -Raw
      if ($routeText -match [regex]::Escape($BaseDomain) -or $routeText -match [regex]::Escape($edgeAlias)) {
        Fail "Edge host space '$BaseDomain' or alias '$edgeAlias' is already referenced by $($routeFile.FullName)."
      }
    }
    $candidateRouterText = Get-Content -LiteralPath $edgeRouterCandidate -Raw
    if (Test-Path -LiteralPath $edgeRouterTarget -PathType Leaf) {
      $existingRouterText = Get-Content -LiteralPath $edgeRouterTarget -Raw
      if ($existingRouterText -cne $candidateRouterText) {
        Fail "Shared edge router target already exists with different content: $edgeRouterTarget"
      }
    } else {
      $temporaryRouterTarget = "$edgeRouterTarget.$([guid]::NewGuid().ToString('N')).tmp"
      Write-Utf8NoBom $temporaryRouterTarget $candidateRouterText
      Move-Item -LiteralPath $temporaryRouterTarget -Destination $edgeRouterTarget
      $edgeRouterInstalledByRun = $true
    }
  }
  Invoke-CapturedNative $dockerCommand ($composeArgs + @('config', '--no-interpolate')) (Join-Path $resolvedReportDir 'compose-config.yml') | Out-Null
  if ($AccessMode -eq 'BehindEdge') {
    $mergedComposeJson = Invoke-NativeText $dockerCommand ($composeArgs + @('config', '--format', 'json')) 'Render merged BehindEdge Compose model'
    Assert-BehindEdgeMergedCompose $mergedComposeJson
  }
  $renderedImages = Join-Path $resolvedReportDir 'compose-images.txt'
  Invoke-CapturedNative $dockerCommand ($composeArgs + @('config', '--images')) $renderedImages | Out-Null
  Invoke-LoggedNative $nodeCommand @(
    $imageVerifier,
    '--tag', $Tag,
    '--source-state', $resolvedSourceState,
    '--expected-source', $ExpectedSource,
    '--rendered-images', $renderedImages,
    '--output', (Join-Path $resolvedReportDir 'enterprise-image-set.json')
  ) (Join-Path $resolvedReportDir 'enterprise-image-preflight.log') | Out-Null

  $projectLabel = "label=com.docker.compose.project=$ProjectName"
  $containers = Split-NonEmptyLines (Invoke-CapturedNative $dockerCommand @(
    'ps', '--all', '--filter', $projectLabel, '--format', '{{.ID}}'
  ) (Join-Path $resolvedReportDir 'compose-initial-containers.txt'))
  $networks = Split-NonEmptyLines (Invoke-CapturedNative $dockerCommand @(
    'network', 'ls', '--filter', $projectLabel, '--format', '{{.ID}}'
  ) (Join-Path $resolvedReportDir 'compose-initial-networks.txt'))
  $volumes = Split-NonEmptyLines (Invoke-CapturedNative $dockerCommand @(
    'volume', 'ls', '--filter', $projectLabel, '--format', '{{.Name}}'
  ) (Join-Path $resolvedReportDir 'compose-initial-volumes.txt'))
  $inventoryPath = Join-Path $resolvedReportDir 'compose-project-inventory.json'
  [ordered]@{
    checkedAt = (Get-Date).ToUniversalTime().ToString('o')
    projectName = $ProjectName
    containers = @($containers)
    networks = @($networks)
    volumes = @($volumes)
  } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $inventoryPath -Encoding UTF8
  $dispositionPath = Join-Path $resolvedReportDir 'compose-project-disposition.json'
  Invoke-LoggedNative $nodeCommand @(
    $supportHelper,
    'classify-project',
    '--inventory', $inventoryPath,
    '--use-existing', ([bool]$UseExistingProject).ToString().ToLowerInvariant(),
    '--reset', ([bool]$ResetVolumes).ToString().ToLowerInvariant(),
    '--output', $dispositionPath
  ) (Join-Path $resolvedReportDir 'compose-project-classification.log') | Out-Null
  $projectDisposition = Get-Content -LiteralPath $dispositionPath -Raw | ConvertFrom-Json
  $gateOwnsProject = [bool]$projectDisposition.ownsProject
  $lifecycle = New-ComposeGateLifecycle `
    -Mode ([string]$projectDisposition.mode) `
    -OwnsProject $gateOwnsProject

  # Ownership is established before either reset or startup. A failed partial
  # mutation therefore still reaches the owned-project teardown path.
  $lifecycle = Start-ComposeGateMutation -Lifecycle $lifecycle
  $projectMutationAttempted = [bool]$lifecycle.MutationAttempted
  if ($ResetVolumes) {
    Invoke-Compose @('down', '--volumes', '--remove-orphans') 'compose-reset.log' | Out-Null
  }
  Invoke-Compose @('up', '-d', '--wait', '--wait-timeout', '300', '--pull', 'never') 'compose-up.log' | Out-Null
  Invoke-CapturedNative $dockerCommand ($composeArgs + @('ps', '--all', '--format', 'json')) (Join-Path $resolvedReportDir 'compose-ps.jsonl') | Out-Null

  $imageReport = Get-Content -LiteralPath (Join-Path $resolvedReportDir 'enterprise-image-set.json') -Raw | ConvertFrom-Json
  if ([string]$imageReport.releaseBuild.version -ne $Tag) {
    Fail "Release image label version '$($imageReport.releaseBuild.version)' must exactly equal requested immutable tag '$Tag'."
  }
  foreach ($identityKey in @('source', 'sourceFingerprint', 'revision', 'created')) {
    if ([string]::IsNullOrWhiteSpace([string]$imageReport.releaseBuild.$identityKey)) {
      Fail "Release image report is missing coherent $identityKey provenance."
    }
  }
  $fingerprintMaterial = @(
    [string]$imageReport.releaseBuild.version,
    [string]$imageReport.releaseBuild.source,
    [string]$imageReport.releaseBuild.sourceFingerprint,
    [string]$imageReport.releaseBuild.revision,
    [string]$imageReport.releaseBuild.created
  ) -join "`n"
  $fingerprintBytes = [System.Text.Encoding]::UTF8.GetBytes($fingerprintMaterial)
  $sha256 = [System.Security.Cryptography.SHA256]::Create()
  try {
    $releaseFingerprint = ([System.BitConverter]::ToString($sha256.ComputeHash($fingerprintBytes))).Replace('-', '').ToLowerInvariant()
  } finally {
    $sha256.Dispose()
  }
  [ordered]@{
    tag = $Tag
    version = [string]$imageReport.releaseBuild.version
    source = [string]$imageReport.releaseBuild.source
    sourceFingerprint = [string]$imageReport.releaseBuild.sourceFingerprint
    revision = [string]$imageReport.releaseBuild.revision
    created = [string]$imageReport.releaseBuild.created
    sha256 = $releaseFingerprint
  } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $resolvedReportDir 'release-identity.json') -Encoding UTF8

  $expectedIds = @{}
  foreach ($image in @($imageReport.images)) {
    $expectedIds[[string]$image.reference] = [string]$image.localContentId
  }
  $serviceImages = [ordered]@{}
  foreach ($service in @(
    'enterprise-platform',
    'enterprise-tenant-kms',
    'enterprise-did',
    'enterprise-tenant-as',
    'enterprise-issuer',
    'enterprise-verifier',
    'admin-console',
    'admin-console-tenant'
  )) {
    $containerIds = Split-NonEmptyLines (Invoke-NativeText $dockerCommand ($composeArgs + @(
      'ps', '--all', '--quiet', $service
    )) "Resolve containers for $service")
    if ($containerIds.Count -ne 1) {
      Fail "$service must resolve exactly one project container; found $($containerIds.Count)."
    }
    $containerId = [string]$containerIds[0]
    $actualId = (Invoke-NativeText $dockerCommand @(
      'inspect', '--format', '{{.Image}}', $containerId
    ) "Inspect image for $service").Trim()
    $containerStatus = (Invoke-NativeText $dockerCommand @(
      'inspect', '--format', '{{.State.Status}}', $containerId
    ) "Inspect state for $service").Trim()
    if ($containerStatus -ne 'running') { Fail "$service container '$containerId' is '$containerStatus', not running." }
    $releaseName = if ($service -eq 'admin-console-tenant') { 'admin-console' } else { $service }
    $reference = "nexus.sphereon.com/edk-docker/$releaseName`:$Tag"
    if ([string]$actualId -ne [string]$expectedIds[$reference]) {
      Fail "$service runs image id '$actualId', expected '$($expectedIds[$reference])'."
    }
    $serviceImages[$service] = [ordered]@{
      reference = $reference
      imageId = [string]$actualId
      containerId = $containerId
      state = $containerStatus
      releaseFingerprint = $releaseFingerprint
    }
  }
  $serviceImages | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $resolvedReportDir 'compose-service-image-ids.json') -Encoding UTF8

  $platformUrl = "https://platform.$BaseDomain"
  $setupArgs = @(
    $setupHelper,
    '--platform-url', $platformUrl,
    '--environment', $resolvedPostmanEnvironment,
    '--evidence', (Join-Path $resolvedReportDir 'setup-evidence.json')
  )
  if ($PreProvisionedSetup) { $setupArgs += '--pre-provisioned' }
  else { $setupArgs += @('--license-bundle', $LicenseBundleZipPath) }
  Invoke-LoggedNative $nodeCommand $setupArgs (Join-Path $resolvedReportDir 'setup.log') $false | Out-Null

  New-Item -ItemType Directory -Path $newmanStageDir -Force | Out-Null
  $runnerOutput = Invoke-LoggedNative $nodeCommand @(
    $runnerPath,
    '--collection', $collectionPath,
    '--environment', $resolvedPostmanEnvironment,
    '--snapshots', $snapshotDir,
    '--report-dir', $newmanStageDir,
    '--working-dir', (Join-Path $repoRoot 'deploy\edk\e2e'),
    '--base-domain', $BaseDomain
  ) (Join-Path $resolvedReportDir 'newman.log') $false
  if ($runnerOutput -notmatch 'E2E finished:\s+95 requests captured,\s+exit code 0\.') {
    Fail 'Newman did not execute and capture exactly all 95 requests.'
  }
  $junitPath = Join-Path $newmanStageDir 'junit.xml'
  Invoke-LoggedNative $nodeCommand @(
    $supportHelper,
    'validate-junit',
    '--file', $junitPath,
    '--output', (Join-Path $resolvedReportDir 'junit-validation.json')
  ) (Join-Path $resolvedReportDir 'junit-validation.log') | Out-Null
  $newmanReportDir = Join-Path $resolvedReportDir 'newman'
  New-Item -ItemType Directory -Path $newmanReportDir -Force | Out-Null
  foreach ($safeArtifact in @('junit.xml', 'failure-summary.json', 'failure-summary.md', 'snapshot-drift.patch')) {
    $sourceArtifact = Join-Path $newmanStageDir $safeArtifact
    if (Test-Path -LiteralPath $sourceArtifact -PathType Leaf) {
      Copy-Item -LiteralPath $sourceArtifact -Destination (Join-Path $newmanReportDir $safeArtifact) -Force
    }
  }
  Remove-Item -LiteralPath $newmanStageDir -Recurse -Force

  Invoke-CapturedNative $dockerCommand ($composeArgs + @('logs', '--no-color', '--timestamps')) (Join-Path $resolvedReportDir 'compose-logs.txt') | Out-Null
  Invoke-CapturedNative $dockerCommand ($composeArgs + @(
    'exec', '-T', 'platform-postgres', 'sh', '-lc',
    'pg_dump --schema-only --no-owner --no-privileges -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
  )) (Join-Path $resolvedReportDir 'platform-schema.sql') | Out-Null
  Invoke-CapturedNative $dockerCommand ($composeArgs + @(
    'exec', '-T', 'tenant-postgres', 'sh', '-lc',
    'pg_dump --schema-only --no-owner --no-privileges -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
  )) (Join-Path $resolvedReportDir 'tenant-schema.sql') | Out-Null

  $canaryEvidence = Join-Path $resolvedReportDir 'plaintext-canary-evidence.jsonl'
  Invoke-CanaryFileScan (Join-Path $resolvedReportDir 'compose-logs.txt') 'compose-logs' $canaryEvidence
  foreach ($databaseScan in @(
    @{service = 'platform-postgres'; label = 'platform-db'; log = 'platform-db-canary-scan.log'},
    @{service = 'tenant-postgres'; label = 'tenant-db'; log = 'tenant-db-canary-scan.log'}
  )) {
    $producerArgs = @(
      $supportHelper,
      'scan-producer',
      '--environment', $resolvedPostmanEnvironment,
      '--canary-key', 'idpClientSecret',
      '--scanner', $canaryScanner,
      '--label', $databaseScan.label,
      '--evidence', $canaryEvidence,
      '--',
      $dockerCommand
    ) + $composeArgs + @(
      'exec', '-T', $databaseScan.service, 'sh', '-lc',
      'pg_dump --data-only --no-owner --no-privileges -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
    )
    Invoke-LoggedNative $nodeCommand $producerArgs (Join-Path $resolvedReportDir $databaseScan.log) | Out-Null
  }
  $workloadPassed = $true
} catch {
  $primaryError = $_
  [string]$_.Exception.Message | Set-Content -LiteralPath (Join-Path $resolvedReportDir 'gate-failure.log') -Encoding UTF8
} finally {
  $teardownStatus = 'not-started'
  $edgeRouterStatus = if ($AccessMode -eq 'BehindEdge') { 'pre-existing' } else { 'not-applicable' }
  try {
    if (Test-Path -LiteralPath $newmanStageDir -PathType Container) {
      Remove-Item -LiteralPath $newmanStageDir -Recurse -Force
    }
    if ($projectMutationAttempted -and
        -not (Test-Path -LiteralPath (Join-Path $resolvedReportDir 'compose-logs.txt'))) {
      try {
        Invoke-CapturedNative $dockerCommand ($composeArgs + @('logs', '--no-color', '--timestamps')) (Join-Path $resolvedReportDir 'compose-logs.txt') | Out-Null
      } catch {
        [string]$_.Exception.Message | Set-Content -LiteralPath (Join-Path $resolvedReportDir 'compose-log-capture-failure.log') -Encoding UTF8
      }
    }
    $teardownAction = Get-ComposeGateTeardownAction -Lifecycle $lifecycle -KeepUp ([bool]$KeepUp)
    if ($teardownAction -eq 'retained-by-request') {
      $teardownStatus = $teardownAction
    } elseif ($teardownAction -eq 'down') {
      $down = @('down', '--remove-orphans')
      if ($RemoveVolumesOnTeardown) { $down += '--volumes' }
      try {
        Invoke-Compose $down 'compose-teardown.log' | Out-Null
        $teardownStatus = 'passed'
      } catch {
        $teardownStatus = 'failed'
        if ($null -eq $primaryError) { $primaryError = $_ }
      }
    } elseif ($teardownAction -eq 'adopted-retained') {
      $teardownStatus = $teardownAction
    }
    [ordered]@{
      completedAt = (Get-Date).ToUniversalTime().ToString('o')
      projectMode = if ($null -eq $projectDisposition) { 'unclassified' } else { [string]$projectDisposition.mode }
      gateOwnsProject = $gateOwnsProject
      mutationAttempted = $projectMutationAttempted
      keepUp = [bool]$KeepUp
      status = $teardownStatus
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $resolvedReportDir 'compose-teardown.json') -Encoding UTF8
  } catch {
    $teardownStatus = 'failed'
    if ($null -eq $primaryError) { $primaryError = $_ }
  }

  if ($edgeRouterInstalledByRun) {
    $mayRemoveOwnedRouter =
      -not $KeepUp -and
      (($teardownStatus -eq 'passed') -or -not $projectMutationAttempted)
    if ($mayRemoveOwnedRouter) {
      try {
        $candidateRouterText = Get-Content -LiteralPath $edgeRouterCandidate -Raw
        $installedRouterText =
          if (Test-Path -LiteralPath $edgeRouterTarget -PathType Leaf) {
            Get-Content -LiteralPath $edgeRouterTarget -Raw
          } else {
            $null
          }
        if ($null -ne $installedRouterText -and $installedRouterText -cne $candidateRouterText) {
          Fail "Refusing to remove changed shared edge router: $edgeRouterTarget"
        }
        if ($null -ne $installedRouterText) { Remove-Item -LiteralPath $edgeRouterTarget -Force }
        $edgeRouterStatus = 'removed'
      } catch {
        $edgeRouterStatus = 'cleanup-failed'
        if ($null -eq $primaryError) { $primaryError = $_ }
      }
    } else {
      $edgeRouterStatus = 'retained'
    }
  }
  [ordered]@{
    accessMode = $AccessMode
    environment = if ($AccessMode -eq 'BehindEdge') { $EdgeEnvironment } else { $null }
    alias = if ($AccessMode -eq 'BehindEdge') { $edgeAlias } else { $null }
    target = if ($AccessMode -eq 'BehindEdge') { $edgeRouterTarget } else { $null }
    installedByRun = $edgeRouterInstalledByRun
    status = $edgeRouterStatus
  } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $resolvedReportDir 'edge-router-disposition.json') -Encoding UTF8

  $candidateStatus = if ($null -eq $primaryError -and $workloadPassed) { 'passed' } else { 'failed' }
  try {
    & $nodeCommand $supportHelper finalize-evidence `
      --root $resolvedReportDir `
      --environment $resolvedPostmanEnvironment `
      --canary-key idpClientSecret `
      --candidate-status $candidateStatus `
      --teardown-status $teardownStatus `
      --project-name $ProjectName `
      --tag $Tag `
      --request-count 95 `
      --manifest (Join-Path $resolvedReportDir 'evidence-manifest.json') `
      --manifest-hash (Join-Path $resolvedReportDir 'evidence-manifest.sha256')
    $finalizationExit = $LASTEXITCODE
    if ($finalizationExit -ne 0) {
      $manifestExists = Test-Path -LiteralPath (Join-Path $resolvedReportDir 'evidence-manifest.json') -PathType Leaf
      if (($candidateStatus -eq 'passed' -or -not $manifestExists) -and $null -eq $primaryError) {
        $primaryError = [System.Management.Automation.RuntimeException]::new(
          "Terminal evidence finalization failed with exit code $finalizationExit."
        )
      } elseif (-not $manifestExists) {
        Write-Warning "Terminal evidence finalization failed with exit code $finalizationExit and produced no manifest."
      }
    }
  } catch {
    if ($null -eq $primaryError) { $primaryError = $_ }
    else { Write-Warning "Terminal evidence finalization also failed: $($_.Exception.Message)" }
  } finally {
    $env:EDK_TAG = $previousTag
    $env:EDK_PLATFORM_BASE_DOMAIN = $previousDomain
    $env:NODE_EXTRA_CA_CERTS = $previousCa
  }
}

if ($null -ne $primaryError) { throw $primaryError }
Write-Host "Customer Compose/Postman release gate passed. Evidence: $resolvedReportDir" -ForegroundColor Green
