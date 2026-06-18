<#
.SYNOPSIS
  Onboards a freshly deployed Sphereon EDK enterprise platform and its first
  production tenant by calling the published REST APIs directly.

.DESCRIPTION
  This script runs against a RUNNING deployment (the Docker Compose
  stack or a Kubernetes install). It performs, in order:

    1. Waits for the enterprise services to report healthy.
    2. Platform setup (only if the setup gate is still open): bootstraps the
       operator account and imports your protected license bundle.
    3. Signs the operator in through the platform authorization-code flow with
       PKCE, carrying cookies and the login form CSRF tuple like a browser.
    4. Registers the first production tenant.
    5. Binds the tenant's three public endpoints (issuer, verifier, AS).
    6. Prints a summary with the operator console URL and the tenant's public
       metadata URLs.

  Prerequisites:
    - A running EDK enterprise deployment reachable at platform.<baseDomain>
      and <tenantSlug>.<baseDomain>, or explicit service URLs in the environment file.
    - A Sphereon protected license bundle ZIP plus bundle key (set in the
      environment file as licenseBundleZipPath and licenseBundleKey).
    - Node.js installed (used to parse the environment JSON and compute the
      PKCE S256 code challenge).
    - Windows PowerShell 5.1 or later.

  Configuration is read from the kit's Postman customer environment file
  (..\postman\EDK-Enterprise-Deployment.customer.postman_environment.json by
  default). The default environment derives public service URLs from baseDomain
  and tenantSlug. Override individual values with the flags below.

.EXAMPLE
  .\provision.ps1

