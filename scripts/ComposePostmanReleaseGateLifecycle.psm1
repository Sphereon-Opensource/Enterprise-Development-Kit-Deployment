Set-StrictMode -Version Latest

function New-ComposeGateLifecycle {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('owned-new', 'owned-reset', 'adopted')]
    [string]$Mode,
    [Parameter(Mandatory = $true)]
    [bool]$OwnsProject
  )
  if ($Mode -eq 'adopted' -and $OwnsProject) {
    throw 'An adopted Compose project can never be gate-owned.'
  }
  if ($Mode -ne 'adopted' -and -not $OwnsProject) {
    throw "Compose lifecycle mode '$Mode' must be gate-owned."
  }
  return [pscustomobject]@{
    Mode = $Mode
    OwnsProject = $OwnsProject
    MutationAttempted = $false
  }
}

function Start-ComposeGateMutation {
  [CmdletBinding()]
  param([Parameter(Mandatory = $true)][psobject]$Lifecycle)
  $Lifecycle.MutationAttempted = $true
  return $Lifecycle
}

function Get-ComposeGateTeardownAction {
  [CmdletBinding()]
  param(
    [psobject]$Lifecycle,
    [Parameter(Mandatory = $true)][bool]$KeepUp
  )
  if ($null -eq $Lifecycle -or -not [bool]$Lifecycle.MutationAttempted) {
    return 'not-started'
  }
  if ($KeepUp) { return 'retained-by-request' }
  if ([bool]$Lifecycle.OwnsProject) { return 'down' }
  if ([string]$Lifecycle.Mode -eq 'adopted') { return 'adopted-retained' }
  throw "Unsupported Compose lifecycle state '$($Lifecycle.Mode)'."
}

Export-ModuleMember -Function New-ComposeGateLifecycle, Start-ComposeGateMutation, Get-ComposeGateTeardownAction
