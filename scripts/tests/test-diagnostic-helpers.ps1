# Exercises real boundaries without OpenSSL or customer HTTP; login uses an owned loopback fixture.
$ErrorActionPreference = 'Stop'
$scripts = Split-Path -Parent $PSScriptRoot
$root = Join-Path ([IO.Path]::GetTempPath()) ('customer-diagnostics-' + [guid]::NewGuid().ToString('N'))
$root = [IO.Path]::GetFullPath($root)
$null = New-Item -ItemType Directory -Path $root
$script:FixtureScriptDirectory = Join-Path $root 'kit/scripts'
$null = New-Item -ItemType Directory -Path $script:FixtureScriptDirectory -Force
$owned = Join-Path $root 'owned'
$null = New-Item -ItemType Directory -Path $owned
$passed = 0
$failed = 0
$script:LoginFixtureServer = $null

function Read-ScriptAst([string]$Path) {
  $tokens = $null; $parseErrors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
  if ($parseErrors.Count) { throw "Parse errors in ${Path}: $parseErrors" }
  return $ast
}

# Execute the actual filesystem boundary before the first key-generation function.
# OpenSSL discovery/invocation remains outside this block and is never executed.
$authorityAst = Read-ScriptAst (Join-Path $scripts 'generate-secret-authority-keys.ps1')
$statements = @($authorityAst.EndBlock.Statements)
$first = 0
while ($first -lt $statements.Count -and
    -not ($statements[$first] -is [Management.Automation.Language.AssignmentStatementAst] -and
      $statements[$first].Left.VariablePath.UserPath -eq 'resolvedOutput')) { $first++ }
$last = $first
while ($last -lt $statements.Count -and
    -not ($statements[$last] -is [Management.Automation.Language.FunctionDefinitionAst] -and
      $statements[$last].Name -eq 'New-Ed25519KeyPair')) { $last++ }
if ($first -ge $last -or $last -eq $statements.Count) { throw 'Cannot locate authority preparation boundary' }
$script:AuthorityInit = [ScriptBlock]::Create($authorityAst.ParamBlock.Extent.Text + "`n" +
  '$PSScriptRoot = $script:FixtureScriptDirectory' + "`n" +
  (($statements[$first..($last - 1)] | ForEach-Object { $_.Extent.Text }) -join "`n") + "`n" + '$resolvedOutput')