.EXAMPLE
  .\provision.ps1 -TenantName "Acme Corporation" -TenantSlug acme `
    -EnvFile ..\postman\EDK-Enterprise-Deployment.customer.postman_environment.json

.EXAMPLE
  .\provision.ps1 -SkipSetup   # platform already initialized
#>
param(
  [string]$EnvFile,
  [string]$TenantName,
  [string]$TenantSlug,
  [switch]$SkipSetup,
  [switch]$Help
)

$ErrorActionPreference = "Stop"

if ($Help) {
  Get-Help $MyInvocation.MyCommand.Path -Detailed
  exit 0
}

function Fail([string]$message) {
  Write-Host "ERROR: $message" -ForegroundColor Red
  exit 1
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

if ([string]::IsNullOrWhiteSpace($EnvFile)) {
  $EnvFile = Join-Path $scriptDir "..\postman\EDK-Enterprise-Deployment.customer.postman_environment.json"
}
if (-not (Test-Path $EnvFile)) { Fail "Environment file not found: $EnvFile" }

# Require node: it parses the Postman environment JSON and computes the PKCE
# S256 code challenge. Both scripts depend on node for consistency.
$node = Get-Command node -ErrorAction SilentlyContinue
if ($null -eq $node) { Fail "node is required but was not found on PATH. Install Node.js and retry." }
$curl = Get-Command curl.exe -ErrorAction SilentlyContinue
if ($null -eq $curl) { Fail "curl.exe is required but was not found on PATH." }

# --- Load the Postman environment file into a flat hashtable ------------------
$envFileResolved = (Resolve-Path $EnvFile).Path
$envScript = @'
const fs = require('fs');
const doc = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
const out = {};
for (const v of (doc.values || [])) {
  if (v && v.key && (v.enabled === undefined || v.enabled)) out[v.key] = v.value;
}
process.stdout.write(JSON.stringify(out));
'@
$envJson = & node -e $envScript $envFileResolved
if ($LASTEXITCODE -ne 0) { Fail "Failed to parse environment file: $envFileResolved" }
$cfg = $envJson | ConvertFrom-Json

function Cfg([string]$key) {
  $val = $cfg.$key
  if ($null -eq $val) { return $null }
  return [string]$val
}

# --- Resolve effective config (flags override the environment file) -----------
$platformUrl = Cfg 'platformUrl'
$kmsUrl      = Cfg 'kmsUrl'
$didUrl      = Cfg 'didUrl'
$asUrl       = Cfg 'asUrl'
$issuerUrl   = Cfg 'issuerUrl'
$verifierUrl = Cfg 'verifierUrl'
$baseDomain  = Cfg 'baseDomain'

$operatorEmail        = Cfg 'operatorEmail'
$operatorDisplayName  = Cfg 'operatorDisplayName'
if ([string]::IsNullOrWhiteSpace($operatorDisplayName)) { $operatorDisplayName = 'Platform Operator' }
$operatorPassword     = Cfg 'operatorPassword'
$operatorRedirectUri  = Cfg 'operatorRedirectUri'
$operatorCodeVerifier = Cfg 'operatorCodeVerifier'
$licenseBundleZipPath = Cfg 'licenseBundleZipPath'
$licenseBundleKey     = Cfg 'licenseBundleKey'
$installationId       = Cfg 'installationId'

if ([string]::IsNullOrWhiteSpace($TenantName)) { $TenantName = Cfg 'tenantName' }
if ([string]::IsNullOrWhiteSpace($TenantSlug)) { $TenantSlug = Cfg 'tenantSlug' }

$tenantHost = Cfg 'tenantHost'
$issuerPublicHost   = Cfg 'issuerPublicHost'
$verifierPublicHost = Cfg 'verifierPublicHost'
$asPublicHost       = Cfg 'asPublicHost'

if (-not [string]::IsNullOrWhiteSpace($baseDomain)) {
  $baseDomain = $baseDomain -replace '^https?://', ''
  $baseDomain = $baseDomain.TrimEnd('/')
}
if ([string]::IsNullOrWhiteSpace($tenantHost) -and -not [string]::IsNullOrWhiteSpace($baseDomain) -and -not [string]::IsNullOrWhiteSpace($TenantSlug)) {
  $tenantHost = "$TenantSlug.$baseDomain"
}
if ([string]::IsNullOrWhiteSpace($platformUrl) -and -not [string]::IsNullOrWhiteSpace($baseDomain)) {
  $platformUrl = "https://platform.$baseDomain"
}
if (-not [string]::IsNullOrWhiteSpace($tenantHost)) {
  $tenantUrl = "https://$tenantHost"
  if ([string]::IsNullOrWhiteSpace($kmsUrl))      { $kmsUrl      = $tenantUrl }
  if ([string]::IsNullOrWhiteSpace($didUrl))      { $didUrl      = $tenantUrl }
  if ([string]::IsNullOrWhiteSpace($asUrl))       { $asUrl       = $tenantUrl }
  if ([string]::IsNullOrWhiteSpace($issuerUrl))   { $issuerUrl   = $tenantUrl }
  if ([string]::IsNullOrWhiteSpace($verifierUrl)) { $verifierUrl = $tenantUrl }
  if ([string]::IsNullOrWhiteSpace($issuerPublicHost))   { $issuerPublicHost   = $tenantHost }
  if ([string]::IsNullOrWhiteSpace($verifierPublicHost)) { $verifierPublicHost = $tenantHost }
  if ([string]::IsNullOrWhiteSpace($asPublicHost))       { $asPublicHost       = $tenantHost }
}
if ([string]::IsNullOrWhiteSpace($operatorRedirectUri) -and -not [string]::IsNullOrWhiteSpace($platformUrl)) {
  $operatorRedirectUri = "$($platformUrl.TrimEnd('/'))/admin-console/callback"
}

if ([string]::IsNullOrWhiteSpace($platformUrl)) { Fail "platformUrl is not set in the environment file." }
if ([string]::IsNullOrWhiteSpace($TenantName))  { Fail "tenantName is not set (use -TenantName or set it in the environment file)." }
if ([string]::IsNullOrWhiteSpace($TenantSlug))  { Fail "tenantSlug is not set (use -TenantSlug or set it in the environment file)." }

$platformUrl = $platformUrl.TrimEnd('/')

# --- HTTP helpers -------------------------------------------------------------
function Invoke-Json {
  param(
    [string]$Method,
    [string]$Uri,
    [object]$Body,
    [string]$BearerToken
  )
  $headers = @{}
  if ($BearerToken) { $headers['Authorization'] = "Bearer $BearerToken" }
  try {
    if ($null -ne $Body) {
      $raw = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 12 }
      return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers `
        -ContentType 'application/json' -Body $raw
    } else {
      return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers
    }
  } catch {
    $status = ""
    if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
    Fail "$Method $Uri failed ($status): $($_.Exception.Message)"
  }
}

