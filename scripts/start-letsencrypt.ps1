param(
  [Parameter(Mandatory = $true)]
  [string]$BaseDomain,
  [Parameter(Mandatory = $true)]
  [string]$Email,
  [ValidateSet('tls-alpn', 'dns')]
  [string]$Challenge = 'tls-alpn',
  [string]$DnsProvider = '',
  [switch]$Staging,
  [string]$TenantAliases = 'tenant-as,acme,globex,initech',
  [string]$DdnsCommand = '',
  [string]$DdnsUpdateUrl = '',
  [switch]$Up
)

$ErrorActionPreference = 'Stop'

if ($Challenge -eq 'dns' -and [string]::IsNullOrWhiteSpace($DnsProvider)) {
  throw "-DnsProvider is required when -Challenge dns, for example: -DnsProvider cloudflare"
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$kitRoot = Resolve-Path (Join-Path $scriptDir '..')
$composeDir = Join-Path $kitRoot 'compose'
$traefikDir = Join-Path $composeDir 'gateway\traefik'

$caServer = if ($Staging) {
  'https://acme-staging-v02.api.letsencrypt.org/directory'
} else {
  'https://acme-v02.api.letsencrypt.org/directory'
}

$challengeBlock = if ($Challenge -eq 'dns') {
@"
      dnsChallenge:
        provider: $DnsProvider
"@
} else {
  '      tlsChallenge: {}'
}

$dnsEnvSection = ''
if ($Challenge -eq 'dns') {
  if ($DnsProvider -eq 'cloudflare') {
    $dnsEnvSection = @"
    environment:
      CF_DNS_API_TOKEN: `${CF_DNS_API_TOKEN}
"@
  } else {
    Write-Host "DNS provider '$DnsProvider' selected. Add the provider credential environment passthrough to compose/docker-compose.letsencrypt.yml after rendering if needed."
  }
}

$escapedBaseDomain = [regex]::Escape($BaseDomain)
$aliases = @()
$aliasDomains = @()
foreach ($alias in $TenantAliases.Split(',')) {
  $trimmed = $alias.Trim()
  if ($trimmed.Length -gt 0) {
    $aliases += "          - $trimmed.$BaseDomain"
    $aliasDomains += "$trimmed.$BaseDomain"
  }
}
$tenantAliasesBlock = ($aliases -join [Environment]::NewLine)

$tlsDomains = ''
if ($Challenge -eq 'dns') {
  $tlsDomains = @"
        domains:
          - main: "$BaseDomain"
            sans:
              - "*.$BaseDomain"
"@
} else {
  $sanLines = @()
  foreach ($domain in $aliasDomains) {
    $sanLines += "              - `"$domain`""
  }
  if ($sanLines.Count -gt 0) {
    $tlsDomains = @"
        domains:
          - main: "platform.$BaseDomain"
            sans:
$($sanLines -join [Environment]::NewLine)
"@
  } else {
    $tlsDomains = @"
        domains:
          - main: "platform.$BaseDomain"
"@
  }
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
  [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

$static = Get-Content (Join-Path $traefikDir 'traefik.letsencrypt.template.yml') -Raw
$static = $static.Replace('__LE_EMAIL__', $Email)
$static = $static.Replace('__LE_CASERVER__', $caServer)
$static = $static.Replace('__LE_CHALLENGE_BLOCK__', $challengeBlock)
Write-Utf8NoBom (Join-Path $traefikDir 'traefik.letsencrypt.generated.yml') $static

$dynamic = Get-Content (Join-Path $traefikDir 'dynamic.letsencrypt.template.yml') -Raw
$dynamic = $dynamic.Replace('saas\.localtest\.me', $escapedBaseDomain)
$dynamic = $dynamic.Replace('saas.localtest.me', $BaseDomain)
$dynamic = $dynamic.Replace('__LE_TLS_DOMAINS__', $tlsDomains)
Write-Utf8NoBom (Join-Path $traefikDir 'dynamic.letsencrypt.generated.yml') $dynamic

$compose = Get-Content (Join-Path $composeDir 'docker-compose.letsencrypt.template.yml') -Raw
$compose = $compose.Replace('saas.localtest.me', $BaseDomain)
$compose = $compose.Replace('__LE_DNS_ENV_SECTION__', $dnsEnvSection)
$compose = $compose.Replace('__LE_TENANT_ALIASES__', $tenantAliasesBlock)
Write-Utf8NoBom (Join-Path $composeDir 'docker-compose.letsencrypt.yml') $compose

Write-Host "Generated Let's Encrypt gateway files for $BaseDomain"
Write-Host "  $composeDir\docker-compose.letsencrypt.yml"
Write-Host "  $traefikDir\traefik.letsencrypt.generated.yml"
Write-Host "  $traefikDir\dynamic.letsencrypt.generated.yml"

if ($DdnsCommand) {
  Write-Host "Running DDNS command"
  Invoke-Expression $DdnsCommand
} elseif ($DdnsUpdateUrl) {
  $masked = if ($DdnsUpdateUrl.Contains('?')) { ($DdnsUpdateUrl -split '\?')[0] + '?<query-redacted>' } else { $DdnsUpdateUrl }
  Write-Host "Calling DDNS update URL: $masked"
  Invoke-WebRequest -UseBasicParsing -Uri $DdnsUpdateUrl | Out-Null
}

Write-Host ""
Write-Host "DNS must point platform.$BaseDomain and *.$BaseDomain at this machine. Inbound TCP 443 must reach Docker."
if ($Challenge -eq 'dns' -and $DnsProvider -eq 'cloudflare') {
  Write-Host "Before compose up, set: `$env:CF_DNS_API_TOKEN='<token>'"
}
Write-Host ""
Write-Host "Start with:"
Write-Host "  cd compose"
Write-Host "  docker compose -f docker-compose.yml -f docker-compose.letsencrypt.yml up -d --wait"
Write-Host ""
Write-Host "Operator console: https://platform.$BaseDomain/admin-console"

if ($Up) {
  Push-Location $composeDir
  try {
    docker compose -f docker-compose.yml -f docker-compose.letsencrypt.yml up -d --wait
  } finally {
    Pop-Location
  }
}
