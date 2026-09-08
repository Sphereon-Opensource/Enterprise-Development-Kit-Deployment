[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateSet('Distributed','Monolith')][string]$Topology,
  [Parameter(Mandatory)][string]$TenantEnvironment,
  [Parameter(Mandatory)][string]$SourceFixtureEvidence,
  [Parameter(Mandatory)][string]$PlatformCredentials,
  [Parameter(Mandatory)][string]$TenantSlug,
  [Parameter(Mandatory)][string]$SourceActivationCommandFile,
  [Parameter(Mandatory)][string]$TargetActivationCommandFile,
  [Parameter(Mandatory)][string]$DiscoveryEdgeNetwork,
  [Parameter(Mandatory)][string]$LocalCaCert,
  [Parameter(Mandatory)][string]$LocalCaKey,
  [Parameter(Mandatory)][string]$TenantId,
  [Parameter(Mandatory)][string]$CollisionIssuer,
  [Parameter(Mandatory)][string]$ChangedIssuer,
  [Parameter(Mandatory)][string]$StaleIssuer,
  [Parameter(Mandatory)][string]$PlatformBaseUrl,
  [Parameter(Mandatory)][string]$ConsoleBaseUrl,
  [Parameter(Mandatory)][string]$EvidenceDirectory,
  [Parameter(Mandatory)][string]$ScreenshotCommandFile,
  [Parameter(Mandatory)][string]$ComposeProject,
  [Parameter(Mandatory)][string]$ComposeEnvFile,
  [Parameter(Mandatory)][string[]]$ComposeFile,
  [Parameter(Mandatory)][string]$PlatformDatabaseContainer,
  [Parameter(Mandatory)][string]$TenantAsDatabaseContainer,
  [string]$PlatformPostgresUser = 'edk_platform',
  [string]$PlatformPostgresDatabase = 'platform',
  [string]$TenantAsPostgresUser = 'edk_tenant',
  [string]$TenantAsPostgresDatabase = 'tenant',
  [string]$FixtureRunId = ('docs-capture-' + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
)

$ErrorActionPreference = 'Stop'
$repo = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$controller = Join-Path $repo 'deploy\edk\e2e\scripts\run-authorization-server-live-fixture.mjs'
$runtimeService = if ($Topology -eq 'Monolith') { 'svc-monolith' } else { 'enterprise-platform' }
$tenantAsRuntimeService = if ($Topology -eq 'Monolith') { 'svc-monolith' } else { 'tenant-as' }
$managedRuntime = if ($Topology -eq 'Monolith') { @('svc-monolith') } else { @('enterprise-platform','tenant-kms','did','tenant-as','issuer','verifier') }
$topologyKind = if ($Topology -eq 'Monolith') { 'monolith-compose' } else { 'distributed-compose' }
$arguments = @(
  $controller, '--topology', $topologyKind,
  '--tenant-environment', $TenantEnvironment, '--source-fixture-evidence', $SourceFixtureEvidence,
  '--platform-credentials', $PlatformCredentials, '--tenant-slug', $TenantSlug,
  '--source-activation-command-file', $SourceActivationCommandFile, '--target-activation-command-file', $TargetActivationCommandFile,
  '--discovery-edge-network', $DiscoveryEdgeNetwork, '--local-ca-cert', $LocalCaCert, '--local-ca-key', $LocalCaKey,
  '--tenant-id', $TenantId, '--fixture-run-id', $FixtureRunId,
  '--collision-issuer', $CollisionIssuer, '--changed-issuer', $ChangedIssuer, '--stale-issuer', $StaleIssuer,
  '--platform-base-url', $PlatformBaseUrl, '--console-base-url', $ConsoleBaseUrl,
  '--evidence-dir', $EvidenceDirectory, '--screenshot-command-file', $ScreenshotCommandFile,
  '--compose-project', $ComposeProject, '--compose-env-file', $ComposeEnvFile,
  '--platform-database-container', $PlatformDatabaseContainer, '--tenant-as-database-container', $TenantAsDatabaseContainer, '--runtime-service', $runtimeService, '--tenant-as-runtime-service', $tenantAsRuntimeService,
  '--platform-postgres-user', $PlatformPostgresUser, '--platform-postgres-database', $PlatformPostgresDatabase,
  '--tenant-as-postgres-user', $TenantAsPostgresUser, '--tenant-as-postgres-database', $TenantAsPostgresDatabase
)
foreach ($file in $ComposeFile) { $arguments += @('--compose-file', $file) }
foreach ($service in $managedRuntime) { $arguments += @('--managed-runtime', $service) }
& node @arguments
if ($LASTEXITCODE -ne 0) { throw "Authorization-server live fixture failed with exit code $LASTEXITCODE." }