function Invoke-LicenseBundle {
  param([string]$Uri)
  $tmp = [System.IO.Path]::GetTempFileName()
  try {
    $args = @(
      '-s', '-o', $tmp, '-w', '%{http_code}', '-X', 'POST', $Uri,
      '-F', "bundle=@$licenseBundleZipPath;type=application/zip",
      '-F', "bundleKey=$licenseBundleKey"
    )
    if (-not [string]::IsNullOrWhiteSpace($installationId)) {
      $args += @('-F', "installationId=$installationId")
    }
    $code = & curl.exe @args
    $out = Get-Content -Path $tmp -Raw
    if ($LASTEXITCODE -ne 0 -or -not ($code -match '^2')) {
      Fail "POST $Uri failed ($code): $out"
    }
    return $out
  } finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
  }
}

# --- Step 1: wait for health --------------------------------------------------
function Wait-Health {
  param([hashtable]$Services, [int]$Retries = 30, [int]$DelaySeconds = 4)
  Write-Host "Waiting for services to report healthy..." -ForegroundColor Cyan
  foreach ($name in $Services.Keys) {
    $url = $Services[$name]
    if ([string]::IsNullOrWhiteSpace($url)) { continue }
    $healthUrl = "$($url.TrimEnd('/'))/health"
    $ok = $false
    for ($i = 0; $i -lt $Retries; $i++) {
      try {
        $resp = Invoke-WebRequest -Uri $healthUrl -Method Get -UseBasicParsing -TimeoutSec 10
        if ($resp.StatusCode -eq 200) { $ok = $true; break }
      } catch { }
      Start-Sleep -Seconds $DelaySeconds
    }
    if ($ok) { Write-Host "  [ok]   $name ($healthUrl)" -ForegroundColor Green }
    else { Fail "$name did not become healthy at $healthUrl" }
  }
}

$services = [ordered]@{
  platform = $platformUrl
}
Wait-Health -Services $services

# --- Step 2: platform setup (idempotent) --------------------------------------
$setupStatusUrl = "$platformUrl/api/platform/setup/v1/status"
$setupOpen = $false
if ($SkipSetup) {
  Write-Host "Skipping platform setup (-SkipSetup)." -ForegroundColor Yellow
} else {
  Write-Host "Checking platform setup status..." -ForegroundColor Cyan
  $statusCode = 0
  try {
    $resp = Invoke-WebRequest -Uri $setupStatusUrl -Method Get -UseBasicParsing -TimeoutSec 15
    $statusCode = [int]$resp.StatusCode
  } catch {
    if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode }
  }
  # 404 means the anonymous setup gate is closed and setup is already done.
  if ($statusCode -eq 404) {
    Write-Host "  Setup gate is closed (already initialized). Skipping setup." -ForegroundColor Yellow
  } elseif ($statusCode -eq 200) {
    $setupOpen = $true
  } else {
    Write-Host "  Setup status returned $statusCode; treating setup as closed." -ForegroundColor Yellow
  }
}

