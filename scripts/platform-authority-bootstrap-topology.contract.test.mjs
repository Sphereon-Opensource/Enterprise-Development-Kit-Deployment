import assert from 'node:assert/strict'
import {spawnSync} from 'node:child_process'
import {fileURLToPath} from 'node:url'
import path from 'node:path'
import test from 'node:test'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..')
const chart = path.join(repositoryRoot, 'customer', 'edk', 'helm', 'edk-enterprise')
const baseValues = path.join(repositoryRoot, 'deploy', 'edk', 'e2e', 'helm', 'values.yaml')
const upgradeValues = path.join(
  repositoryRoot,
  'deploy',
  'edk',
  'e2e',
  'build',
  'reports',
  'helm-upgrade',
  '20260802T085826Z',
  'upgrade-runtime-values.yaml',
)

function renderChart() {
  const result = spawnSync('helm', ['template', 'topology-test', chart, '-f', baseValues, '-f', upgradeValues], {
    cwd: repositoryRoot,
    encoding: 'utf8',
  })
  assert.equal(result.status, 0, `helm template failed:\n${result.stderr || result.stdout}`)
  return result.stdout
}

function documents(rendered) {
  return rendered.split(/^---\s*$/m).map((document) => document.trim()).filter(Boolean)
}

function namedDocument(rendered, kind, name) {
  const document = documents(rendered).find((candidate) =>
    new RegExp(`^kind: ${kind}$`, 'm').test(candidate) &&
    new RegExp(`^  name: ${name}$`, 'm').test(candidate),
  )
  assert.ok(document, `rendered chart is missing ${kind} ${name}`)
  return document
}

test('rolling-upgrade authorities use RC3-only internal gRPC topologies', () => {
  const rendered = renderChart()
  const prefix = 'topology-test-edk-enterprise'
  const bootstrapName = `${prefix}-platform-authority-bootstrap`
  const bootstrapService = namedDocument(rendered, 'Service', bootstrapName)
  const platformService = namedDocument(rendered, 'Service', `${prefix}-platform`)
  const platformDeployment = namedDocument(rendered, 'Deployment', `${prefix}-platform`)
  const tenantKmsDeployment = namedDocument(rendered, 'Deployment', `${prefix}-tenant-kms`)
  const tenantKmsBootstrapName = `${prefix}-tenant-kms-authority-bootstrap`
  const tenantKmsBootstrapService = namedDocument(rendered, 'Service', tenantKmsBootstrapName)
  const platformConfig = namedDocument(rendered, 'ConfigMap', `${prefix}-platform-db-override`)
  const tenantKmsConfig = namedDocument(rendered, 'ConfigMap', `${prefix}-tenant-kms-config`)

  assert.match(bootstrapService, /^  publishNotReadyAddresses: true$/m)
  assert.match(bootstrapService, /^    edk\.sphereon\.com\/platform-authority-bootstrap: "true"$/m)
  assert.match(bootstrapService, /^    - name: grpc$/m)
  // The bootstrap Service also carries REST: satellites mint their workload identity and fetch the
  // platform JWKS while the platform is deliberately unready during its boot ceremony.
  assert.match(bootstrapService, /^    - name: rest$/m)

  assert.match(platformDeployment, /^        edk\.sphereon\.com\/platform-authority-bootstrap: "true"$/m)
  for (const deployment of documents(rendered).filter((candidate) => /^kind: Deployment$/m.test(candidate) && candidate !== platformDeployment)) {
    assert.doesNotMatch(deployment, /edk\.sphereon\.com\/platform-authority-bootstrap/)
  }

  assert.doesNotMatch(platformService, /publishNotReadyAddresses/)
  assert.doesNotMatch(platformService, /edk\.sphereon\.com\/platform-authority-bootstrap/)
  assert.match(platformService, /^    - name: rest$/m)
  assert.match(platformService, /^    - name: grpc$/m)

  assert.match(tenantKmsConfig, new RegExp(`grpc://${bootstrapName}:`))
  assert.match(tenantKmsDeployment, new RegExp(`/dev/tcp/${bootstrapName}/`))
  assert.match(tenantKmsDeployment, /^        edk\.sphereon\.com\/tenant-kms-authority-bootstrap: "true"$/m)
  assert.match(tenantKmsBootstrapService, /^  publishNotReadyAddresses: true$/m)
  assert.match(tenantKmsBootstrapService, /^    edk\.sphereon\.com\/tenant-kms-authority-bootstrap: "true"$/m)
  assert.match(tenantKmsBootstrapService, /^    - name: grpc$/m)
  assert.doesNotMatch(tenantKmsBootstrapService, /^    - name: (?:http|rest)$/m)
  assert.match(platformDeployment, new RegExp(`TENANT_KMS_AUTHORITY_BOOTSTRAP_HOST[\\s\\S]*${tenantKmsBootstrapName}`))
  assert.equal((platformConfig.match(new RegExp(`grpc://${tenantKmsBootstrapName}:`, 'g')) ?? []).length, 4)

  for (const satellite of ['tenant-kms', 'did', 'tenant-as', 'issuer', 'verifier']) {
    const satelliteDeployment = namedDocument(rendered, 'Deployment', `${prefix}-${satellite}`)
    assert.match(
      satelliteDeployment,
      new RegExp(`name: SERVER_SERVICE_IDENTITY_TOKEN_ENDPOINT\\s+value: "http://${bootstrapName}:\\d+/token"`),
      `${satellite} must mint its workload identity against the platform authority bootstrap service`,
    )
    assert.match(
      satelliteDeployment,
      new RegExp(`name: SERVER_REST_AUTH_PLATFORM_JWKS_URI\\s+value: "http://${bootstrapName}:\\d+/\\.well-known/jwks\\.json"`),
      `${satellite} must fetch the platform JWKS from the authority bootstrap service`,
    )
    assert.doesNotMatch(
      satelliteDeployment,
      new RegExp(`name: SERVER_REST_AUTH_PLATFORM_ISSUER\\s+value: "http://${prefix}-platform`),
      `${satellite} must keep the public platform issuer as its token trust anchor`,
    )
  }

  for (const route of documents(rendered).filter((candidate) => /^kind: HTTPRoute$/m.test(candidate))) {
    assert.doesNotMatch(route, /(?:platform|tenant-kms)-authority-bootstrap/)
  }
})
