param(
  [Parameter(Mandatory = $true)]
  [string]$BaseDomain,
  [Parameter(Mandatory = $true)]
  [string]$Email,
  [ValidateSet('tls-alpn', 'dns')]
  [string]$Challenge = 'tls-alpn',
  [string]$DnsProvider = '',
  [switch]$Staging,
  [string]$TenantAliases = '',
  [string]$DdnsCommand = '',
  [string]$DdnsUpdateUrl = '',
  [switch]$IncludeBaseDomain,
  [switch]$Up
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$kitRoot = Resolve-Path (Join-Path $scriptDir '..')
$composeDir = Join-Path $kitRoot 'compose'
$traefikDir = Join-Path $composeDir 'gateway\traefik'
$manualDns = $Challenge -eq 'dns' -and ([string]::IsNullOrWhiteSpace($DnsProvider) -or $DnsProvider -eq 'manual')

$caServer = if ($Staging) {
  'https://acme-staging-v02.api.letsencrypt.org/directory'
} else {
  'https://acme-v02.api.letsencrypt.org/directory'
}

$challengeBlock = if ($Challenge -eq 'dns' -and -not $manualDns) {
@"
      dnsChallenge:
        provider: $DnsProvider
"@
} else {
  '      tlsChallenge: {}'
}

$dnsEnvSection = ''
if ($Challenge -eq 'dns' -and -not $manualDns) {
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
  if ($IncludeBaseDomain) {
    $tlsDomains = @"
        domains:
          - main: "$BaseDomain"
            sans:
              - "*.$BaseDomain"
"@
  } else {
    $tlsDomains = @"
        domains:
          - main: "*.$BaseDomain"
"@
  }
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

if ($manualDns) {
  $dynamic = Get-Content (Join-Path $traefikDir 'dynamic.public-cert.template.yml') -Raw
  $dynamic = $dynamic.Replace('__BASE_DOMAIN_REGEX__', $escapedBaseDomain)
  $dynamic = $dynamic.Replace('__BASE_DOMAIN__', $BaseDomain)
  Write-Utf8NoBom (Join-Path $traefikDir 'dynamic.public-cert.generated.yml') $dynamic

  $compose = Get-Content (Join-Path $composeDir 'docker-compose.public-cert.template.yml') -Raw
  $compose = $compose.Replace('__BASE_DOMAIN__', $BaseDomain)
  $compose = $compose.Replace('__PUBLIC_CERT_TENANT_ALIASES__', $tenantAliasesBlock)
  Write-Utf8NoBom (Join-Path $composeDir 'docker-compose.public-cert.yml') $compose

  $certPath = Join-Path $composeDir 'gateway\certs\wildcard.crt'
  $keyPath = Join-Path $composeDir 'gateway\certs\wildcard.key'
  $hasCert = (Test-Path $certPath) -and (Test-Path $keyPath)

  Write-Host "Generated public static-certificate gateway files for $BaseDomain"
  Write-Host "  $composeDir\docker-compose.public-cert.yml"
  Write-Host "  $traefikDir\dynamic.public-cert.generated.yml"
  Write-Host ""
  Write-Host "Manual DNS-01 cannot be renewed by Traefik without DNS API credentials."
  Write-Host "Obtain or renew the certificate with an external ACME client, for example:"
  if ($IncludeBaseDomain) {
    Write-Host "  certbot certonly --manual --preferred-challenges dns --agree-tos --no-eff-email --email $Email -d `"$BaseDomain`" -d `"*.$BaseDomain`""
  } else {
    Write-Host "  certbot certonly --manual --preferred-challenges dns --agree-tos --no-eff-email --email $Email -d `"*.$BaseDomain`""
  }
  Write-Host ""
  Write-Host "When prompted, create the TXT value(s) at _acme-challenge.$BaseDomain and wait for DNS propagation."
  Write-Host "Then copy the issued files to:"
  Write-Host "  fullchain.pem -> $certPath"
  Write-Host "  privkey.pem   -> $keyPath"
  Write-Host ""
  Write-Host "DNS must point platform.$BaseDomain and *.$BaseDomain at this machine. Inbound TCP 443 must reach Docker."
  Write-Host ""
  Write-Host "Start with:"
  Write-Host "  cd compose"
  Write-Host "  docker compose -f docker-compose.yml -f docker-compose.public-cert.yml up -d --wait --remove-orphans"
  Write-Host ""
  Write-Host "First-run setup: https://platform.$BaseDomain/setup-license"
  Write-Host "Operator console after setup: https://platform.$BaseDomain/admin-console"

  if (-not $hasCert) {
    Write-Warning "Certificate files are not present yet: $certPath and $keyPath"
    if ($Up) {
      throw "Cannot start because the manual certificate files are missing."
    }
  } elseif ($Up) {
    Push-Location $composeDir
    try {
      docker compose -f docker-compose.yml -f docker-compose.public-cert.yml up -d --wait --remove-orphans
    } finally {
      Pop-Location
    }
  }

  return
}

$static = Get-Content (Join-Path $traefikDir 'traefik.letsencrypt.template.yml') -Raw
$static = $static.Replace('__LE_EMAIL__', $Email)
$static = $static.Replace('__LE_CASERVER__', $caServer)
$static = $static.Replace('__LE_CHALLENGE_BLOCK__', $challengeBlock)
Write-Utf8NoBom (Join-Path $traefikDir 'traefik.letsencrypt.generated.yml') $static

$dynamic = Get-Content (Join-Path $traefikDir 'dynamic.letsencrypt.template.yml') -Raw
$dynamic = $dynamic.Replace('__BASE_DOMAIN_REGEX__', $escapedBaseDomain)
$dynamic = $dynamic.Replace('__BASE_DOMAIN__', $BaseDomain)
$dynamic = $dynamic.Replace('__LE_TLS_DOMAINS__', $tlsDomains)
Write-Utf8NoBom (Join-Path $traefikDir 'dynamic.letsencrypt.generated.yml') $dynamic

$compose = Get-Content (Join-Path $composeDir 'docker-compose.letsencrypt.template.yml') -Raw
$compose = $compose.Replace('__BASE_DOMAIN__', $BaseDomain)
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
Write-Host "  docker compose -f docker-compose.yml -f docker-compose.letsencrypt.yml up -d --wait --remove-orphans"
Write-Host ""
Write-Host "First-run setup: https://platform.$BaseDomain/setup-license"
Write-Host "Operator console after setup: https://platform.$BaseDomain/admin-console"

if ($Up) {
  Push-Location $composeDir
  try {
    docker compose -f docker-compose.yml -f docker-compose.letsencrypt.yml up -d --wait --remove-orphans
  } finally {
    Pop-Location
  }
}