if ($setupOpen) {
  if ([string]::IsNullOrWhiteSpace($operatorEmail) -or [string]::IsNullOrWhiteSpace($operatorPassword)) {
    Fail "operatorEmail and operatorPassword are required to bootstrap the operator."
  }
  if ([string]::IsNullOrWhiteSpace($licenseBundleZipPath) -or $licenseBundleZipPath -like 'PASTE-*') {
    Fail "licenseBundleZipPath is not set in the environment file. Set it before running setup."
  }
  if ([string]::IsNullOrWhiteSpace($licenseBundleKey) -or $licenseBundleKey -like 'PASTE-*') {
    Fail "licenseBundleKey is not set in the environment file. Set it before running setup."
  }
  if (-not (Test-Path -LiteralPath $licenseBundleZipPath)) {
    Fail "licenseBundleZipPath does not point to a file: $licenseBundleZipPath"
  }
  $licenseBundleZipPath = (Resolve-Path -LiteralPath $licenseBundleZipPath).Path

  Write-Host "Previewing license bundle import..." -ForegroundColor Cyan
  $null = Invoke-LicenseBundle -Uri "$platformUrl/api/platform/setup/v1/license/import/preview"
  Write-Host "  License bundle preview accepted." -ForegroundColor Green

  Write-Host "Importing license bundle..." -ForegroundColor Cyan
  $null = Invoke-LicenseBundle -Uri "$platformUrl/api/platform/setup/v1/license/import"
  Write-Host "  License bundle imported." -ForegroundColor Green

  Write-Host "Bootstrapping platform operator..." -ForegroundColor Cyan
  $null = Invoke-Json -Method Post -Uri "$platformUrl/api/platform/setup/v1/bootstrap" -Body @{
    adminEmail       = $operatorEmail
    adminDisplayName = $operatorDisplayName
    adminPassword    = $operatorPassword
  }
  Write-Host "  Operator bootstrapped; setup gate closed." -ForegroundColor Green
}

# --- Step 3: operator sign-in (PKCE authorization-code flow) -------------------
if ([string]::IsNullOrWhiteSpace($operatorEmail) -or [string]::IsNullOrWhiteSpace($operatorPassword)) {
  Fail "operatorEmail and operatorPassword are required to sign in."
}
if ([string]::IsNullOrWhiteSpace($operatorRedirectUri))  { Fail "operatorRedirectUri is not set." }
if ([string]::IsNullOrWhiteSpace($operatorCodeVerifier)) { Fail "operatorCodeVerifier is not set." }

Write-Host "Signing in as operator..." -ForegroundColor Cyan

# Compute S256(code_verifier) -> base64url, without padding.
$challengeScript = @'
const crypto = require('crypto');
const v = process.argv[1];
const c = crypto.createHash('sha256').update(v).digest('base64')
  .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
process.stdout.write(c);
'@
$codeChallenge = & node -e $challengeScript $operatorCodeVerifier
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($codeChallenge)) {
  Fail "Failed to compute PKCE code challenge."
}

$state = "operator-state-$([guid]::NewGuid().ToString('N').Substring(0,12))"

function UrlEncode([string]$s) { return [System.Uri]::EscapeDataString($s) }

# 3.1 Start the authorization request. Do not follow redirects; read Location.
$authorizeUrl = "$platformUrl/authorize?response_type=code&client_id=platform-operator-cli" +
  "&redirect_uri=$(UrlEncode $operatorRedirectUri)&scope=openid&state=$state" +
  "&code_challenge=$codeChallenge&code_challenge_method=S256"

