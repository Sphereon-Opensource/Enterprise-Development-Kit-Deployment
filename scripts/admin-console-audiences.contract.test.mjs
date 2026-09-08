import assert from 'node:assert/strict'
import {spawnSync} from 'node:child_process'
import {readFileSync} from 'node:fs'
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

function renderChart(topology = 'distributed') {
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
    '--set-string',
    `topology.mode=${topology}`,
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

for (const topology of ['distributed', 'monolith']) {
  test(`${topology} operator browser token remains audience-bound under the rendered configuration`, () => {
    const rendered = renderChart(topology)
    let clientConfiguration = rendered
    if (topology === 'monolith') {
      const overlay = rendered.split(/^---\s*$/mu).find(document =>
        /^kind: ConfigMap$/mu.test(document) && /name: .*monolith-runtime\s*$/mu.test(document))
      assert.ok(overlay, 'monolith runtime overlay is absent')
      // This overlay replaces application-container.yml, not the packaged application.yml.
      // The operator client is inherited from that base profile and must not be shadowed here.
      assert.doesNotMatch(overlay, /platform-operator-cli:/u)
      clientConfiguration = readFileSync(path.join(infraRoot, 'services/service-monolith/config/application.yml'), 'utf8')
    }
    const match = clientConfiguration.match(
      /platform-operator-cli:\s*[\s\S]*?default-access-token-audience:\s*"([^"]+)"/,
    )
    assert.ok(match, 'effective platform-operator-cli configuration has no default audience')
    assert.equal(match[1], 'enterprise-platform')
  })

  test(`${topology} tenant console uses the narrow platform bootstrap transport without operator credentials`, () => {
    const rendered = renderChart(topology)
    const tenantConsole = rendered.split(/^---\s*$/mu).find(document =>
      /^kind: Deployment$/mu.test(document) && /name: .*admin-console-tenant\s*$/mu.test(document))
    assert.ok(tenantConsole, 'tenant console Deployment is absent')
    assert.match(tenantConsole, /name: ADMIN_CONSOLE_MODE\s+value: "?TENANT"?\s/u)
    assert.match(tenantConsole, /name: ADMIN_CONSOLE_PLATFORM_BOOTSTRAP_BASE_URL\s+value: "http:\/\/[^/\s"]+:\d+\/api\/platform\/bootstrap\/v1"/u)
    assert.doesNotMatch(tenantConsole, /name: ADMIN_CONSOLE_PLATFORM_BASE_URL\s*$/mu)
    assert.doesNotMatch(tenantConsole, /name: ADMIN_CONSOLE_WORKLOAD_CLIENT_(?:ID|SECRET)\s*$/mu)
    assert.doesNotMatch(tenantConsole, /name: ADMIN_CONSOLE_PUBLIC_ORIGIN\s*$/mu)
  })
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

test('admin-console receives server-only runtime audience variables', () => {
  const rendered = renderChart()
  for (const [name, audience] of [
    ['ADMIN_CONSOLE_PLATFORM_AUDIENCE', 'enterprise-platform'],
    ['ADMIN_CONSOLE_TENANT_KMS_AUDIENCE', 'enterprise-tenant-kms'],
    ['ADMIN_CONSOLE_AUDIT_AUDIENCE', 'enterprise-platform'],
    ['ADMIN_CONSOLE_WALLET_ENTITLEMENT_AUDIENCE', 'enterprise-platform'],
    ['ADMIN_CONSOLE_THEME_AUDIENCE', 'enterprise-blob'],
    ['ADMIN_CONSOLE_TENANT_DID_AUDIENCE', 'enterprise-tenant-did'],
    ['ADMIN_CONSOLE_ISSUER_AUDIENCE', 'enterprise-issuer'],
    ['ADMIN_CONSOLE_VERIFIER_AUDIENCE', 'enterprise-verifier'],
  ]) {
    assert.match(
      rendered,
      new RegExp(`name: ${name}\\s+value: "${audience}"`),
      `${name} is missing its runtime audience`,
    )
  }
})