# Bind real CLI parameters and execute the actual serialized tenant request constructor.
$provisionAst = Read-ScriptAst (Join-Path $scripts 'provision.ps1')
$body = $provisionAst.Find({ param($node)
  $node -is [Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
    $node.Left.VariablePath.UserPath -eq 'tenantBody'
}, $true)
if (-not $body) { throw 'Cannot locate tenant request constructor' }
$script:ProvisionBody = [ScriptBlock]::Create($provisionAst.ParamBlock.Extent.Text + "`n" +
  $body.Extent.Text + "`n" + '$tenantBody | ConvertTo-Json -Depth 8 -Compress')

# Execute the real endpoint checks and final summary, with only transport/output stubbed.
$provisionText = $provisionAst.Extent.Text
$verificationStart = $provisionText.IndexOf('# --- Step 5:')
$summaryStart = $provisionText.IndexOf('# --- Step 6:')
$verificationStatements = @($provisionAst.EndBlock.Statements | Where-Object {
  $_.Extent.StartOffset -gt $verificationStart -and $_.Extent.StartOffset -lt $summaryStart
})
$summaryStatements = @($provisionAst.EndBlock.Statements | Where-Object {
  $_.Extent.StartOffset -gt $summaryStart -and $_ -isnot [Management.Automation.Language.ExitStatementAst]
})
if (-not $verificationStatements.Count -or -not $summaryStatements.Count) { throw 'Cannot locate provisioning verification/summary blocks' }
$fixtureBindings = @'
$platformUrl = 'https://platform.example.invalid'
$operatorToken = 'fixture-token'
$tenantId = 'fixture-tenant'
$tenantHost = 'owned.example.invalid'
$tenantGatewayUrl = 'https://owned.example.invalid'
$adminConsoleUrl = 'https://console.example.invalid'
function Invoke-Json { return $script:BoundEndpoints }
function Fail([string]$Message) { throw $Message }
function Write-Host { param([object]$Object, [object]$ForegroundColor) $script:ProvisionOutput.Add([string]$Object) }
'@
$script:ProvisionVerification = [ScriptBlock]::Create($provisionAst.ParamBlock.Extent.Text + "`n" + $fixtureBindings + "`n" +
  (($verificationStatements | ForEach-Object { $_.Extent.Text }) -join "`n"))
$script:ProvisionSummary = [ScriptBlock]::Create($provisionAst.ParamBlock.Extent.Text + "`n" + $fixtureBindings + "`n" +
  (($summaryStatements | ForEach-Object { $_.Extent.Text }) -join "`n"))

# Execute the actual login/callback block against a real isolated redirect server.
# The optional callback deliberately 404s, as in the headless customer topology.
$loginStart = $provisionText.IndexOf('# 3.3 Submit credentials')
$loginEnd = $provisionText.IndexOf('# 3.5 Exchange the code')
if ($loginStart -lt 0 -or $loginEnd -le $loginStart) { throw 'Cannot locate operator login block' }
$loginFunctions = @($provisionAst.EndBlock.Statements | Where-Object {
  $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $_.Name -in @('Get-FinalUri', 'Get-LocationHeader', 'Invoke-OperatorRedirect')
})
$script:ProvisionLogin = [ScriptBlock]::Create(@'
param([string]$FixtureUrl, [string]$FixtureUser = 'fixture')
$platformUrl = $FixtureUrl
$operatorEmail = $FixtureUser
$operatorPassword = 'fixture-password + unicode-' + [char]0xe9
$sessionId = 'fixture-session'
$tabId = 'fixture-tab'
$sessionCode = 'fixture-code-csrf'
$returnUrl = '/authorize/resume'
$opSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
$opSession.Cookies.Add([Uri]$platformUrl, [Net.Cookie]::new('fixture-csrf', 'fixture-cookie', '/'))
function Fail([string]$Message) { throw $Message }
'@ + "`n" + (($loginFunctions | ForEach-Object { $_.Extent.Text }) -join "`n") + "`n" +
  $provisionText.Substring($loginStart, $loginEnd - $loginStart) + "`n" +
  '[pscustomobject]@{ code = $authCode; cookies = $opSession.Cookies.GetCookieHeader([Uri]$platformUrl) }')

function Start-LoginFixture {
  $serverPath = Join-Path $root 'login-fixture.js'
  $readyPath = Join-Path $root 'login-fixture-port.txt'
  $script:LoginRequestsPath = Join-Path $root 'login-fixture-requests.jsonl'
  [IO.File]::WriteAllText($serverPath, @'
const http = require('http');
const fs = require('fs');
const [ready, requests] = process.argv.slice(2);
const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', chunk => { body += chunk; });
  req.on('end', () => {
    const path = new URL(req.url, 'http://127.0.0.1').pathname;
    const form = Object.fromEntries(new URLSearchParams(body));
    fs.appendFileSync(requests, JSON.stringify({method:req.method,path,cookie:req.headers.cookie || '',form}) + '\n');
    if (path === '/login' && req.method === 'POST') {
      if (form.username === 'http-failure') { res.writeHead(401); res.end('Unauthorized'); return; }
      if (form.username === 'not-redirect') { res.writeHead(200); res.end('Not authorized'); return; }
      if (form.username === 'missing-location') { res.writeHead(302); res.end(); return; }
      const location = form.username === 'invalid' ? '/onboarding/callback?error=invalid_credentials' :
        form.username === 'intermediate' ? '/authorize/resume' : '/onboarding/callback?code=fixture-auth-code&state=fixture-state';
      res.writeHead(302, {'Location':location,'Set-Cookie':'fixture-auth=authenticated; Path=/'});
      res.end(); return;
    }
    if (path === '/authorize/resume') {
      res.writeHead(302, {'Location':'/onboarding/callback?code=fixture-auth-code&state=fixture-state'});
      res.end(); return;
    }
    res.writeHead(404); res.end('Optional callback UI is absent');
  });
});
server.listen(0,'127.0.0.1',() => fs.writeFileSync(ready, String(server.address().port)));
'@, [Text.UTF8Encoding]::new($false))
  $nodePath = @(Get-Command node -CommandType Application)[0].Source
  $script:LoginFixtureServer = Start-Process -FilePath $nodePath `
    -ArgumentList @(('"' + $serverPath + '"'), ('"' + $readyPath + '"'), ('"' + $script:LoginRequestsPath + '"')) `
    -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $root 'fixture-stdout.txt') `
    -RedirectStandardError (Join-Path $root 'fixture-stderr.txt')
  $deadline = [DateTime]::UtcNow.AddSeconds(10)
  while (-not (Test-Path -LiteralPath $readyPath)) {
    if ($script:LoginFixtureServer.HasExited -or [DateTime]::UtcNow -ge $deadline) { throw 'Owned loopback fixture did not start' }
    Start-Sleep -Milliseconds 50
  }
  $script:LoginFixtureUrl = 'http://127.0.0.1:' + ([IO.File]::ReadAllText($readyPath)).Trim()
}

function Read-LoginRequests {
  if (-not (Test-Path -LiteralPath $script:LoginRequestsPath)) { return @() }
  return @(Get-Content -LiteralPath $script:LoginRequestsPath -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json })
}

function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([ScriptBlock]$Action, [string]$Pattern) {
  try { & $Action | Out-Null } catch {
    Assert-True ($_.Exception.Message -match $Pattern) "Unexpected rejection: $($_.Exception.Message)"
    return
  }
  throw 'Expected rejection'
}
function Test([string]$Name, [ScriptBlock]$Action) {
  try { & $Action; $script:passed++; Write-Host "PASS $Name" }
  catch { $script:failed++; Write-Host "FAIL ${Name}: $($_.Exception.Message)" }
}

try {
  Start-LoginFixture
  Test 'Login redirect code succeeds without fetching an absent optional callback UI' {
    $before = @(Read-LoginRequests).Count
    $actual = & $script:ProvisionLogin -FixtureUrl $script:LoginFixtureUrl
    $requests = @(Read-LoginRequests | Select-Object -Skip $before)
    Assert-True ($actual.code -eq 'fixture-auth-code') 'Successful login code was lost'
    Assert-True ($requests.Count -eq 1 -and $requests[0].path -eq '/login' -and $requests[0].method -eq 'POST') 'Optional callback was fetched'
    Assert-True ($requests[0].cookie -match 'fixture-csrf=fixture-cookie') 'CSRF session cookie was dropped'
    Assert-True ($actual.cookies -match 'fixture-auth=authenticated') 'Response session cookie was dropped'
    Assert-True ($requests[0].form.password -eq ('fixture-password + unicode-' + [char]0xe9) -and
      $requests[0].form.session_code -eq 'fixture-code-csrf' -and $requests[0].form.tab_id -eq 'fixture-tab') 'Credential/CSRF form encoding changed'
  }
  Test 'Intermediate authorization callback retains cookies and stops at final code Location' {
    $before = @(Read-LoginRequests).Count
    $actual = & $script:ProvisionLogin -FixtureUrl $script:LoginFixtureUrl -FixtureUser 'intermediate'
    $requests = @(Read-LoginRequests | Select-Object -Skip $before)
    Assert-True ($actual.code -eq 'fixture-auth-code') 'Intermediate callback code was lost'
    Assert-True ($requests.Count -eq 2 -and $requests[1].path -eq '/authorize/resume' -and $requests[1].method -eq 'GET') 'Intermediate callback flow changed'
    Assert-True ($requests[1].cookie -match 'fixture-auth=authenticated') 'Authenticated cookie was not retained on callback'
    Assert-True (@($requests | Where-Object { $_.path -eq '/onboarding/callback' }).Count -eq 0) 'Optional UI was fetched'
  }
  Test 'Invalid credentials redirect is rejected without fetching callback UI' {
    $before = @(Read-LoginRequests).Count
    Assert-Throws { & $script:ProvisionLogin -FixtureUrl $script:LoginFixtureUrl -FixtureUser 'invalid' } 'invalid credentials'
    Assert-True (@(Read-LoginRequests).Count -eq $before + 1) 'Rejected credential redirect was followed'
  }
  Test 'Real login HTTP failures remain failures' {
    Assert-Throws { & $script:ProvisionLogin -FixtureUrl $script:LoginFixtureUrl -FixtureUser 'http-failure' } 'Operator login failed.*401'
  }
  Test 'Missing redirect Location and nonredirect login responses remain failures' {
    Assert-Throws { & $script:ProvisionLogin -FixtureUrl $script:LoginFixtureUrl -FixtureUser 'missing-location' } 'Location'
    Assert-Throws { & $script:ProvisionLogin -FixtureUrl $script:LoginFixtureUrl -FixtureUser 'not-redirect' } 'redirect|authorization code'
  }
  Test 'External fresh destination creates authority directories within explicit owned root' {
    $target = Join-Path $owned 'fresh'
    $actual = & $script:AuthorityInit -OutputDirectory $target -ExternalOutputRoot $owned
    Assert-True ($actual -eq $target) 'Wrong resolved destination'
    foreach ($name in @('central', 'public', 'workload')) {
      Assert-True (Test-Path -LiteralPath (Join-Path $target $name) -PathType Container) "Missing $name"
    }
  }
  Test 'External nonempty destination is refused without deleting existing bytes' {
    $target = Join-Path $owned 'nonempty'; $null = New-Item -ItemType Directory -Path $target
    $sentinel = Join-Path $target 'sentinel.txt'; [IO.File]::WriteAllText($sentinel, 'owned bytes')
    Assert-Throws { & $script:AuthorityInit -OutputDirectory $target -ExternalOutputRoot $owned } 'fresh|exist'
    Assert-True ([IO.File]::ReadAllText($sentinel) -eq 'owned bytes') 'Existing bytes were changed'
  }
  Test 'External empty existing destination is refused rather than adopted' {
    $target = Join-Path $owned 'empty'; $null = New-Item -ItemType Directory -Path $target
    Assert-Throws { & $script:AuthorityInit -OutputDirectory $target -ExternalOutputRoot $owned } 'fresh|exist'
    Assert-True ((Get-ChildItem -LiteralPath $target -Force).Count -eq 0) 'Existing directory was populated'
  }
  Test 'External sibling-prefix escape is refused' {
    $target = Join-Path $root 'owned-other/out'
    Assert-Throws { & $script:AuthorityInit -OutputDirectory $target -ExternalOutputRoot $owned } 'contain'
    Assert-True (-not (Test-Path -LiteralPath $target)) 'Outside destination created'
  }
  Test 'External parent traversal and the owned root itself are refused' {
    Assert-Throws { & $script:AuthorityInit -OutputDirectory (Join-Path $owned '../outside') -ExternalOutputRoot $owned } 'contain'
    Assert-Throws { & $script:AuthorityInit -OutputDirectory $owned -ExternalOutputRoot $owned } 'contain'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'outside'))) 'Traversal destination created'
  }
  Test 'External relative destination is refused' {
    Assert-Throws { & $script:AuthorityInit -OutputDirectory 'relative-output' -ExternalOutputRoot $owned } 'absolute'
  }
  Test 'External relative root is refused' {
    Assert-Throws { & $script:AuthorityInit -OutputDirectory (Join-Path $owned 'relative-root') -ExternalOutputRoot 'owned' } 'absolute'
  }
  Test 'Explicit empty external root never falls back to deleting a customer window' {
    $target = Join-Path $root 'kit/compose/.secret-authority/empty-root'
    $null = New-Item -ItemType Directory -Path $target -Force
    $sentinel = Join-Path $target 'sentinel.txt'; [IO.File]::WriteAllText($sentinel, 'preserve')
    Assert-Throws { & $script:AuthorityInit -OutputDirectory $target -ExternalOutputRoot '' } 'absolute'
    Assert-True ([IO.File]::ReadAllText($sentinel) -eq 'preserve') 'Empty root caused ordinary deletion'
  }
  Test 'External root must already exist and cannot be a drive root' {
    Assert-Throws { & $script:AuthorityInit -OutputDirectory (Join-Path $root 'missing/out') -ExternalOutputRoot (Join-Path $root 'missing') } 'existing'
    Assert-Throws { & $script:AuthorityInit -OutputDirectory (Join-Path $owned 'drive-root') -ExternalOutputRoot ([IO.Path]::GetPathRoot($owned)) } 'root'
  }
  Test 'External reparse-point ancestor is refused before creating files' {
    $real = Join-Path $root 'real'; $null = New-Item -ItemType Directory -Path $real
    $alias = Join-Path $owned 'alias'
    $null = New-Item -ItemType Junction -Path $alias -Target $real
    Assert-Throws { & $script:AuthorityInit -OutputDirectory (Join-Path $alias 'out') -ExternalOutputRoot $owned } 'reparse'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $real 'out'))) 'Reparse target was written'
    Remove-Item -LiteralPath $alias -Force
  }
  Test 'External owned root cannot itself be a junction' {
    $real = Join-Path $root 'real-root'; $null = New-Item -ItemType Directory -Path $real
    $alias = Join-Path $root 'alias-root'
    $null = New-Item -ItemType Junction -Path $alias -Target $real
    Assert-Throws { & $script:AuthorityInit -OutputDirectory (Join-Path $alias 'out') -ExternalOutputRoot $alias } 'reparse'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $real 'out'))) 'Root junction target was written'
    Remove-Item -LiteralPath $alias -Force
  }
  Test 'Default customer mode remains confined and replaces its own previous output' {
    $target = Join-Path $root 'kit/compose/.secret-authority/default'
    $null = & $script:AuthorityInit -OutputDirectory $target
    $sentinel = Join-Path $target 'sentinel.txt'; [IO.File]::WriteAllText($sentinel, 'old own window')
    $null = & $script:AuthorityInit -OutputDirectory $target
    Assert-True (-not (Test-Path -LiteralPath $sentinel)) 'Ordinary rotation no longer replaces its own output'
    Assert-Throws { & $script:AuthorityInit -OutputDirectory (Join-Path $owned 'default-escape') } 'contain'
  }
  Test 'Default tenant request retains complete customer provisioning' {
    $request = (& $script:ProvisionBody -TenantName 'Owned Test' -TenantSlug 'owned-test') | ConvertFrom-Json
    Assert-True ($request.provisioning.issuer -eq $true -and $request.provisioning.verifier -eq $true -and
      $request.provisioning.keysAndDids -eq $true -and $request.provisioning.sampleData -eq $true) 'Default provisioning changed'
    Assert-True ($request.tenant.name -eq 'Owned Test' -and $request.tenant.slug -eq 'owned-test' -and
      $request.contacts.ownerAdmin.source -eq 'technical' -and $request.login.defaultAuthorizationServerRequired -eq $true) 'Default request fields changed'
  }
  Test 'Verifier-only CLI request excludes issuer and sample data while retaining keys and hosted AS' {
    $request = (& $script:ProvisionBody -TenantName 'Owned Test' -TenantSlug 'owned-test' -VerifierOnly) | ConvertFrom-Json
    Assert-True ($request.provisioning.issuer -eq $false -and $request.provisioning.verifier -eq $true -and
      $request.provisioning.keysAndDids -eq $true -and $request.provisioning.sampleData -eq $false) 'Verifier-only request is not exact'
    Assert-True ($request.login.enabled -eq $true -and $request.login.defaultAuthorizationServerRequired -eq $true) 'Hosted AS disabled'
  }
  Test 'Verifier-only actual endpoint verification accepts verifier and OAuth without issuer' {
    $script:ProvisionOutput = [Collections.Generic.List[string]]::new()
    $script:BoundEndpoints = @{ host = 'owned.example.invalid'; kinds = @('OID4VP_VERIFIER', 'OAUTH2_AUTHORIZATION_SERVER') }
    & $script:ProvisionVerification -VerifierOnly
  }
  Test 'Default actual endpoint verification still rejects missing issuer' {
    $script:ProvisionOutput = [Collections.Generic.List[string]]::new()
    $script:BoundEndpoints = @{ host = 'owned.example.invalid'; kinds = @('OID4VP_VERIFIER', 'OAUTH2_AUTHORIZATION_SERVER') }
    Assert-Throws { & $script:ProvisionVerification } 'OID4VCI_ISSUER'
  }
  Test 'Default actual endpoint verification retains all three required kinds' {
    $script:ProvisionOutput = [Collections.Generic.List[string]]::new()
    $script:BoundEndpoints = @{ host = 'owned.example.invalid'; kinds = @('OID4VCI_ISSUER', 'OID4VP_VERIFIER', 'OAUTH2_AUTHORIZATION_SERVER') }
    & $script:ProvisionVerification
  }
  Test 'Verifier-only still requires verifier and OAuth endpoint bindings' {
    $script:ProvisionOutput = [Collections.Generic.List[string]]::new()
    foreach ($kind in @('OID4VP_VERIFIER', 'OAUTH2_AUTHORIZATION_SERVER')) {
      $script:BoundEndpoints = @{ host = 'owned.example.invalid'; kinds = @('OID4VP_VERIFIER', 'OAUTH2_AUTHORIZATION_SERVER') | Where-Object { $_ -ne $kind } }
      Assert-Throws { & $script:ProvisionVerification -VerifierOnly } $kind
    }
  }
  Test 'Verifier-only summary does not advertise an unprovisioned issuer' {
    $script:ProvisionOutput = [Collections.Generic.List[string]]::new()
    & $script:ProvisionSummary -VerifierOnly
    $summary = $script:ProvisionOutput -join "`n"
    Assert-True ($summary -notmatch 'OID4VCI|openid-credential-issuer') 'Verifier-only summary advertised issuer metadata'
    Assert-True ($summary -match 'oauth-authorization-server' -and $summary -match 'did.json') 'Verifier-only summary lost OAuth/DID metadata'
  }
  Test 'Default summary still advertises issuer OAuth and DID metadata' {
    $script:ProvisionOutput = [Collections.Generic.List[string]]::new()
    & $script:ProvisionSummary
    $summary = $script:ProvisionOutput -join "`n"
    Assert-True ($summary -match 'openid-credential-issuer' -and $summary -match 'oauth-authorization-server' -and $summary -match 'did.json') 'Default metadata summary changed'
  }
} finally {
  if ($script:LoginFixtureServer -and -not $script:LoginFixtureServer.HasExited) {
    Stop-Process -Id $script:LoginFixtureServer.Id -Force
    $script:LoginFixtureServer.WaitForExit()
  }
  if (-not $root.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Refusing cleanup outside test temporary root'
  }
  Remove-Item -LiteralPath $root -Recurse -Force
}
Write-Host "Diagnostic helper tests: $passed passed, $failed failed"
if ($failed) { exit 1 }