$loginPageUrl = $null
try {
  $resp = Invoke-WebRequest -Uri $authorizeUrl -Method Get -MaximumRedirection 0 `
    -SessionVariable opSession -UseBasicParsing -ErrorAction Stop
  $loginPageUrl = $resp.Headers['Location']
} catch {
  # 5.1: a 302 surfaces as a terminating error when MaximumRedirection is 0.
  $r = $_.Exception.Response
  if ($r -and ([int]$r.StatusCode -eq 302 -or [int]$r.StatusCode -eq 301)) {
    $loginPageUrl = $r.Headers['Location']
  } else {
    Fail "authorize request did not redirect to the login page: $($_.Exception.Message)"
  }
}
if ([string]::IsNullOrWhiteSpace($loginPageUrl)) { Fail "authorize did not return a login page Location." }
if ($loginPageUrl -notmatch '^https?://') { $loginPageUrl = "$platformUrl$loginPageUrl" }

# Extract session_id and return_url carried on the login URL.
$sessionId = $null; $returnUrl = $null
if ($loginPageUrl -match '[?&]session_id=([^&]+)') { $sessionId = [System.Uri]::UnescapeDataString($Matches[1]) }
if ($loginPageUrl -match '[?&]return_url=([^&]+)') { $returnUrl = [System.Uri]::UnescapeDataString($Matches[1]) }

# 3.2 Load the login page (sets CSRF cookie, embeds tab_id and session_code).
$loginHtml = ""
try {
  $resp = Invoke-WebRequest -Uri $loginPageUrl -Method Get -WebSession $opSession -UseBasicParsing -ErrorAction Stop
  $loginHtml = $resp.Content
} catch {
  Fail "Failed to load operator login page: $($_.Exception.Message)"
}
$tabId = $null; $sessionCode = $null
if ($loginHtml -match 'name="tab_id"\s+value="([^"]+)"') { $tabId = $Matches[1] }
if ($loginHtml -match 'name="session_code"\s+value="([^"]+)"') { $sessionCode = $Matches[1] }

# 3.3 Submit credentials with the CSRF tuple. Do not follow the redirect.
$loginBody = @{
  username = $operatorEmail
  password = $operatorPassword
}
if ($sessionId)   { $loginBody['session_id']   = $sessionId }
if ($tabId)       { $loginBody['tab_id']        = $tabId }
if ($sessionCode) { $loginBody['session_code']  = $sessionCode }
if ($returnUrl)   { $loginBody['return_url']    = $returnUrl }

$callbackUrl = $null
try {
  $resp = Invoke-WebRequest -Uri "$platformUrl/login" -Method Post -Body $loginBody `
    -WebSession $opSession -MaximumRedirection 0 -UseBasicParsing -ErrorAction Stop
  $callbackUrl = $resp.Headers['Location']
} catch {
  $r = $_.Exception.Response
  if ($r -and ([int]$r.StatusCode -eq 302 -or [int]$r.StatusCode -eq 301)) {
    $callbackUrl = $r.Headers['Location']
  } else {
    Fail "Operator login failed: $($_.Exception.Message)"
  }
}
if ([string]::IsNullOrWhiteSpace($callbackUrl)) { Fail "Login did not return a callback Location." }
if ($callbackUrl -match 'error=invalid_credentials') { Fail "Operator login rejected: invalid credentials." }
if ($callbackUrl -notmatch '^https?://') { $callbackUrl = "$platformUrl$callbackUrl" }

# 3.4 Resume the authorization callback to obtain the authorization code.
$redirectWithCode = $null
try {
  $resp = Invoke-WebRequest -Uri $callbackUrl -Method Get -WebSession $opSession `
    -MaximumRedirection 0 -UseBasicParsing -ErrorAction Stop
  $redirectWithCode = $resp.Headers['Location']
} catch {
  $r = $_.Exception.Response
  if ($r -and ([int]$r.StatusCode -eq 302 -or [int]$r.StatusCode -eq 301)) {
    $redirectWithCode = $r.Headers['Location']
  } else {
    Fail "Authorization callback failed: $($_.Exception.Message)"
  }
}
if ([string]::IsNullOrWhiteSpace($redirectWithCode)) { Fail "Callback did not return a redirect with code." }
$authCode = $null
if ($redirectWithCode -match '[?&#]code=([^&]+)') { $authCode = [System.Uri]::UnescapeDataString($Matches[1]) }
if ([string]::IsNullOrWhiteSpace($authCode)) { Fail "Authorization code not found in callback redirect." }

# 3.5 Exchange the code for an operator access token.
$tokenBody = @{
  grant_type    = 'authorization_code'
  code          = $authCode
  redirect_uri  = $operatorRedirectUri
  client_id     = 'platform-operator-cli'
  code_verifier = $operatorCodeVerifier
}
$operatorToken = $null
try {
  $tok = Invoke-RestMethod -Method Post -Uri "$platformUrl/token" -Body $tokenBody `
    -ContentType 'application/x-www-form-urlencoded' -WebSession $opSession
  $operatorToken = $tok.access_token
} catch {
  Fail "Token exchange failed: $($_.Exception.Message)"
}
if ([string]::IsNullOrWhiteSpace($operatorToken)) { Fail "No access_token returned from /token." }
Write-Host "  Operator signed in." -ForegroundColor Green

