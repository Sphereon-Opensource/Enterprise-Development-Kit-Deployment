[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

$ErrorActionPreference = "Stop"
$scriptPath = Join-Path $PSScriptRoot "configure-webuild-trust-domain.mjs"
& node $scriptPath @Arguments
exit $LASTEXITCODE
