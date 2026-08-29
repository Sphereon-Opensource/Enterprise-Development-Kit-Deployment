import assert from 'node:assert/strict'
import {spawnSync} from 'node:child_process'
import {fileURLToPath} from 'node:url'
import path from 'node:path'
import test from 'node:test'

const customerEdkRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const chart = path.join(customerEdkRoot, 'helm', 'edk-enterprise')
const infraRoot = process.env.IG5_INFRA_ROOT
  ?? path.resolve(customerEdkRoot, '..', 'service-identity-hardening')
const values = path.join(infraRoot, 'deploy', 'edk', 'e2e', 'helm', 'values.yaml')
const secretRoles = [
  'platform',
  'tenant-kms',
  'tenant-as',
  'did',
  'blob',
  'issuer',
  'verifier',
  'wallet-unit',
  'wallet-interaction',
]

function renderChart() {
  const args = [
    'template',
    'ig5-test',
    chart,
    '-f',
    values,
    '--set-string',
    'global.platformBaseDomain=helm-e2e.nk.sphereon.com',
    '--set-string',
    'platform.externalBaseUrl=https://platform.helm-e2e.nk.sphereon.com',
    '--set-string',
    'platform.bootstrap.issuer=https://platform.helm-e2e.nk.sphereon.com',
  ]
  for (const role of secretRoles) {
    args.push('--set-string', `secretAuthority.existingSecrets.${role}=ig5-${role}`)
  }
  const result = spawnSync('helm', args, {
    cwd: infraRoot,
    encoding: 'utf8',
  })
  assert.equal(result.status, 0, `helm template failed:\n${result.stderr || result.stdout}`)
  return result.stdout
}

test('operator token exchange allowlist follows admin-console peer audiences', () => {
  const rendered = renderChart()
  const match = rendered.match(
    /platform-operator-cli:\s*[\s\S]*?allowed-access-token-audiences:\s*"([^"]+)"/,
  )
  assert.ok(match, 'rendered platform-operator-cli has no audience allowlist')

  const audiences = match[1].split(',')
  for (const audience of [
    'enterprise-tenant-did',
    'enterprise-blob',
    'enterprise-tenant-kms',
    'enterprise-issuer',
    'enterprise-verifier',
  ]) {
    assert.ok(audiences.includes(audience), `operator allowlist is missing ${audience}`)
  }
  assert.ok(!audiences.includes('enterprise-platform'), 'operator default audience must not be duplicated')
})