# --- Step 4: register the first production tenant -----------------------------
Write-Host "Registering tenant '$TenantName' ($TenantSlug)..." -ForegroundColor Cyan
$tenantBody = @{
  tenantType    = 'organization'
  name          = $TenantName
  description   = "$TenantName issuing and verification tenant"
  slug          = $TenantSlug
  owner         = @{
    type        = 'local'
    email       = "admin@$TenantSlug.example"
    displayName = "$TenantName Administrator"
  }
  ownerDelivery = @{ mode = 'none' }
}
$tenantsUrl = "$platformUrl/api/platform/admin/v1/tenants"
$tenantId = $null
try {
  $created = Invoke-RestMethod -Method Post -Uri $tenantsUrl -Headers @{ Authorization = "Bearer $operatorToken" } `
    -ContentType 'application/json' -Body ($tenantBody | ConvertTo-Json -Depth 8)
  if ($created.tenant -and $created.tenant.id) { $tenantId = $created.tenant.id }
  elseif ($created.id) { $tenantId = $created.id }
  Write-Host "  Tenant registered: $tenantId" -ForegroundColor Green
} catch {
  $status = 0
  if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
  if ($status -eq 409) {
    Write-Host "  Tenant '$TenantSlug' already exists; continuing." -ForegroundColor Yellow
    # Try to resolve its id from the listing so endpoint binding can proceed.
    try {
      $list = Invoke-RestMethod -Method Get -Uri $tenantsUrl -Headers @{ Authorization = "Bearer $operatorToken" }
      $items = if ($list.items) { $list.items } elseif ($list -is [System.Array]) { $list } else { $list.tenants }
      foreach ($t in $items) { if ($t.slug -eq $TenantSlug) { $tenantId = $t.id; break } }
    } catch { }
  } else {
    Fail "Tenant registration failed ($status): $($_.Exception.Message)"
  }
}
if ([string]::IsNullOrWhiteSpace($tenantId)) {
  Fail "Could not determine tenantId; cannot bind public endpoints."
}

# --- Step 5: bind the three public endpoints ----------------------------------
function Bind-Endpoint {
  param([string]$Kind, [string]$PublicHost)
  if ([string]::IsNullOrWhiteSpace($PublicHost)) {
    Write-Host "  Skipping $Kind (no public host configured)." -ForegroundColor Yellow
    return
  }
  $url = "$platformUrl/api/platform/admin/v1/tenants/$tenantId/public-endpoints/$Kind"
  $null = Invoke-Json -Method Put -Uri $url -BearerToken $operatorToken -Body @{
    host            = $PublicHost
    enabled         = $true
    primaryEndpoint = $true
  }
  Write-Host "  Bound $Kind -> $PublicHost" -ForegroundColor Green
}

Write-Host "Binding public endpoints..." -ForegroundColor Cyan
Bind-Endpoint -Kind 'OID4VCI_ISSUER' -PublicHost $issuerPublicHost
Bind-Endpoint -Kind 'OID4VP_VERIFIER' -PublicHost $verifierPublicHost
Bind-Endpoint -Kind 'OAUTH2_AUTHORIZATION_SERVER' -PublicHost $asPublicHost

# Read the bindings back for confirmation.
$bound = Invoke-Json -Method Get -BearerToken $operatorToken `
  -Uri "$platformUrl/api/platform/admin/v1/tenants/$tenantId/public-endpoints"

# --- Step 6: summary ----------------------------------------------------------
Write-Host ""
Write-Host "==================== Tenant onboarded ====================" -ForegroundColor Green
Write-Host "Operator console : $platformUrl"
Write-Host "Tenant           : $TenantName [$TenantSlug] ($tenantId)"
Write-Host ""
if (-not [string]::IsNullOrWhiteSpace($issuerPublicHost)) {
  Write-Host "Issuer metadata  : https://$issuerPublicHost/.well-known/openid-credential-issuer"
}
if (-not [string]::IsNullOrWhiteSpace($asPublicHost)) {
  Write-Host "AS metadata      : https://$asPublicHost/.well-known/oauth-authorization-server"
}
if (-not [string]::IsNullOrWhiteSpace($verifierPublicHost)) {
  Write-Host "Verifier host    : https://$verifierPublicHost"
}
if (-not [string]::IsNullOrWhiteSpace($issuerPublicHost)) {
  Write-Host "did.json         : https://$issuerPublicHost/.well-known/did.json"
}
Write-Host "=========================================================="
exit 0
