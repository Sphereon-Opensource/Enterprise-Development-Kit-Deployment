#!/usr/bin/env node

import assert from 'node:assert/strict'
import {createHash} from 'node:crypto'
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs'
import {tmpdir} from 'node:os'
import {dirname, join, resolve} from 'node:path'
import {spawnSync} from 'node:child_process'
import {fileURLToPath} from 'node:url'
import {
  decideProjectDisposition,
  finalizeEvidence,
  redactSensitiveText,
  validateJunitText,
} from './compose-postman-release-gate-support.mjs'
import {
  findCanaryMatches,
  requireStableCanary,
  secretVariants,
} from './assert-plaintext-canary-absent.mjs'
import {
  authenticateExactOperator,
  classifySetupStatus,
} from './prepare-compose-postman-setup.mjs'

const scriptDir = dirname(fileURLToPath(import.meta.url))
const customerRoot = resolve(scriptDir, '..')
const repoRoot = resolve(customerRoot, '..', '..')
const wrapperPath = join(scriptDir, 'run-compose-postman-release-gate.ps1')
const setupPath = join(scriptDir, 'prepare-compose-postman-setup.mjs')
const scannerPath = join(scriptDir, 'assert-plaintext-canary-absent.mjs')
const supportPath = join(scriptDir, 'compose-postman-release-gate-support.mjs')
const lifecycleModulePath = join(scriptDir, 'ComposePostmanReleaseGateLifecycle.psm1')
const docsPath = join(customerRoot, 'docs', 'compose-postman-release-gate.md')
const readmePath = join(customerRoot, 'README.md')
const collectionPath = join(customerRoot, 'postman', 'EDK-Enterprise-Deployment.postman_collection.json')
const composePath = join(customerRoot, 'compose', 'docker-compose.yml')

