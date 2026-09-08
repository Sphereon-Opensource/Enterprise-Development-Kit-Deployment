import assert from 'node:assert/strict'
import {spawnSync} from 'node:child_process'
import {fileURLToPath} from 'node:url'
import path from 'node:path'
import test from 'node:test'

const customerEdkRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const chart = path.join(customerEdkRoot, 'helm', 'edk-enterprise')
const repositoryRoot = path.resolve(customerEdkRoot, '..', '..')
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

test('identity-plane Services replace authority-bootstrap and publish not-ready addresses', () => {
  const rendered = renderChart()
  const prefix = 'topology-test-edk-enterprise'
  const identityName = `${prefix}-platform-identity`
  const identityService = namedDocument(rendered, 'Service', identityName)
  const platformService = namedDocument(rendered, 'Service', `${prefix}-platform`)
  const tenantKmsService = namedDocument(rendered, 'Service', `${prefix}-tenant-kms`)
  const platformDeployment = namedDocument(rendered, 'Deployment', `${prefix}-platform`)
  const tenantKmsDeployment = namedDocument(rendered, 'Deployment', `${prefix}-tenant-kms`)
  const tenantKmsIdentityName = `${prefix}-tenant-kms-identity`
  const tenantKmsIdentityService = namedDocument(rendered, 'Service', tenantKmsIdentityName)
  const platformConfig = namedDocument(rendered, 'ConfigMap', `${prefix}-platform-db-override`)
  const tenantKmsConfig = namedDocument(rendered, 'ConfigMap', `${prefix}-tenant-kms-config`)
  const issuerConfig = namedDocument(rendered, 'ConfigMap', `${prefix}-issuer-config`)

  assert.doesNotMatch(rendered, /authority-bootstrap/)
  assert.match(identityService, /^  publishNotReadyAddresses: true$/m)
  assert.match(identityService, /^    edk\.sphereon\.com\/readiness-path: \/health\/identity$/m)
  assert.match(identityService, /^    edk\.sphereon\.com\/platform-identity: "true"$/m)
  assert.match(identityService, /^    - name: grpc$/m)
  assert.match(identityService, /^    - name: rest$/m)

  assert.match(platformDeployment, /^        edk\.sphereon\.com\/platform-identity: "true"$/m)
  assert.match(platformDeployment, /readinessProbe:\s+httpGet:\s+path: \/ready/)
  for (const deployment of documents(rendered).filter((candidate) => /^kind: Deployment$/m.test(candidate) && candidate !== platformDeployment)) {
    assert.doesNotMatch(deployment, /edk\.sphereon\.com\/platform-identity/)
  }

  assert.match(platformService, /^    edk\.sphereon\.com\/readiness-path: \/ready$/m)
  assert.doesNotMatch(platformService, /publishNotReadyAddresses/)
  assert.doesNotMatch(platformService, /edk\.sphereon\.com\/platform-identity/)
  assert.match(platformService, /^    - name: rest$/m)
  assert.match(platformService, /^    - name: grpc$/m)

  assert.match(tenantKmsConfig, new RegExp(`grpc://${identityName}:`))
  assert.doesNotMatch(issuerConfig, new RegExp(`grpc://${identityName}:`))
  assert.match(issuerConfig, new RegExp(`grpc://${prefix}-platform:`))
  assert.match(tenantKmsDeployment, new RegExp(`/dev/tcp/${identityName}/`))
  assert.match(tenantKmsDeployment, /^        edk\.sphereon\.com\/tenant-kms-identity: "true"$/m)
  assert.match(tenantKmsDeployment, /readinessProbe:\s+httpGet:\s+path: \/ready/)
  assert.doesNotMatch(tenantKmsService, /publishNotReadyAddresses/)
  assert.match(tenantKmsIdentityService, /^  publishNotReadyAddresses: true$/m)
  assert.match(tenantKmsIdentityService, /^    edk\.sphereon\.com\/readiness-path: \/health\/identity$/m)
  assert.match(tenantKmsIdentityService, /^    edk\.sphereon\.com\/tenant-kms-identity: "true"$/m)
  assert.match(tenantKmsIdentityService, /^    - name: grpc$/m)
  assert.doesNotMatch(tenantKmsIdentityService, /^    - name: (?:http|rest)$/m)
  assert.match(platformDeployment, new RegExp(`TENANT_KMS_AUTHORITY_BOOTSTRAP_HOST[\\s\\S]*${tenantKmsIdentityName}`))
  assert.equal((platformConfig.match(new RegExp(`grpc://${tenantKmsIdentityName}:`, 'g')) ?? []).length, 4)

  const tenantKmsIdentityDeployment = tenantKmsDeployment
  assert.match(
    tenantKmsIdentityDeployment,
    new RegExp(`name: SERVER_SERVICE_IDENTITY_TOKEN_ENDPOINT\\s+value: "http://${identityName}:\\d+/token"`),
    'tenant-kms must mint its workload identity against the platform identity service',
  )
  assert.match(
    tenantKmsIdentityDeployment,
    new RegExp(`name: SERVER_REST_AUTH_PLATFORM_JWKS_URI\\s+value: "http://${identityName}:\\d+/\\.well-known/jwks\\.json"`),
    'tenant-kms must fetch the platform JWKS from the platform identity service',
  )

  for (const satellite of ['did', 'tenant-as', 'issuer', 'verifier']) {
    const satelliteDeployment = namedDocument(rendered, 'Deployment', `${prefix}-${satellite}`)
    assert.match(
      satelliteDeployment,
      new RegExp(`name: SERVER_SERVICE_IDENTITY_TOKEN_ENDPOINT\\s+value: "http://${prefix}-platform:\\d+/token"`),
      `${satellite} must mint its workload identity against the serving platform service`,
    )
    assert.match(
      satelliteDeployment,
      new RegExp(`name: SERVER_REST_AUTH_PLATFORM_JWKS_URI\\s+value: "http://${prefix}-platform:\\d+/\\.well-known/jwks\\.json"`),
      `${satellite} must fetch the platform JWKS from the serving platform service`,
    )
    assert.doesNotMatch(
      satelliteDeployment,
      new RegExp(`name: SERVER_REST_AUTH_PLATFORM_ISSUER\\s+value: "http://${prefix}-platform`),
      `${satellite} must keep the public platform issuer as its token trust anchor`,
    )
  }

  for (const route of documents(rendered).filter((candidate) => /^kind: HTTPRoute$/m.test(candidate))) {
    assert.doesNotMatch(route, /(?:platform|tenant-kms)-(?:authority-bootstrap|identity)/)
  }
})
