# Exercises real destination preparation and request construction without OpenSSL or HTTP.
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
} finally {
  if (-not $root.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Refusing cleanup outside test temporary root'
  }
  Remove-Item -LiteralPath $root -Recurse -Force
}
Write-Host "Diagnostic helper tests: $passed passed, $failed failed"
if ($failed) { exit 1 }