const wrapper = readFileSync(wrapperPath, 'utf8')
const setup = readFileSync(setupPath, 'utf8')
const docs = readFileSync(docsPath, 'utf8')
const readme = readFileSync(readmePath, 'utf8')
const compose = readFileSync(composePath, 'utf8')
const collection = JSON.parse(readFileSync(collectionPath, 'utf8'))
const powershell = process.platform === 'win32'
  ? join(process.env.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
  : 'pwsh'

function requestCount(items) {
  return (items ?? []).reduce(
    (count, item) => count + (item.request ? 1 : 0) + requestCount(item.item),
    0,
  )
}

function requests(items) {
  return (items ?? []).flatMap((item) => [
    ...(item.request ? [item] : []),
    ...requests(item.item),
  ])
}

function writeEnvironment(path, overrides = {}) {
  const values = {
    baseDomain: 'saas.localtest.me',
    tenantSlug: 'acme',
    tenantName: 'Acme',
    operatorEmail: 'operator@example.com',
    operatorPassword: 'operator-password-value',
    tenantOwnerPassword: 'tenant-owner-password-value',
    tenantOwnerCodeVerifier: 'tenant-owner-verifier-value',
    idpClientSecret: 'StableCanary_0123456789',
    ...overrides,
  }
  writeFileSync(path, `${JSON.stringify({
    values: Object.entries(values).map(([key, value]) => ({key, value, enabled: true})),
  }, null, 2)}\n`, 'utf8')
}

assert.equal(requestCount(collection.item), 95, 'shipped customer collection must contain 95 requests')
const collectionRequests = requests(collection.item)
const requestByName = new Map(collectionRequests.map((item) => [item.name, item]))
const kmsLifecycleContract = [
  ['04 Create disposable SOFTWARE KMS resource', 'POST', '{{tenantPlatformConfigApiBaseUrl}}/tenants/{{tenantId}}/kms/resources'],
  ['05 Read SOFTWARE KMS credential status', 'GET', '{{tenantPlatformConfigApiBaseUrl}}/tenants/{{tenantId}}/kms/resources/{{kmsLifecycleResourceHandle}}/credentials/software-keystore'],
  ['06 Attach SOFTWARE KMS credential', 'PUT', '{{tenantPlatformConfigApiBaseUrl}}/tenants/{{tenantId}}/kms/resources/{{kmsLifecycleResourceHandle}}/credentials/software-keystore'],
  ['07 Validate disposable SOFTWARE KMS resource', 'POST', '{{tenantPlatformConfigApiBaseUrl}}/tenants/{{tenantId}}/kms/resources/{{kmsLifecycleResourceHandle}}:validate'],
  ['08 Rotate SOFTWARE KMS credential', 'POST', '{{tenantPlatformConfigApiBaseUrl}}/tenants/{{tenantId}}/kms/resources/{{kmsLifecycleResourceHandle}}:rotate'],
  ['09 Detach disposable SOFTWARE KMS resource', 'POST', '{{tenantPlatformConfigApiBaseUrl}}/tenants/{{tenantId}}/kms/resources/{{kmsLifecycleResourceHandle}}:detach'],
  ['10 Retire disposable SOFTWARE KMS resource', 'POST', '{{tenantPlatformConfigApiBaseUrl}}/tenants/{{tenantId}}/kms/resources/{{kmsLifecycleResourceHandle}}:retire'],
]
for (const [name, method, url] of kmsLifecycleContract) {
  const item = requestByName.get(name)
  assert.ok(item, `customer KMS lifecycle request '${name}' must exist`)
  assert.equal(item.request.method, method, `${name} method`)
  assert.equal(item.request.url, url, `${name} path`)
}
const lifecycleItems = kmsLifecycleContract.map(([name]) => requestByName.get(name))
const lifecycleSource = JSON.stringify(lifecycleItems)
assert.match(
  requestByName.get('04 Create disposable SOFTWARE KMS resource').request.body.raw,
  /"kind": "SOFTWARE"[\s\S]*"storageMode": "MEMORY"/u,
  'customer lifecycle must create its own MEMORY-backed SOFTWARE resource',
)
for (const name of [
  '06 Attach SOFTWARE KMS credential',
  '08 Rotate SOFTWARE KMS credential',
  '09 Detach disposable SOFTWARE KMS resource',
  '10 Retire disposable SOFTWARE KMS resource',
]) {
  assert.ok(
    requestByName.get(name).request.body.raw.includes('{{kmsLifecycleResourceVersion}}'),
    `${name} must use the version captured from the preceding response`,
  )
}
for (const invariant of [
  "pm.collectionVariables.set('kmsLifecycleResourceHandle', j.handle)",
  "pm.collectionVariables.set('kmsLifecycleResourceVersion', String(j.resourceVersion))",
  "pm.collectionVariables.set('kmsLifecycleCredentialSecretRef', j.credentialSecretRef)",
  "pm.collectionVariables.unset('kmsLifecycleCredential')",
  "pm.expect(j.state, 'resource state').to.eql('CONFIGURED')",
  "pm.expect(j.state, 'resource state').to.eql('DETACHED')",
  "pm.expect(j.state, 'resource state').to.eql('RETIRED')",
]) {
  assert.ok(lifecycleSource.includes(invariant), `customer KMS lifecycle must retain '${invariant}'`)
}
assert.ok(lifecycleSource.includes("pm.variables.replaceIn('{{$randomUUID}}')"), 'customer KMS lifecycle must generate transient credentials and labels')
assert.ok(!/krh_[A-Za-z0-9_-]{20,}/u.test(lifecycleSource), 'customer KMS lifecycle must never hardcode an opaque resource handle')
assert.ok(!lifecycleSource.includes('/reference'), 'SOFTWARE lifecycle must not call the cloud-only change-reference route')
const tenantOriginContractItems = [
  '01 Register tenant',
  '05 List tenant gateway endpoint bindings',
  '06 Resolve tenant runtime service discovery',
]
for (const name of tenantOriginContractItems) {
  const source = JSON.stringify(requestByName.get(name)?.event ?? [])
  assert.ok(
    source.includes("const expectedTenantOrigin = 'https://' + pm.variables.get('tenantSlug') + '.' + pm.variables.get('baseDomain');"),
    `${name} must derive the exact HTTPS default-port tenant origin`,
  )
  assert.ok(
    source.includes('to.eql(expectedTenantOrigin)'),
    `${name} must reject Localtest, internal, HTTP, and explicit-port origins`,
  )
}
const expectedImages = [
  'enterprise-platform',
  'enterprise-tenant-kms',
  'enterprise-did',
  'enterprise-tenant-as',
  'enterprise-issuer',
  'enterprise-verifier',
  'admin-console',
]
const composeReleaseImages = [...new Set(
  [...compose.matchAll(/image:\s+nexus\.sphereon\.com\/edk-docker\/([^:$]+):\$\{EDK_TAG/gu)]
    .map((match) => match[1]),
)].sort()
assert.deepEqual(composeReleaseImages, [...expectedImages].sort(), 'customer Compose must use exactly seven release images')

for (const sourceInvariant of [
  "'docker-compose.yml'",
  "'docker-compose.gateway.yml'",
  'verify-enterprise-image-set.mjs',
  'compose-postman-release-gate-support.mjs',
  "'--pull', 'never'",
  "'E2E finished:\\s+95 requests captured,\\s+exit code 0\\.'",
  "'pg_dump --schema-only --no-owner --no-privileges",
  "'scan-producer'",
  'finalize-evidence',
  "'evidence-manifest.sha256'",
  'Assert-BehindEdgeMergedCompose',
  "'config', '--format', 'json'",
  "host_ip -ne '127.0.0.1'",
]) {
  assert.ok(wrapper.includes(sourceInvariant), `wrapper must retain '${sourceInvariant}'`)
}
assert.ok(!wrapper.includes("'--skip-snapshots'") && !wrapper.includes("'--update'"), 'release gate must enforce snapshot drift')
assert.ok(setup.includes('/api/platform/setup/v1/license/import/preview'), 'setup must preview the protected bundle')
assert.ok(setup.includes('/api/platform/setup/v1/bootstrap'), 'setup must use the product bootstrap API')
assert.ok(docs.includes('-ResetVolumes') && docs.includes('-DryRun'), 'docs must cover destructive authorization and static validation')
assert.ok(docs.includes('95-request') && docs.includes('exactly 95 requests'), 'docs must retain the exact customer collection count')
assert.ok(readme.includes('docs/compose-postman-release-gate.md'), 'README must route operators to the gate')

// A stopped project still owns its labeled networks and volumes and cannot be
// mistaken for a new gate-owned project.
const stoppedInventory = {containers: [], networks: ['project_default'], volumes: ['project_db']}
assert.throws(
  () => decideProjectDisposition(stoppedInventory, {useExisting: false, reset: false}),
  /already owns/u,
)
const adopted = decideProjectDisposition(stoppedInventory, {useExisting: true, reset: false})
assert.equal(adopted.mode, 'adopted')
assert.equal(adopted.ownsProject, false)
assert.throws(
  () => decideProjectDisposition({containers: [], networks: [], volumes: []}, {useExisting: true, reset: false}),
  /no existing/u,
)
const partialUpDisposition = decideProjectDisposition(
  {containers: [], networks: [], volumes: []},
  {useExisting: false, reset: false},
)
assert.deepEqual(
  {mode: partialUpDisposition.mode, ownsProject: partialUpDisposition.ownsProject},
  {mode: 'owned-new', ownsProject: true},
  'ownership must be established before a clean project attempts compose up',
)

// Canary input is encoding-stable, while the scanner still recognizes escaped
// legacy representations so quoted/backslashed values cannot silently evade it.
requireStableCanary('StableCanary_0123456789')
assert.throws(() => requireStableCanary('unstable"canary-value'), /encoding-stable/u)
const legacyCanary = 'legacy"canary\\value'
const escapedLegacy = JSON.stringify(legacyCanary)
assert.ok(findCanaryMatches(escapedLegacy, legacyCanary).length > 0)
assert.ok(secretVariants(legacyCanary).length >= 2)

const testRoot = mkdtempSync(join(tmpdir(), 'edk-customer-gate-contract-'))
try {
  const environmentPath = join(testRoot, 'environment.json')
  writeEnvironment(environmentPath)
  const lifecycleProbePath = join(testRoot, 'lifecycle-probe.ps1')
  writeFileSync(lifecycleProbePath, `
param([string]$ModulePath)
Import-Module -Name $ModulePath -Force
$owned = New-ComposeGateLifecycle -Mode owned-new -OwnsProject $true
$owned = Start-ComposeGateMutation -Lifecycle $owned
$adopted = New-ComposeGateLifecycle -Mode adopted -OwnsProject $false
$adopted = Start-ComposeGateMutation -Lifecycle $adopted
[ordered]@{
  partialUpAction = Get-ComposeGateTeardownAction -Lifecycle $owned -KeepUp $false
  adoptedAction = Get-ComposeGateTeardownAction -Lifecycle $adopted -KeepUp $false
} | ConvertTo-Json -Compress
`, 'utf8')
  const lifecycleProbe = spawnSync(powershell, [
    '-NoLogo',
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy', 'Bypass',
    '-File', lifecycleProbePath,
    '-ModulePath', lifecycleModulePath,
  ], {encoding: 'utf8'})
  assert.equal(lifecycleProbe.status, 0, lifecycleProbe.stderr)
  const lifecycleResult = JSON.parse(lifecycleProbe.stdout.trim())
  assert.equal(lifecycleResult.partialUpAction, 'down', 'mock partial up must plan owned-project cleanup')
  assert.equal(lifecycleResult.adoptedAction, 'adopted-retained', 'adopted project must never become cleanup-owned')

  const canary = 'StableCanary_0123456789'
  const cleanScan = spawnSync(process.execPath, [
    scannerPath,
    '--environment', environmentPath,
    '--canary-key', 'idpClientSecret',
    '--label', 'contract-clean',
  ], {input: 'safe evidence\n', encoding: 'utf8'})
  assert.equal(cleanScan.status, 0, cleanScan.stderr)
  const leakingScan = spawnSync(process.execPath, [
    scannerPath,
    '--environment', environmentPath,
    '--canary-key', 'idpClientSecret',
    '--label', 'contract-leak',
  ], {input: `unsafe ${canary}\n`, encoding: 'utf8'})
  assert.notEqual(leakingScan.status, 0, 'scanner must fail for the submitted canary')
  const emptyScan = spawnSync(process.execPath, [
    scannerPath,
    '--environment', environmentPath,
    '--canary-key', 'idpClientSecret',
    '--label', 'contract-empty',
  ], {input: '', encoding: 'utf8'})
  assert.notEqual(emptyScan.status, 0, 'scanner must reject empty producer input')

  // Producer and scanner statuses are independent: partial non-empty output
  // followed by a producer failure must fail even when the scanner succeeds.
  const producerPath = join(testRoot, 'partial-producer.mjs')
  writeFileSync(producerPath, "process.stdout.write('partial safe dump\\n'); process.exit(9)\n", 'utf8')
  const producerEvidence = join(testRoot, 'producer-evidence.jsonl')
  const partialProducer = spawnSync(process.execPath, [
    supportPath,
    'scan-producer',
    '--environment', environmentPath,
    '--canary-key', 'idpClientSecret',
    '--scanner', scannerPath,
    '--label', 'partial-db',
    '--evidence', producerEvidence,
    '--',
    process.execPath,
    producerPath,
  ], {encoding: 'utf8'})
  assert.notEqual(partialProducer.status, 0, 'partial producer failure must not be masked by scanner success')
  const producerResult = JSON.parse(readFileSync(producerEvidence, 'utf8').trim())
  assert.equal(producerResult.producerExitCode, 9)
  assert.equal(producerResult.scannerExitCode, 0)
  assert.ok(!readFileSync(producerEvidence, 'utf8').includes('partial safe dump'), 'data dump must not be retained')

  const validJunit =
    '<?xml version="1.0"?>\n' +
    '<testsuites tests="2" failures="0" errors="0">' +
    '<testsuite name="gate" tests="2" failures="0" errors="0">' +
    '<testcase name="one"/><testcase name="two"/></testsuite></testsuites>'
  assert.deepEqual(validateJunitText(validJunit), {
    tests: 2,
    failures: 0,
    errors: 0,
    suites: 1,
    testcases: 2,
  })
  for (const malformed of [
    '<testsuites failures="0" errors="0"></testsuites>',
    '<testsuites tests="0" failures="0" errors="0"></testsuites>',
    '<testsuites tests="2" failures="0" errors="0"><testsuite tests="1" failures="0" errors="0"><testcase/></testsuite></testsuites>',
  ]) {
    assert.throws(() => validateJunitText(malformed), /JUnit/u)
  }

  const redacted = redactSensitiveText(
    'password=operator-password-value Authorization: Bearer eyJabc.defghi.signature',
    [{key: 'operatorPassword', value: 'operator-password-value'}],
  )
  assert.ok(!redacted.text.includes('operator-password-value'))
  assert.ok(!redacted.text.includes('eyJabc.defghi.signature'))

  // Finalization is behavioral: a teardown failure cannot leave a passed
  // manifest, and the detached checksum must account for the terminal manifest.
  const teardownFailureRoot = join(testRoot, 'teardown-failure')
  mkdirSync(teardownFailureRoot)
  writeFileSync(join(teardownFailureRoot, 'compose-teardown.log'), 'mock teardown failed\n', 'utf8')
  const failedManifest = join(teardownFailureRoot, 'evidence-manifest.json')
  const failedManifestHash = join(teardownFailureRoot, 'evidence-manifest.sha256')
  const failedFinalization = finalizeEvidence({
    root: teardownFailureRoot,
    environmentPath,
    canaryKey: 'idpClientSecret',
    candidateStatus: 'passed',
    teardownStatus: 'failed',
    projectName: 'contract_project',
    tag: '0.25.0-RC3-contract',
    requestCount: 95,
    manifestPath: failedManifest,
    manifestHashPath: failedManifestHash,
  })
  assert.equal(failedFinalization.status, 'failed')
  const failedDocument = JSON.parse(readFileSync(failedManifest, 'utf8'))
  assert.equal(failedDocument.status, 'failed')
  const detachedHash = readFileSync(failedManifestHash, 'utf8').split(/\s+/u)[0]
  assert.equal(detachedHash, createHash('sha256').update(readFileSync(failedManifest)).digest('hex'))
  assert.ok(failedDocument.evidence.some((entry) => entry.path === 'compose-teardown.log'))
  assert.equal(failedDocument.detachedManifestHash.scope, 'evidence-manifest.json')

  const sanitizedRoot = join(testRoot, 'sanitized-success')
  mkdirSync(sanitizedRoot)
  writeFileSync(
    join(sanitizedRoot, 'newman.log'),
    'operator-password-value tenant-owner-password-value Bearer eyJabc.defghi.signature\n',
    'utf8',
  )
  const sanitizedManifest = join(sanitizedRoot, 'evidence-manifest.json')
  const sanitizedHash = join(sanitizedRoot, 'evidence-manifest.sha256')
  const sanitizedResult = finalizeEvidence({
    root: sanitizedRoot,
    environmentPath,
    canaryKey: 'idpClientSecret',
    candidateStatus: 'passed',
    teardownStatus: 'passed',
    projectName: 'contract_project',
    tag: '0.25.0-RC3-contract',
    requestCount: 95,
    manifestPath: sanitizedManifest,
    manifestHashPath: sanitizedHash,
  })
  assert.equal(sanitizedResult.status, 'passed')
  const sanitizedLog = readFileSync(join(sanitizedRoot, 'newman.log'), 'utf8')
  assert.ok(!sanitizedLog.includes('operator-password-value'))
  assert.ok(!sanitizedLog.includes('tenant-owner-password-value'))
  assert.ok(!sanitizedLog.includes('eyJabc.defghi.signature'))

  // Structured 200 setup state is mandatory. A 404 is only provisional until
  // the exact operator completes the product authorization flow.
  assert.deepEqual(
    classifySetupStatus(200, {
      gateOpen: true,
      firstTenantConfigMissingKeys: [],
      emailConfigured: false,
      licenseConfigured: false,
    }),
    {state: 'open', productStateVerified: true},
  )
  assert.deepEqual(classifySetupStatus(404, {}), {state: 'closed', productStateVerified: false})
  assert.throws(() => classifySetupStatus(200, {gateOpen: true}), /structured/u)

  let expectedState = ''
  let sawExactCredentials = false
  const jwt = [
    Buffer.from('{"alg":"none"}').toString('base64url'),
    Buffer.from('{"sub":"operator-1","roles":["platform-admin"]}').toString('base64url'),
    'signature',
  ].join('.')
  const mockFetch = async (input, init) => {
    const url = new URL(input)
    if (url.pathname === '/authorize') {
      expectedState = url.searchParams.get('state')
      return new Response(null, {
        status: 302,
        headers: {Location: `/login?session_id=s1&return_url=${encodeURIComponent('/authorize/callback?session_id=s1')}`},
      })
    }
    if (url.pathname === '/login' && init.method === 'GET') {
      return new Response('<input name="tab_id" value="tab"><input name="session_code" value="session-code">', {
        status: 200,
        headers: {'Set-Cookie': 'oidc_login_csrf=cookie; Path=/; HttpOnly'},
      })
    }
    if (url.pathname === '/login' && init.method === 'POST') {
      const body = new URLSearchParams(String(init.body))
      sawExactCredentials =
        body.get('username') === 'operator@example.com' &&
        body.get('password') === 'operator-password-value'
      return new Response(null, {status: 302, headers: {Location: '/authorize/callback?session_id=s1'}})
    }
    if (url.pathname === '/authorize/callback') {
      return new Response(null, {
        status: 302,
        headers: {Location: `/admin-console/callback?code=code-1&state=${expectedState}`},
      })
    }
    if (url.pathname === '/token') {
      return Response.json({access_token: jwt})
    }
    throw new Error(`Unexpected mock request ${init.method} ${url}`)
  }
  const identity = await authenticateExactOperator({
    fetchImpl: mockFetch,
    platformUrl: 'https://platform.saas.localtest.me',
    operatorEmail: 'operator@example.com',
    operatorPassword: 'operator-password-value',
  })
  assert.equal(sawExactCredentials, true)
  assert.equal(identity.subject, 'operator-1')
  assert.deepEqual(identity.roles, ['platform-admin'])

  const reportDir = join(testRoot, 'dry-run')
  const sourceState = join(testRoot, 'release-source-state.json')
  writeFileSync(sourceState, JSON.stringify({
    schemaVersion: 1,
    tag: '0.25.0-RC3-contract',
    capturedAt: '2026-07-30T12:00:00Z',
    fingerprint: `sha256:${'a'.repeat(64)}`,
    imageRevisionLabel: '0123456789abcdef0123456789abcdef01234567',
    imageSourceLabel: 'https://github.com/Sphereon-Opensource/VDX-infra',
  }))
  mkdirSync(reportDir)
  const dryRun = spawnSync(powershell, [
    '-NoLogo',
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy', 'Bypass',
    '-File', wrapperPath,
    '-Tag', '0.25.0-RC3-contract',
    '-ProjectName', 'edk_customer_contract',
    '-ReportDir', reportDir,
    '-AccessMode', 'Localtest',
    '-BaseDomain', 'saas.localtest.me',
    '-SourceState', sourceState,
    '-ExpectedSource', 'https://github.com/Sphereon-Opensource/VDX-infra',
    '-ComposeEnvFile', join(customerRoot, 'compose', '.env.example'),
    '-PostmanEnvironmentFile', join(customerRoot, 'postman', 'EDK-Enterprise-Deployment.customer.postman_environment.json'),
    '-PreProvisionedSetup',
    '-DryRun',
  ], {
    cwd: repoRoot,
    encoding: 'utf8',
    env: {...process.env, PATH: dirname(process.execPath)},
  })
  assert.equal(dryRun.status, 0, `${dryRun.stdout}\n${dryRun.stderr}`)
  const plan = JSON.parse(readFileSync(join(reportDir, 'release-gate-plan.json'), 'utf8').replace(/^\uFEFF/u, ''))
  assert.equal(plan.mode, 'dry-run')
  assert.equal(plan.accessMode, 'Localtest')
  assert.equal(plan.requestCount, 95)
  assert.equal(plan.projectName, 'edk_customer_contract')
  assert.equal(plan.requiresLocalCa, true)
  assert.equal(plan.composeFiles[1], join(customerRoot, 'compose', 'docker-compose.gateway.yml'))
  assert.deepEqual(
    plan.releaseImages.map((reference) => reference.split('/').at(-1).split(':')[0]),
    expectedImages,
  )

  const edgeReportDir = join(testRoot, 'dry-run-behind-edge')
  const edgeEnvironment = join(testRoot, 'behind-edge.postman_environment.json')
  writeEnvironment(edgeEnvironment, {baseDomain: 'compose-rc3.nk.sphereon.com'})
  mkdirSync(edgeReportDir)
  const edgeDryRun = spawnSync(powershell, [
    '-NoLogo',
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy', 'Bypass',
    '-File', wrapperPath,
    '-Tag', '0.25.0-RC3-contract',
    '-ProjectName', 'edk_customer_edge_contract',
    '-ReportDir', edgeReportDir,
    '-AccessMode', 'BehindEdge',
    '-BaseDomain', 'compose-rc3.nk.sphereon.com',
    '-EdgeEnvironment', 'compose-rc3',
    '-EdgeNetworkName', 'edge',
    '-EdgeTrustedSubnet', '172.16.100.0/24',
    '-SourceState', sourceState,
    '-ExpectedSource', 'https://github.com/Sphereon-Opensource/VDX-infra',
    '-ComposeEnvFile', join(customerRoot, 'compose', '.env.example'),
    '-PostmanEnvironmentFile', edgeEnvironment,
    '-PreProvisionedSetup',
    '-DryRun',
  ], {
    cwd: repoRoot,
    encoding: 'utf8',
    env: {...process.env, PATH: dirname(process.execPath)},
  })
  assert.equal(edgeDryRun.status, 0, `${edgeDryRun.stdout}\n${edgeDryRun.stderr}`)

  const edgePlan = JSON.parse(readFileSync(join(edgeReportDir, 'release-gate-plan.json'), 'utf8').replace(/^\uFEFF/u, ''))
  assert.equal(edgePlan.mode, 'dry-run')
  assert.equal(edgePlan.accessMode, 'BehindEdge')
  assert.equal(edgePlan.baseDomain, 'compose-rc3.nk.sphereon.com')
  assert.equal(edgePlan.publicOrigin, 'https://platform.compose-rc3.nk.sphereon.com')
  assert.equal(edgePlan.requiresLocalCa, false)
  assert.equal(edgePlan.edgeEnvironment, 'compose-rc3')
  assert.equal(edgePlan.edgeAlias, 'gw-compose-rc3')
  assert.equal(edgePlan.edgeNetwork, 'edge')
  assert.equal(edgePlan.composeFiles[1], join(edgeReportDir, 'behind-edge', 'docker-compose.behind-edge.yml'))

  const edgeCompose = readFileSync(edgePlan.composeFiles[1], 'utf8')
  assert.match(edgeCompose, /EDK_PLATFORM_PUBLIC_URL: https:\/\/platform\.compose-rc3\.nk\.sphereon\.com/u)
  assert.match(edgeCompose, /aliases:\s*\n\s+- gw-compose-rc3/u)
  assert.match(edgeCompose, /name: edge\s*\n\s+external: true/u)
  for (const service of [
    'enterprise-platform',
    'enterprise-tenant-as',
    'enterprise-did',
    'enterprise-issuer',
    'enterprise-verifier',
  ]) {
    assert.match(
      edgeCompose,
      new RegExp(`^  ${service}:\\r?\\n(?: {4}.*\\r?\\n)*? {4}ports: !reset \\[\\]$`, 'mu'),
      `${service} must reset the base diagnostic host ports in BehindEdge mode`,
    )
  }
  for (const service of ['platform-postgres', 'tenant-postgres', 'otel-collector', 'jaeger']) {
    assert.doesNotMatch(
      edgeCompose,
      new RegExp(`^  ${service}:`, 'mu'),
      `${service} loopback support ports must remain owned by the base Compose file`,
    )
  }
  assert.doesNotMatch(edgeCompose, /local-ca|local-truststore|gateway\/certs/iu)

  const edgeDynamic = readFileSync(edgePlan.gatewayDynamic, 'utf8')
  assert.match(edgeDynamic, /Host\(`platform\.compose-rc3\.nk\.sphereon\.com`\)/u)
  assert.match(edgeDynamic, /HostRegexp\(`\^\[a-z0-9-\]\+\\\.compose-rc3\\\.nk\\\.sphereon\\\.com\$`\)/u)
  assert.match(edgeDynamic, /entryPoints: \["web"\]/u)
  assert.doesNotMatch(edgeDynamic, /websecure|^\s+tls:/mu)

  const edgeStatic = readFileSync(join(edgeReportDir, 'behind-edge', 'traefik.behind-edge.generated.yml'), 'utf8')
  assert.match(edgeStatic, /address: ":80"/u)
  assert.match(edgeStatic, /"172\.16\.100\.0\/24"/u)
  assert.doesNotMatch(edgeStatic, /websecure|certResolver|certFile/u)

  const edgeRouter = readFileSync(edgePlan.edgeRouterCandidate, 'utf8')
  assert.match(edgeRouter, /HostRegexp\(`\^\[a-z0-9-\]\+\\\.compose-rc3\\\.nk\\\.sphereon\\\.com\$`\)/u)
  assert.match(edgeRouter, /url: "http:\/\/gw-compose-rc3:80"/u)
  assert.match(edgeRouter, /certResolver: le/u)
} finally {
  rmSync(testRoot, {recursive: true, force: true})
}

console.log('customer compose Postman release-gate contract: passed')
