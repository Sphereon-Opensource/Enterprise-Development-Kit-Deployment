<#
.SYNOPSIS
  Generate a local wildcard TLS certificate for the single-port gateway, for
  LOCAL EVALUATION of the kit.

.DESCRIPTION
  The kit's single-port gateway terminates TLS for every tenant and the operator
  host under one wildcard certificate. This helper produces that certificate for
  local evaluation. For production, front the gateway with a publicly-trusted
  certificate instead and skip this script.

  Output (compose/gateway/certs/):
    wildcard.crt / wildcard.key   server cert for the selected base domain, mounted into Traefik
    local-ca.crt                  the local CA; trust this in your OS/browser/wallet
    local-truststore.p12          JVM default public roots plus the local CA (password:
                                  changeit), mounted into service containers so internal
                                  gateway TLS and public provider endpoints both validate

  Uses mkcert when available (auto-trusted after 'mkcert -install'), otherwise a self-signed
  openssl CA you trust manually. Re-run any time; it overwrites the cert material.
#>
param(
  [string]$BaseDomain = $(if ($env:EDK_PLATFORM_BASE_DOMAIN) { $env:EDK_PLATFORM_BASE_DOMAIN } else { "" }),
  [switch]$Localtest,
  [string]$TruststorePassword = $(if ($env:EDK_TRUSTSTORE_PASSWORD) { $env:EDK_TRUSTSTORE_PASSWORD } else { "changeit" })
)

$ErrorActionPreference = "Stop"

if ($Localtest -and $PSBoundParameters.ContainsKey("BaseDomain")) { throw "-Localtest and -BaseDomain are mutually exclusive." }
if ($Localtest) { $BaseDomain = "saas.localtest.me" }
if ([string]::IsNullOrWhiteSpace($BaseDomain)) {
  throw "A base domain is required. Pass -BaseDomain, set EDK_PLATFORM_BASE_DOMAIN, or pass -Localtest explicitly."
}
$BaseDomain = $BaseDomain.Trim()
if ($BaseDomain -match '^[a-zA-Z][a-zA-Z0-9+.-]*://' -or $BaseDomain -match '[/\\\s:]' -or $BaseDomain.StartsWith('.') -or $BaseDomain.EndsWith('.')) {
  throw "BaseDomain must be a hostname without scheme, port, path, or whitespace; got '$BaseDomain'."
}
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$certDir = Join-Path (Split-Path -Parent $scriptDir) "compose\gateway\certs"
New-Item -ItemType Directory -Force -Path $certDir | Out-Null

Write-Host "Generating local wildcard cert for *.$BaseDomain -> $certDir"

function Test-Cmd($name) { return [bool](Get-Command $name -ErrorAction SilentlyContinue) }

# openssl is often not on the PowerShell PATH on Windows even when Git ships it.
function Resolve-OpenSsl {
  $c = Get-Command openssl -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  foreach ($p in @(
      "$env:ProgramFiles\Git\usr\bin\openssl.exe",
      "${env:ProgramFiles(x86)}\Git\usr\bin\openssl.exe",
      "$env:LOCALAPPDATA\Programs\Git\usr\bin\openssl.exe",
      "$env:ProgramFiles\Git\mingw64\bin\openssl.exe")) {
    if ($p -and (Test-Path $p)) { return $p }
  }
  return $null
}

# keytool ships with the JDK; fall back to JAVA_HOME when it is not on PATH.
function Resolve-Keytool {
  $c = Get-Command keytool -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  foreach ($base in @($env:JAVA_HOME, $env:JDK_HOME)) {
    if ($base) { $p = Join-Path $base "bin\keytool.exe"; if (Test-Path $p) { return $p } }
  }
  return $null
}

function Resolve-DefaultCacerts([string]$KeytoolPath) {
  $jdkRoot = Split-Path -Parent (Split-Path -Parent $KeytoolPath)
  foreach ($candidate in @(
      (Join-Path $jdkRoot "lib\security\cacerts"),
      (Join-Path $jdkRoot "jre\lib\security\cacerts"))) {
    if (Test-Path $candidate) { return $candidate }
  }
  return $null
}

# openssl/keytool write benign progress to stderr (e.g. "Certificate request
# self-signature ok"); under Windows PowerShell 5.1 + ErrorActionPreference=Stop
# that escalates to a terminating NativeCommandError. Relax it for the native
# section and validate the produced files explicitly afterwards.
$ErrorActionPreference = 'Continue'

