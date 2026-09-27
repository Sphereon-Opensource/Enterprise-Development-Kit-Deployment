import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import test from 'node:test'

const source = readFileSync(new URL('./upgrade-compose.ps1', import.meta.url), 'utf8')
const functionMatch = source.match(/^function Get-ReleaseNumber\([^\n]*\) \{[\s\S]*?^\}/m)
assert.ok(functionMatch, 'expected to find the Get-ReleaseNumber function block')

const pwshCheck = spawnSync('pwsh', ['-NoProfile', '-NonInteractive', '-Command', '$PSVersionTable.PSVersion.ToString()'], {
  encoding: 'utf8',
})
const pwshUnavailable = pwshCheck.error?.code === 'ENOENT' || pwshCheck.error?.code === 'EACCES'
const pwshSkipReason = pwshCheck.error?.code === 'EACCES'
  ? 'pwsh is on PATH but its executable is inaccessible; PowerShell contract cannot run.'
  : 'pwsh is not on PATH; PowerShell contract cannot run.'
const functionText = functionMatch[0]
const command = "Invoke-Expression $env:RELEASE_NUMBER_FUNCTION; Get-ReleaseNumber -Tag $env:RELEASE_TAG"

test('Get-ReleaseNumber ranks supported release tags and rejects unknown tags', {
  skip: pwshUnavailable ? pwshSkipReason : false,
}, () => {
  const cases = [
    ['0.25.0-RC1', 1],
    ['0.25.0-RC2', 2],
    ['0.25.0-RC3', 3],
    ['0.25.0-RC4-20260831-4', 4],
    ['0.25.0-RC5', 5],
    ['0.25.0', 10],
    ['0.25.0-20261001-1', 10],
    ['0.25.0-RC30', 0],
    ['0.25.0-SNAPSHOT', 0],
    ['', 0],
  ]

  for (const [tag, expected] of cases) {
    const result = spawnSync('pwsh', ['-NoProfile', '-NonInteractive', '-Command', command], {
      encoding: 'utf8',
      env: {
        ...process.env,
        RELEASE_NUMBER_FUNCTION: functionText,
        RELEASE_TAG: tag,
      },
    })
    assert.equal(result.error, undefined, `pwsh failed to start for tag ${JSON.stringify(tag)}`)
    assert.equal(result.status, 0, `pwsh exited unsuccessfully for tag ${JSON.stringify(tag)}: ${result.stderr}`)
    assert.equal(Number(result.stdout.trim()), expected, `unexpected rank for tag ${JSON.stringify(tag)}`)
  }
})
