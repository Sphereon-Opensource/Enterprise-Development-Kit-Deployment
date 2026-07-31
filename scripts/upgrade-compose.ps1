[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ImageTag,
    [string]$ComposeDir = (Join-Path $PSScriptRoot '..\compose'),
    [string[]]$File = @(),
    [string]$InstalledImageTag,
    [string]$BackupRoot = '.\edk-compose-upgrade-backup',
    [switch]$SkipTargetPull
)

$ErrorActionPreference = 'Stop'

function Invoke-DockerCompose {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    $composeArguments = @('compose', '--project-directory', $script:ComposeDirResolved)
    foreach ($composeFile in $script:ComposeFilesResolved) {
        $composeArguments += @('-f', $composeFile)
    }
    & docker @composeArguments @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "docker compose failed with exit code $LASTEXITCODE"
    }
}

function Get-ReleaseNumber([string]$Tag) {
    switch ($Tag.ToUpperInvariant()) {
        '0.25.0-RC1' { return 1 }
        '0.25.0-RC2' { return 2 }
        '0.25.0-RC3' { return 3 }
        default { return 0 }
    }
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw 'docker was not found on PATH.'
}
& docker compose version *> $null
if ($LASTEXITCODE -ne 0) { throw 'Docker Compose v2 is required.' }

$script:ComposeDirResolved = (Resolve-Path -LiteralPath $ComposeDir).Path
if ($File.Count -eq 0) { $File = @((Join-Path $script:ComposeDirResolved 'docker-compose.yml')) }
$script:ComposeFilesResolved = @($File | ForEach-Object { (Resolve-Path -LiteralPath $_).Path })
$stateFile = Join-Path $script:ComposeDirResolved '.edk-installed-image-tag'

if (-not $InstalledImageTag) {
    $composeArguments = @('compose', '--project-directory', $script:ComposeDirResolved)
    foreach ($composeFile in $script:ComposeFilesResolved) { $composeArguments += @('-f', $composeFile) }
    $containerId = (& docker @composeArguments ps -a -q enterprise-platform 2>$null | Select-Object -First 1)
    if ($containerId) {
        $image = (& docker inspect --format '{{.Config.Image}}' $containerId 2>$null)
        if ($image -and $image -notmatch '@sha256:' -and $image -match ':([^:]+)$') {
            $InstalledImageTag = $Matches[1]
        }
    }
    if (-not $InstalledImageTag -and (Test-Path -LiteralPath $stateFile)) {
        $InstalledImageTag = (Get-Content -Raw -LiteralPath $stateFile).Trim()
    }
    $envFile = Join-Path $script:ComposeDirResolved '.env'
    if (-not $InstalledImageTag -and (Test-Path -LiteralPath $envFile)) {
        $match = Select-String -LiteralPath $envFile -Pattern '^\s*EDK_TAG\s*=\s*([^#\s]+)' | Select-Object -Last 1
        if ($match) { $InstalledImageTag = $match.Matches[0].Groups[1].Value }
    }
}

$installedRelease = Get-ReleaseNumber $InstalledImageTag
$targetRelease = Get-ReleaseNumber $ImageTag
if ($installedRelease -gt 0 -and $targetRelease -gt 0 -and $targetRelease -lt $installedRelease) {
    throw "Refusing unsupported release downgrade: $InstalledImageTag -> $ImageTag"
}
$intermediateTag = $null
if ($installedRelease -eq 1 -and $targetRelease -ge 3) { $intermediateTag = '0.25.0-RC2' }

$timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
$backupDir = Join-Path $BackupRoot "edk-enterprise-$timestamp"
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
Invoke-DockerCompose config | Set-Content -LiteralPath (Join-Path $backupDir 'compose-before.yaml')
try { Invoke-DockerCompose ps -a | Set-Content -LiteralPath (Join-Path $backupDir 'containers-before.txt') } catch { }
if ($InstalledImageTag) { Set-Content -LiteralPath (Join-Path $backupDir 'installed-image-tag.txt') -Value $InstalledImageTag }

$originalTag = $env:EDK_TAG
try {
    function Invoke-ReleaseStep([string]$Tag, [bool]$IsTarget) {
        $env:EDK_TAG = $Tag
        Write-Host "Validating Docker Compose release $Tag."
        Invoke-DockerCompose config --quiet
        if (-not ($IsTarget -and $SkipTargetPull)) {
            Write-Host "Pulling published images for $Tag."
            Invoke-DockerCompose pull
        } else {
            Write-Host "Using locally built target images for $Tag; intermediate releases were still pulled."
        }
        Write-Host "Starting release $Tag and waiting for health checks."
        Invoke-DockerCompose up -d --wait --pull never
        Set-Content -LiteralPath $stateFile -Value $Tag
        Invoke-DockerCompose ps | Set-Content -LiteralPath (Join-Path $backupDir "containers-$Tag.txt")
    }

    Write-Host "Detected installed image tag: $(if ($InstalledImageTag) { $InstalledImageTag } else { '<fresh-install>' })"
    if ($intermediateTag) {
        Write-Host "Required ordered Compose upgrade: $InstalledImageTag -> $intermediateTag -> $ImageTag"
        Invoke-ReleaseStep $intermediateTag $false
    }
    Invoke-ReleaseStep $ImageTag $true
} finally {
    if ($null -eq $originalTag) { Remove-Item Env:EDK_TAG -ErrorAction SilentlyContinue } else { $env:EDK_TAG = $originalTag }
}

Write-Host "Compose install/upgrade completed successfully. Evidence: $backupDir"
Write-Host "Keep EDK_TAG=$ImageTag in .env for subsequent direct docker compose commands."