if (Test-Cmd mkcert) {
  Write-Host "Using mkcert (run 'mkcert -install' once so your browser trusts it)."
  & mkcert -cert-file (Join-Path $certDir "wildcard.crt") -key-file (Join-Path $certDir "wildcard.key") `
    "*.$BaseDomain" "$BaseDomain" "platform.$BaseDomain" localhost 127.0.0.1
  $caRoot = (& mkcert -CAROOT).Trim()
  Copy-Item (Join-Path $caRoot "rootCA.pem") (Join-Path $certDir "local-ca.crt") -Force
}
else {
  $openssl = Resolve-OpenSsl
  if (-not $openssl) { throw "Neither mkcert nor openssl is available (checked PATH and Git's bundled openssl). Install one to generate the local-evaluation certificate." }
  Write-Host "mkcert not found; using a self-signed openssl CA via $openssl. Trust local-ca.crt manually."
  & $openssl genrsa -out (Join-Path $certDir "local-ca.key") 4096 2>$null
  & $openssl req -x509 -new -nodes -key (Join-Path $certDir "local-ca.key") -sha256 -days 3650 `
    -subj "/CN=EDK Local Evaluation CA/O=Sphereon EDK" -out (Join-Path $certDir "local-ca.crt") 2>$null
  & $openssl genrsa -out (Join-Path $certDir "wildcard.key") 2048 2>$null
  $san = @"
[req]
distinguished_name = dn
req_extensions = v3_req
prompt = no
[dn]
CN = *.$BaseDomain
[v3_req]
subjectAltName = @alt
[alt]
DNS.1 = *.$BaseDomain
DNS.2 = $BaseDomain
DNS.3 = platform.$BaseDomain
DNS.4 = localhost
IP.1 = 127.0.0.1
"@
  $sanPath = Join-Path $certDir ".san.cnf"
  Set-Content -Path $sanPath -Value $san -Encoding ascii
  & $openssl req -new -key (Join-Path $certDir "wildcard.key") -out (Join-Path $certDir ".wildcard.csr") -config $sanPath 2>$null
  & $openssl x509 -req -in (Join-Path $certDir ".wildcard.csr") -CA (Join-Path $certDir "local-ca.crt") `
    -CAkey (Join-Path $certDir "local-ca.key") -CAcreateserial -days 825 -sha256 `
    -extensions v3_req -extfile $sanPath -out (Join-Path $certDir "wildcard.crt") 2>$null
  Remove-Item (Join-Path $certDir ".wildcard.csr"), $sanPath, (Join-Path $certDir "local-ca.srl") -ErrorAction SilentlyContinue
}

$keytool = Resolve-Keytool
if ($keytool) {
  $ts = Join-Path $certDir "local-truststore.p12"
  $defaultCacerts = Resolve-DefaultCacerts $keytool
  if (-not $defaultCacerts) { throw "Could not locate the JVM default truststore next to $keytool." }
  Remove-Item $ts -ErrorAction SilentlyContinue
  & $keytool -importkeystore -noprompt -srckeystore $defaultCacerts -srcstorepass changeit `
    -destkeystore $ts -deststorepass $TruststorePassword -deststoretype PKCS12 2>$null
  if ($LASTEXITCODE -ne 0) { throw "Could not copy JVM public roots into local-truststore.p12." }
  & $keytool -importcert -noprompt -trustcacerts -alias edk-local-ca `
    -file (Join-Path $certDir "local-ca.crt") -keystore $ts -storetype PKCS12 -storepass $TruststorePassword 2>$null
  if ($LASTEXITCODE -ne 0) { throw "Could not add the local CA to local-truststore.p12." }
  Write-Host "Wrote local-truststore.p12 with JVM public roots and the local CA (password: $TruststorePassword)."
}
else {
  Write-Host "WARNING: keytool not found; local-truststore.p12 not generated."
  Write-Host "         Per-tenant JWKS over TLS from inside the service containers will fail until you create it."
}

$ErrorActionPreference = 'Stop'
Remove-Item (Join-Path $certDir ".wildcard.csr"), (Join-Path $certDir ".san.cnf"), (Join-Path $certDir "local-ca.srl") -ErrorAction SilentlyContinue
foreach ($f in @('wildcard.crt', 'wildcard.key', 'local-ca.crt')) {
  if (-not (Test-Path (Join-Path $certDir $f))) { throw "Certificate generation failed: $f was not produced." }
}

Write-Host "Done. Trust $certDir\local-ca.crt in your OS/browser to avoid cert warnings."
