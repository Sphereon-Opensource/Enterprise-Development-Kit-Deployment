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
  EVIDENCE_LABELS,
  finalizeEvidence,
  normalizeOptionalLanes,
  OPTIONAL_LANES,
  parseOptionalLanes,
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
const tenantConsoleCompose = readFileSync(join(customerRoot, 'compose', 'docker-compose.yml'), 'utf8')
  .split(/^  admin-console-tenant:\s*$/m)[1]?.split(/^  [a-z][a-z0-9-]*:\s*$/m)[0]
assert.match(tenantConsoleCompose ?? '', /ADMIN_CONSOLE_PLATFORM_BASE_URL: http:\/\/enterprise-platform:18080/,
  'The tenant BFF must route platform-config calls to the platform, not recursively to its own public API')
const repoRoot = resolve(customerRoot, '..', '..')
const wrapperPath = join(scriptDir, 'run-compose-postman-release-gate.ps1')
const setupPath = join(scriptDir, 'prepare-compose-postman-setup.mjs')
const scannerPath = join(scriptDir, 'assert-plaintext-canary-absent.mjs')
const supportPath = join(scriptDir, 'compose-postman-release-gate-support.mjs')
const lifecycleModulePath = join(scriptDir, 'ComposePostmanReleaseGateLifecycle.psm1')
const variableAuditPath = join(repoRoot, 'deploy', 'edk', 'e2e', 'scripts', 'audit-postman-variables.mjs')
const idkExampleCollectionPath = join(
  repoRoot, 'vdx', 'edk', 'idk', 'examples', 'oid4vc', 'services', 'postman', 'IDK-OID4VCI-OID4VP-E2E.postman_collection.json',
)
const secretAuthorityGeneratorPath = join(scriptDir, 'generate-secret-authority-keys.ps1')
const secretAuthorityShellGeneratorPath = join(scriptDir, 'generate-secret-authority-keys.sh')
const collectionPath = join(customerRoot, 'postman', 'EDK-Enterprise-Deployment.postman_collection.json')
const composePath = join(customerRoot, 'compose', 'docker-compose.yml')
const composeGitignorePath = join(customerRoot, 'compose', '.gitignore')
const composeConfigRoot = join(customerRoot, 'compose', 'config')
const helmValuesPath = join(customerRoot, 'helm', 'edk-enterprise', 'values.yaml')
const e2eHelmValuesPath = join(repoRoot, 'deploy', 'edk', 'e2e', 'helm', 'values.yaml')

const wrapper = readFileSync(wrapperPath, 'utf8')
assert.ok(wrapper.includes("$snapshotDir = Join-Path $customerRoot 'postman\\snapshots'"), 'customer snapshot updates must not remove internal-overlay snapshots')
const setup = readFileSync(setupPath, 'utf8')
const compose = readFileSync(composePath, 'utf8')
const secretAuthorityGenerator = readFileSync(secretAuthorityGeneratorPath, 'utf8')
const secretAuthorityShellGenerator = readFileSync(secretAuthorityShellGeneratorPath, 'utf8')
const composeGitignore = readFileSync(composeGitignorePath, 'utf8')
const helmValues = readFileSync(helmValuesPath, 'utf8')
const e2eHelmValues = readFileSync(e2eHelmValuesPath, 'utf8')
const collection = JSON.parse(readFileSync(collectionPath, 'utf8'))
const powershell = process.platform === 'win32'
  ? join(process.env.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
  : 'pwsh'

const countFunction = wrapper.match(/function Count-Requests\([\s\S]*?\n}\r?\n/)[0]
const countProbe = spawnSync(powershell, ['-NoProfile', '-Command', `${countFunction}
$collection = Get-Content -LiteralPath '${collectionPath.replaceAll("'", "''")}' -Raw | ConvertFrom-Json
@{ inventory = (Count-Requests @($collection.item)); enabled = (Count-Requests @($collection.item) -EnabledOnly) } | ConvertTo-Json -Compress
`], {encoding: 'utf8'})
assert.equal(countProbe.status, 0, countProbe.stderr)
assert.deepEqual(JSON.parse(countProbe.stdout), {inventory: 219, enabled: 199})

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
    tenantServiceClientId: 'walkthrough-client-id',
    tenantServiceClientSecret: 'StableCanary_0123456789',
    ...overrides,
  }
  writeFileSync(path, `${JSON.stringify({
    values: Object.entries(values).map(([key, value]) => ({key, value, enabled: true})),
  }, null, 2)}\n`, 'utf8')
}

assert.equal(requestCount(collection.item), 219, 'shipped customer collection must contain the current 219-request customer reference')
const collectionRequests = requests(collection.item)
const requestByName = new Map(collectionRequests.map((item) => [item.name, item]))

// Every variable the collection reads is either declared or set by an earlier request, and every
// declared variable is used. The audit also flags names copied into the IDK example collection.
const variableAudit = spawnSync(process.execPath, [variableAuditPath, collectionPath, idkExampleCollectionPath], {encoding: 'utf8'})
assert.equal(variableAudit.status, 0, `${variableAudit.stdout}\n${variableAudit.stderr}`)
assert.match(variableAudit.stdout, /Postman variable audit passed\./u)

// The platform operator signs in through the hosted authorization server. client_credentials is
// reserved for the tenant service client the walkthrough registers in the tenant
// federation lane after the tenant authorization server has been discovered.
assert.deepEqual(collection.auth, {type: 'bearer', bearer: [{key: 'token', value: '{{operatorToken}}', type: 'string'}]})
const operatorTokenRequest = requestByName.get('05 Exchange code for operator token')
assert.ok(operatorTokenRequest, 'operator sign-in must end in an authorization-code token exchange')
assert.equal(operatorTokenRequest.request.url, '{{platformUrl}}/token')
assert.ok(operatorTokenRequest.request.body.urlencoded.some((entry) => entry.key === 'grant_type' && entry.value === 'authorization_code'))
assert.ok(JSON.stringify(operatorTokenRequest.event).includes("pm.collectionVariables.set('operatorToken', j.access_token)"))
const tenantTokenRequest = requestByName.get('01 Tenant service token (client credentials)')
assert.ok(tenantTokenRequest, 'tenant service token request must exist')
assert.equal(tenantTokenRequest.request.auth.type, 'basic')
assert.deepEqual(
  tenantTokenRequest.request.auth.basic.map((entry) => entry.value),
  ['{{tenantServiceClientId}}', '{{tenantServiceClientSecret}}'],
)
assert.ok(JSON.stringify(tenantTokenRequest.event).includes("pm.collectionVariables.set('tenantToken', tenantAccessToken)") ||
  JSON.stringify(tenantTokenRequest.event).includes("pm.collectionVariables.set('tenantToken', j.access_token)"))
const tenantServiceClientRegistration = requestByName.get('07b Register walkthrough tenant service client')
assert.ok(tenantServiceClientRegistration, 'tenant service client registration must follow tenant authorization-server discovery in folder 04')
assert.match(tenantServiceClientRegistration.request.body.raw, /"principalRoles": \[\s*"tenant-admin"\s*\]/u)
assert.match(tenantServiceClientRegistration.request.body.raw, /"grantTypes": \[\s*"client_credentials"\s*\]/u)
for (const folderName of ['06 Tenant Keys and DID', '10 Issuer Settings', '15 Issue SD-JWT VC and mdoc', '22 Verification']) {
  const folder = collection.item.find((item) => item.name === folderName)
  assert.deepEqual(folder.auth, {type: 'bearer', bearer: [{key: 'token', value: '{{tenantToken}}', type: 'string'}]}, `${folderName} must inherit the tenant token`)
}
assert.equal(
  collectionRequests.filter((item) => (item.request.header ?? []).some((header) => /^authorization$/iu.test(header.key))).length,
  0,
  'bearer credentials come from collection, folder, or request auth, never from a header',
)
assert.ok(collection.variable.some((entry) => entry.key === 'operatorCodeVerifier'), 'operator sign-in keeps its PKCE helper variable')
assert.ok(requestByName.has('03 Submit operator credentials'), 'the platform operator signs in through the hosted login form')
assert.ok(requestByName.has('05 Submit tenant owner credentials'), 'tenant owner activation keeps its forms login')
for (const name of [
  '00a Resolve EuPid DID signing selection',
  '00b Resolve mDL X.509 signing selection',
  '04a Create X.509 token status list',
  '04b Fetch hosted X.509 status list token',
  '01a Fetch signed verification request object',
]) {
  assert.ok(requestByName.has(name), `customer collection must retain release signing coverage: ${name}`)
}
// The customer reference reads and validates the KMS resources the tenant holds; the disposable
// SOFTWARE lifecycle (create, credential, rotate, detach, retire) is internal breadth and lives in
// the overlay folder checked by the internal gate.
for (const [name, method, url] of [
  ['01 List KMS offerings', 'GET', '{{tenantPlatformConfigApiBaseUrl}}/tenants/{{tenantId}}/kms/offerings'],
  ['02 List KMS resources', 'GET', '{{tenantPlatformConfigApiBaseUrl}}/tenants/{{tenantId}}/kms/resources'],
  ['03 Validate tenant setup KMS resource', 'POST', '{{tenantPlatformConfigApiBaseUrl}}/tenants/{{tenantId}}/kms/resources/{{kmsResourceHandle}}/validate'],
]) {
  const item = requestByName.get(name)
  assert.ok(item, `customer KMS resource request '${name}' must exist`)
  assert.equal(item.request.method, method, `${name} method`)
  assert.equal(item.request.url, url, `${name} path`)
}
assert.ok(!/krh_[A-Za-z0-9_-]{20,}/u.test(JSON.stringify(collection)), 'customer collection must never hardcode an opaque resource handle')
const tenantOriginContractItems = [
  '01 Register tenant',
  '05 List tenant gateway endpoint bindings',
  '06 Resolve tenant runtime service discovery',
]
for (const name of tenantOriginContractItems) {
  const source = JSON.stringify(requestByName.get(name)?.event ?? [])
  assert.ok(
    source.includes("pm.variables.get('tenantGatewayUrl')") && source.includes('expectedTenantOrigin'),
    `${name} must derive the exact tenant origin from the configured HTTPS gateway URL`,
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
  'service-data',
  'enterprise-tenant-as',
  'enterprise-issuer',
  'enterprise-verifier',
  'admin-console',
]
const composeReleaseImages = [...new Set(
  [...compose.matchAll(/image:\s+nexus\.sphereon\.com\/edk-docker\/([^:$]+):\$\{EDK_TAG/gu)]
    .map((match) => match[1]),
)].sort()
assert.deepEqual(composeReleaseImages, [...expectedImages].sort(), 'customer Compose must use exactly eight release images')
const tenantDbEnv = compose.match(/x-edk-tenant-db-env:[\s\S]*?(?=\nx-[a-z]|\nservices:)/u)?.[0] ?? ''
// Every runtime hosts the secret-use broker, so the tenant-serving and narrow runtime roles are
// shared. The authority-admin credential is not: it stays on enterprise-platform alone.
for (const credential of [
  'EDK_SECRET_MANAGEMENT_TENANT_DB_PASSWORD',
  'EDK_SECRET_MANAGEMENT_RUNTIME_DB_PASSWORD',
]) {
  assert.ok(tenantDbEnv.includes(`${credential}:`), `customer tenant DB environment must propagate ${credential} to every runtime`)
}
assert.ok(
  !tenantDbEnv.includes('EDK_SECRET_MANAGEMENT_ADMIN_DB_PASSWORD:'),
  'the authority-admin DB credential must not reach every runtime through the shared tenant DB anchor',
)
const platformService = compose.match(/\n  enterprise-platform:[\s\S]*?(?=\n  [a-z][a-z0-9-]*:\n)/u)?.[0] ?? ''
assert.ok(
  platformService.includes('EDK_SECRET_MANAGEMENT_ADMIN_DB_PASSWORD:'),
  'enterprise-platform must be the one runtime that receives the authority-admin DB credential',
)
for (const workload of ['service-platform', 'service-crypto', 'service-data', 'service-blob', 'service-tenant-as', 'service-oid4vci', 'service-oid4vp']) {
  assert.ok(compose.includes(`/workload/${workload}:/app/secret-authority/workload:ro`), `customer Compose must mount the ${workload} assertion key only into its owner`)
}
for (const coordinate of [
  'SECRET_AUTHORITY_CENTRAL_PERMIT_SIGNING_KEY',
  'SECRET_AUTHORITY_CENTRAL_ASSERTION_VERIFICATION_KEYS',
  'SECRET_AUTHORITY_SATELLITE_ASSERTION_SIGNING_KEY',
  'SECRET_AUTHORITY_SATELLITE_PERMIT_VERIFICATION_KEYS',
]) {
  assert.ok(compose.includes(coordinate), `customer Compose must require ${coordinate}`)
}
assert.ok(secretAuthorityGenerator.includes('-algorithm ED25519'), 'customer key generator must mint Ed25519 keys')
assert.ok(secretAuthorityGenerator.includes("'..\\compose\\.secret-authority'"), 'customer key generator must confine output below the ignored authority root')
assert.ok(secretAuthorityShellGenerator.includes('-algorithm ED25519'), 'customer shell key generator must mint Ed25519 keys')
assert.ok(secretAuthorityShellGenerator.includes('secret-authority output must be below'), 'customer shell key generator must confine destructive replacement')
assert.ok(composeGitignore.includes('.secret-authority/'), 'customer Compose must ignore generated secret-authority material')
for (const [configName, workloadId] of [
  ['platform', 'service-platform'],
  ['tenant-kms', 'service-crypto'],
  ['did', 'service-data'],
  ['blob', 'service-blob'],
  ['tenant-as', 'service-tenant-as'],
  ['issuer', 'service-oid4vci'],
  ['verifier', 'service-oid4vp'],
]) {
  const config = readFileSync(join(composeConfigRoot, `${configName}.application.yml`), 'utf8')
  assert.ok(config.includes('secret:\n  authority:'), `${configName} must configure the secret authority role`)
  assert.ok(config.includes(`workload-id: ${workloadId}`), `${configName} must bind secret assertions to ${workloadId}`)
  assert.ok(config.includes('verification-keys: ${env:SECRET_AUTHORITY_SATELLITE_PERMIT_VERIFICATION_KEYS}'), `${configName} must verify central permits`)
  if (configName !== 'platform') {
    assert.match(
      config,
      /\n {6}secret:\n {8}target: SERVER\n {8}transport: GRPC\n {8}endpoint: grpc:\/\/enterprise-platform:9090\n {8}serviceTokenAudience: enterprise-platform\n(?: {8}#[^\n]*\n)* {8}preferServiceTokenOverSessionBearer: false\n/u,
      `${configName} must route the central secret-authority module to the platform with its downscoped bearer`,
    )
  }
  // The authority-admin database route is platform-only. Satellites host the secret-use broker
  // and get the tenant-serving role alone, so requiring the admin route of them would pin the
  // inverse of that boundary.
  const expectedSecretRoutes = configName === "platform"
    ? [
        ['secret-management-admin', 'secret_management_admin', 'EDK_SECRET_MANAGEMENT_ADMIN_DB_PASSWORD'],
        ['secret-management-tenant', 'secret_management_tenant_serving', 'EDK_SECRET_MANAGEMENT_TENANT_DB_PASSWORD'],
      ]
    : [['secret-management-tenant', 'secret_management_tenant_serving', 'EDK_SECRET_MANAGEMENT_TENANT_DB_PASSWORD']]
  if (configName !== 'platform') {
    assert.ok(
      !config.includes('    secret-management-admin:\n'),
      `${configName} must not configure the authority-admin database route`,
    )
  }
  for (const [route, username, passwordEnvironment] of expectedSecretRoutes) {
    const marker = `    ${route}:\n`
    const roleStart = config.indexOf(marker)
    assert.notEqual(roleStart, -1, `${configName} must configure the ${route} database route`)
    const roleTail = config.slice(roleStart + marker.length)
    const nextRoute = roleTail.search(/\n {4}[a-z0-9-]+:\n/u)
    const roleBlock = nextRoute === -1 ? roleTail : roleTail.slice(0, nextRoute)
    assert.ok(roleBlock.includes(`username: ${username}`), `${configName} ${route} must use its restricted SQL role`)
    assert.ok(roleBlock.includes(`password: \${env:${passwordEnvironment}}`), `${configName} ${route} must use its dedicated password`)
    assert.ok(roleBlock.includes('dedicated-pool: true'), `${configName} ${route} must not reuse the default runtime pool`)
  }
}
const tenantAsConfig = readFileSync(join(composeConfigRoot, 'tenant-as.application.yml'), 'utf8')
assert.ok(
  tenantAsConfig.includes(
    '      auth:\n' +
      '        # Identity and credential storage is owned by the platform control plane. Hosted login\n' +
      '        # stays local, but password verification must use the same central credential authority.\n' +
      '        serviceTokenAudience: enterprise-platform\n' +
      '        preferServiceTokenOverSessionBearer: true\n' +
      '        services:\n' +
      '          credentials:\n' +
      '            commands:\n' +
      '              "[auth.credentials.verify-remote]":\n' +
      '                target: SERVER\n' +
      '                transport: GRPC\n' +
      '                endpoint: grpc://enterprise-platform:9090\n',
  ),
  'customer Compose tenant AS must verify passwords through the platform credential authority',
)
const platformConfig = readFileSync(join(composeConfigRoot, 'platform.application.yml'), 'utf8')
assert.doesNotMatch(
  platformConfig,
  /operator@example\.com|EDK_PLATFORM_OPERATOR_EMAIL/u,
  'customer Compose must not ship a synthetic platform operator identity',
)
assert.doesNotMatch(helmValues, /operator@example\.com/u, 'customer Helm must not ship a synthetic platform operator identity')
assert.match(helmValues, /allowTenantManagedProviders: false/u, 'customer Helm must not publish cloud-provider fixtures by default')
assert.match(e2eHelmValues, /allowTenantManagedProviders: false/u, 'E2E Helm must preserve the clean customer provider baseline')
assert.match(
  rootYamlBlock(platformConfig, 'secret-management'),
  /\n {4}tenant-policy:\n(?: {6}#[^\n]*\n)* {6}allow-tenant-managed-providers: \$\{env:SECRET_MANAGEMENT_AUTHORITY_TENANT_POLICY_ALLOW_TENANT_MANAGED_PROVIDERS:false\}\n/u,
  'customer Compose must not publish cloud-provider fixtures by default',
)
assert.match(
  rootYamlBlock(platformConfig, 'sphereon'),
  /\n {2}service:\n {4}id: service-platform\n/u,
  'customer Compose platform must attest its local secret-bound workload as service-platform',
)

function rootYamlBlock(config, key) {
  const marker = `${key}:\n`
  const rootMarker = new RegExp(`(?:^|\\n)${key}:\\n`, 'u')
  const match = rootMarker.exec(config)
  assert.ok(match, `${key} must be a root YAML key`)
  const start = match.index + (match[0].startsWith('\n') ? 1 : 0)
  const bodyStart = start + marker.length
  const tail = config.slice(bodyStart)
  const nextRootOffset = tail.search(/\n(?=[a-z0-9][a-z0-9-]*:\n)/u)
  return config.slice(start, nextRootOffset === -1 ? config.length : bodyStart + nextRootOffset)
}

const tenantConfig = rootYamlBlock(platformConfig, 'tenant')
assert.match(
  tenantConfig,
  /\n {2}registration:\n(?: {4}#[^\n]*\n)* {4}signing-key:\n {6}auto-generate: true\n/u,
  'customer Compose must opt fresh tenant registration into typed product-key provisioning under tenant.registration',
)
assert.doesNotMatch(
  rootYamlBlock(platformConfig, 'platform'),
  /\n {2}registration:\n/u,
  'typed product-key provisioning must not be misconfigured under platform.registration',
)
assert.match(
  rootYamlBlock(platformConfig, 'secret-management'),
  /\n {2}internal-resolution:\n(?: {4}[^\n]*\n)* {4}workload-actor-ids: tenant-as-service=service-tenant-as,issuer-service=service-oid4vci,kms-service=service-crypto,did-service=service-data,blob-service=service-blob,verifier-service=service-oid4vp,email-service=service-email\n/u,
  'customer Compose must map authenticated service clients to their authorized secret workload identities',
)
assert.ok(
  platformConfig.includes(
    '      kms:\n' +
      '        serviceTokenAudience: enterprise-tenant-kms\n' +
      '        # Tenant KMS accepts the platform\'s dedicated workload identity. Never forward the\n' +
      '        # incoming operator or tenant-AS STS bearer across this trust boundary.\n' +
      '        preferServiceTokenOverSessionBearer: true\n',
  ),
  'customer Compose platform must mint its dedicated tenant-KMS workload token instead of forwarding a foreign-audience bearer',
)
assert.ok(
  platformConfig.includes(
    '      "[oauth2-as-admin]":\n' +
      '        target: SERVER\n' +
      '        serviceTokenAudience: enterprise-tenant-as\n' +
      '        preferServiceTokenOverSessionBearer: false\n' +
      '        services:\n' +
      '          "[signing-key]":\n' +
      '            target: SERVER\n' +
      '            transport: HTTP\n' +
      '            endpoint: http://enterprise-tenant-as:18083\n',
  ),
  'customer Compose platform must route tenant signing-key registration with the tenant-bound STS session',
)

for (const sourceInvariant of [
  "'docker-compose.yml'",
  "'docker-compose.gateway.yml'",
  'verify-enterprise-image-set.mjs',
  'compose-postman-release-gate-support.mjs',
  "'--pull', 'never'",
  "'E2E finished:\\s+' + [regex]::Escape($enabledRequestCount) + ' requests captured,\\s+exit code 0\\.'",
  "'pg_dump --schema-only --no-owner --no-privileges",
  "'scan-producer'",
  'finalize-evidence',
  "'evidence-manifest.sha256'",
  'Assert-BehindEdgeMergedCompose',
  "'config', '--format', 'json'",
  "host_ip -ne '127.0.0.1'",
  'generate-secret-authority-keys.ps1',
  'EDK_SECRET_AUTHORITY_ROOT=',
  '"@ + "`n" + $publicDynamic.Substring($httpMatch.Index)',
  "'Nudge shared edge router reload'",
  'Wait-BehindEdgePublicOrigin',
  "'edge-public-readiness.log'",
  'if (-not $KeepUp -and (Test-Path -LiteralPath $secretAuthorityRoot',
  'Write-Utf8NoBom $inventoryPath',
  '$imageReport.sourceState.fingerprint',
  "$imageReport.backendBuild.revision",
  '$containerIds = @(Split-NonEmptyLines',
  "foreach ($buildFamily in @('backendBuild', 'adminConsoleBuild'))",
  'Capture-DatabaseEvidence',
  "c.relname = '_schema_version'",
  'runtime_can_read',
  'Publish-NewmanSafeArtifacts',
  "if ($Topology -eq 'Distributed' -and $BaselineInstall) {",
  "'-BaselineInstall requires -KeepUp; a torn-down baseline cannot be upgraded.'",
  "'-BaselineInstall cannot be combined with -UpdateSnapshots.'",
  "--evidence-kind $(if ($BaselineInstall) { 'baseline' } else { 'release' })",
  '--request-count $enabledRequestCount',
  // Preflight: the five vendored openapi checkouts must agree before the stack comes up.
  'verify-openapi-checkouts.mjs',
  '& $nodeCommand $openapiCheckoutVerifier --allow-missing',
  // Optional lanes: overlay per switch, Postman values only via the runner's env channel,
  // and every lane recorded in the manifest as ran or skipped.
  '[switch]$Keycloak',
  '[switch]$WebhookSink',
  "'docker-compose.keycloak.yml'",
  "'keycloak\\edk-realm.json'",
  "'docker-compose.webhook-sink.yml'",
  'Set-OptionalLaneEnvironment',
  '$env:EDK_E2E_ENV_keycloakIssuerUrl',
  '$env:EDK_E2E_ENV_keycloakClientSecret',
  '$env:EDK_E2E_ENV_webhookSinkInternalUrl',
  '$env:EDK_E2E_ENV_webhookSinkAdminUrl',
  // The Azure lane has no overlay; it is ran only when -AzureKms is given and every AZURE_*
  // value is present, and a missing value skips it rather than failing the gate.
  '[switch]$AzureKms',
  "$azureKmsEnvNames = @('AZURE_KEY_VAULT_URI', 'AZURE_TENANT_ID', 'AZURE_CLIENT_ID', 'AZURE_CLIENT_SECRET', 'AZURE_HSM_KEY_NAME', 'AZURE_CERT_NAME')",
  '$azureKmsLaneReady = [bool]($AzureKms -and $azureKmsMissing.Count -eq 0)',
  '"Azure lane skipped (missing: $($azureKmsMissing -join ', '))"',
  '$env:EDK_E2E_ENV_azureKeyVaultUri',
  '$env:EDK_E2E_ENV_azureClientSecret',
  "azureKms = if ($azureKmsLaneReady) { 'ran' } else { 'skipped' }",
  "eudi = 'skipped'",
  '--optional-lanes $optionalLanesArgument',
]) {
  assert.ok(wrapper.includes(sourceInvariant), `wrapper must retain '${sourceInvariant}'`)
}
// The customer overlays the switches append must exist and join the same networks as the
// tenant AS so the AS can reach Keycloak and the dispatcher can reach the sink in-network.
const customerKeycloakOverlay = readFileSync(join(customerRoot, 'compose', 'docker-compose.keycloak.yml'), 'utf8')
assert.ok(customerKeycloakOverlay.includes('KC_DB_URL: jdbc:postgresql://platform-postgres:5432/keycloak'))
assert.ok(customerKeycloakOverlay.includes('KC_HOSTNAME: http://keycloak:8080'))
assert.ok(customerKeycloakOverlay.includes('- appnet'))
assert.ok(customerKeycloakOverlay.includes('- platform-db-net'))
assert.ok(customerKeycloakOverlay.includes('20-keycloak-database.sh:/docker-entrypoint-initdb.d/20-keycloak-database.sh:ro'))
assert.ok(customerKeycloakOverlay.includes('${EDK_KEYCLOAK_DB_PASSWORD:?Set EDK_KEYCLOAK_DB_PASSWORD}'), 'customer lane must not ship a default Keycloak database password')
const customerRealm = JSON.parse(readFileSync(join(customerRoot, 'compose', 'keycloak', 'edk-realm.json'), 'utf8'))
assert.equal(customerRealm.realm, 'edk')
const tenantAsClient = customerRealm.clients.find((client) => client.clientId === 'edk-tenant-as')
assert.ok(tenantAsClient && tenantAsClient.publicClient === false && tenantAsClient.standardFlowEnabled === true)
assert.ok(tenantAsClient.redirectUris.includes('http://enterprise-tenant-as:18083/federation/callback'))
assert.ok(customerRealm.users.some((user) => user.username === 'wallet-user' && user.emailVerified === true))
const customerWebhookOverlay = readFileSync(join(customerRoot, 'compose', 'docker-compose.webhook-sink.yml'), 'utf8')
assert.ok(customerWebhookOverlay.includes('image: wiremock/wiremock:${EDK_WEBHOOK_SINK_IMAGE_TAG:-3}'))
assert.ok(customerWebhookOverlay.includes('./webhook-sink/mappings:/home/wiremock/mappings:ro'))
for (const mapping of ['hooks-ok.json', 'hooks-fail.json', 'hooks-flaky.json']) {
  JSON.parse(readFileSync(join(customerRoot, 'compose', 'webhook-sink', 'mappings', mapping), 'utf8'))
}
// Drift enforcement is never switched off. Re-minting the baselines is a deliberate, explicit
// choice, so --update may reach the runner only behind the -UpdateSnapshots switch.
assert.ok(!wrapper.includes("'--skip-snapshots'"), 'release gate must never skip snapshot comparison')
assert.ok(
  wrapper.includes("$(if ($UpdateSnapshots) { @('--update') } else { @() })"),
  'release gate must gate snapshot minting behind -UpdateSnapshots',
)
assert.equal(
  (wrapper.match(/'--update'/gu) ?? []).length,
  1,
  'release gate must pass --update from exactly the one guarded site',
)
assert.ok(setup.includes('/api/platform/setup/v1/license/import/preview'), 'setup must preview the protected bundle')
assert.ok(setup.includes('/api/platform/setup/v1/bootstrap'), 'setup must use the product bootstrap API')

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
    '--canary-key', 'tenantServiceClientSecret',
    '--label', 'contract-clean',
  ], {input: 'safe evidence\n', encoding: 'utf8'})
  assert.equal(cleanScan.status, 0, cleanScan.stderr)
  const leakingScan = spawnSync(process.execPath, [
    scannerPath,
    '--environment', environmentPath,
    '--canary-key', 'tenantServiceClientSecret',
    '--label', 'contract-leak',
  ], {input: `unsafe ${canary}\n`, encoding: 'utf8'})
  assert.notEqual(leakingScan.status, 0, 'scanner must fail for the submitted canary')
  const emptyScan = spawnSync(process.execPath, [
    scannerPath,
    '--environment', environmentPath,
    '--canary-key', 'tenantServiceClientSecret',
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
    '--canary-key', 'tenantServiceClientSecret',
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
    canaryKey: 'tenantServiceClientSecret',
    candidateStatus: 'passed',
    teardownStatus: 'failed',
    projectName: 'contract_project',
    tag: '0.25.0-RC3-contract',
    requestCount: 169,
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

  // A baseline install is not a release verdict: it carries its own kind into the manifest so a
  // reader (and the console line) can never mistake it for a gate pass.
  const baselineRoot = join(testRoot, 'baseline-evidence')
  mkdirSync(baselineRoot)
  writeFileSync(join(baselineRoot, 'newman.log'), 'baseline run\n', 'utf8')
  const baselineManifest = join(baselineRoot, 'evidence-manifest.json')
  const baselineResult = finalizeEvidence({
    root: baselineRoot,
    environmentPath,
    canaryKey: 'tenantServiceClientSecret',
    candidateStatus: 'passed',
    teardownStatus: 'passed',
    projectName: 'contract_project',
    tag: '0.25.0-RC3',
    requestCount: 113,
    manifestPath: baselineManifest,
    manifestHashPath: join(baselineRoot, 'evidence-manifest.sha256'),
    evidenceKind: 'baseline',
  })
  assert.equal(baselineResult.evidenceKind, 'baseline')
  assert.equal(EVIDENCE_LABELS.baseline, 'customer-compose-baseline')
  assert.notEqual(EVIDENCE_LABELS.baseline, EVIDENCE_LABELS.release)
  assert.equal(JSON.parse(readFileSync(baselineManifest, 'utf8')).kind, 'baseline')
  // The helper parses options into a Map, so the CLI must read it with .get. Exercising the
  // command line here is what catches a property read that silently falls back to 'release'.
  const cliRoot = join(testRoot, 'baseline-cli')
  mkdirSync(cliRoot)
  writeFileSync(join(cliRoot, 'newman.log'), 'baseline cli run\n', 'utf8')
  const cliManifest = join(cliRoot, 'evidence-manifest.json')
  const cli = spawnSync(process.execPath, [
    join(customerRoot, 'scripts', 'compose-postman-release-gate-support.mjs'),
    'finalize-evidence',
    '--root', cliRoot,
    '--environment', environmentPath,
    '--canary-key', 'tenantServiceClientSecret',
    '--candidate-status', 'passed',
    '--teardown-status', 'passed',
    '--project-name', 'contract_project',
    '--tag', '0.25.0-RC3',
    '--request-count', '113',
    '--manifest', cliManifest,
    '--manifest-hash', join(cliRoot, 'evidence-manifest.sha256'),
    '--evidence-kind', 'baseline',
  ], {encoding: 'utf8'})
  assert.equal(cli.status, 0, `${cli.stdout}\n${cli.stderr}`)
  assert.match(cli.stdout, /customer-compose-baseline:passed/u)
  assert.doesNotMatch(cli.stdout, /customer-compose-evidence:/u)
  assert.equal(JSON.parse(readFileSync(cliManifest, 'utf8')).kind, 'baseline')
  // A run without lane flags still records every optional lane, as skipped.
  assert.deepEqual(JSON.parse(readFileSync(cliManifest, 'utf8')).optionalLanes, {
    keycloak: 'skipped',
    webhookSink: 'skipped',
    azureKms: 'skipped',
    eudi: 'skipped',
  })

  // Optional lanes: the manifest names each lane as ran or skipped. Lanes without a switch yet
  // (azureKms, eudi) are still listed so their absence is explicit rather than silent.
  assert.deepEqual([...OPTIONAL_LANES], ['keycloak', 'webhookSink', 'azureKms', 'eudi'])
  assert.deepEqual(normalizeOptionalLanes({keycloak: 'ran'}), {
    keycloak: 'ran',
    webhookSink: 'skipped',
    azureKms: 'skipped',
    eudi: 'skipped',
  })
  assert.throws(() => normalizeOptionalLanes({mailpit: 'ran'}), /Unknown optional lane 'mailpit'/u)
  assert.throws(() => normalizeOptionalLanes({keycloak: 'yes'}), /must be ran or skipped/u)
  assert.deepEqual(parseOptionalLanes('keycloak=ran, webhookSink=ran'), {
    keycloak: 'ran',
    webhookSink: 'ran',
    azureKms: 'skipped',
    eudi: 'skipped',
  })
  assert.deepEqual(parseOptionalLanes(''), normalizeOptionalLanes({}))
  assert.throws(() => parseOptionalLanes('keycloak'), /expected name=ran\|skipped/u)
  const lanesRoot = join(testRoot, 'optional-lanes')
  mkdirSync(lanesRoot)
  writeFileSync(join(lanesRoot, 'newman.log'), 'keycloak lane run\n', 'utf8')
  const lanesManifest = join(lanesRoot, 'evidence-manifest.json')
  const lanesResult = finalizeEvidence({
    root: lanesRoot,
    environmentPath,
    canaryKey: 'tenantServiceClientSecret',
    candidateStatus: 'passed',
    teardownStatus: 'passed',
    projectName: 'contract_project',
    tag: '0.25.0-RC3',
    requestCount: 113,
    manifestPath: lanesManifest,
    manifestHashPath: join(lanesRoot, 'evidence-manifest.sha256'),
    optionalLanes: {keycloak: 'ran', webhookSink: 'ran'},
  })
  assert.deepEqual(lanesResult.optionalLanes, {keycloak: 'ran', webhookSink: 'ran', azureKms: 'skipped', eudi: 'skipped'})
  assert.deepEqual(JSON.parse(readFileSync(lanesManifest, 'utf8')).optionalLanes, lanesResult.optionalLanes)
  const lanesCliRoot = join(testRoot, 'optional-lanes-cli')
  mkdirSync(lanesCliRoot)
  writeFileSync(join(lanesCliRoot, 'newman.log'), 'lanes cli run\n', 'utf8')
  const lanesCliManifest = join(lanesCliRoot, 'evidence-manifest.json')
  const lanesCli = spawnSync(process.execPath, [
    join(customerRoot, 'scripts', 'compose-postman-release-gate-support.mjs'),
    'finalize-evidence',
    '--root', lanesCliRoot,
    '--environment', environmentPath,
    '--canary-key', 'tenantServiceClientSecret',
    '--candidate-status', 'passed',
    '--teardown-status', 'passed',
    '--project-name', 'contract_project',
    '--tag', '0.25.0-RC3',
    '--request-count', '113',
    '--manifest', lanesCliManifest,
    '--manifest-hash', join(lanesCliRoot, 'evidence-manifest.sha256'),
    '--optional-lanes', 'keycloak=ran,webhookSink=skipped',
  ], {encoding: 'utf8'})
  assert.equal(lanesCli.status, 0, `${lanesCli.stdout}\n${lanesCli.stderr}`)
  assert.match(lanesCli.stdout, /customer-compose-optional-lanes:keycloak=ran,webhookSink=skipped,azureKms=skipped,eudi=skipped/u)
  assert.deepEqual(JSON.parse(readFileSync(lanesCliManifest, 'utf8')).optionalLanes, {
    keycloak: 'ran',
    webhookSink: 'skipped',
    azureKms: 'skipped',
    eudi: 'skipped',
  })

  assert.throws(
    () => finalizeEvidence({
      root: baselineRoot,
      environmentPath,
      canaryKey: 'tenantServiceClientSecret',
      candidateStatus: 'passed',
      teardownStatus: 'passed',
      projectName: 'contract_project',
      tag: '0.25.0-RC3',
      requestCount: 113,
      manifestPath: baselineManifest,
      manifestHashPath: join(baselineRoot, 'evidence-manifest.sha256'),
      evidenceKind: 'release-ish',
    }),
    /Unknown evidence kind/u,
  )

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
    canaryKey: 'tenantServiceClientSecret',
    candidateStatus: 'passed',
    teardownStatus: 'passed',
    projectName: 'contract_project',
    tag: '0.25.0-RC3-contract',
    requestCount: 169,
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
  assert.equal(plan.requestCount, 219)
  assert.equal(plan.projectName, 'edk_customer_contract')
  assert.equal(plan.requiresLocalCa, true)
  assert.equal(plan.composeFiles[1], join(customerRoot, 'compose', 'docker-compose.gateway.yml'))
  assert.deepEqual(
    plan.releaseImages.map((reference) => reference.split('/').at(-1).split(':')[0]),
    expectedImages,
  )

  const monolithReportDir = join(testRoot, 'dry-run-monolith')
  mkdirSync(monolithReportDir)
  const monolithDryRun = spawnSync(powershell, [
    '-NoLogo',
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy', 'Bypass',
    '-File', wrapperPath,
    '-Tag', '0.25.0-RC3-contract',
    '-Topology', 'Monolith',
    '-MonolithImage', 'sphereon/vdx-svc-monolith:0.25.0-RC3-contract',
    '-ProjectName', 'edk_customer_monolith_contract',
    '-ReportDir', monolithReportDir,
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
  assert.equal(monolithDryRun.status, 0, `${monolithDryRun.stdout}\n${monolithDryRun.stderr}`)
  const monolithPlan = JSON.parse(readFileSync(join(monolithReportDir, 'release-gate-plan.json'), 'utf8').replace(/^\uFEFF/u, ''))
  assert.equal(monolithPlan.topology, 'Monolith')
  assert.equal(monolithPlan.accessMode, 'Localtest')
  assert.equal(monolithPlan.requestCount, 219)
  assert.equal(monolithPlan.composeFiles.length, 3)
  assert.equal(monolithPlan.composeFiles[0], join(customerRoot, 'compose', 'docker-compose.monolith-base.yml'))
  assert.equal(monolithPlan.composeFiles[1], join(repoRoot, 'deploy', 'docker', 'docker-compose.monolith.local.yml'))
  assert.match(readFileSync(monolithPlan.composeFiles[1], 'utf8'), /LICENSE_GATE_SERVICE_ROLE: \$\{VDX_LICENSE_GATE_SERVICE_ROLE:-platform\}/u)
  assert.match(readFileSync(monolithPlan.composeFiles[2], 'utf8'), /svc-monolith/u)
  assert.match(readFileSync(monolithPlan.composeFiles[2], 'utf8'), /acme\.saas\.localtest\.me/u)
  assert.match(readFileSync(monolithPlan.composeFiles[2], 'utf8'), /TENANT_RESOLUTION_SELF_HOSTS: localhost,svc-monolith,platform\.saas\.localtest\.me/u)
  assert.match(readFileSync(monolithPlan.gatewayDynamic, 'utf8'), /http:\/\/svc-monolith:8080/u)
  assert.doesNotMatch(readFileSync(monolithPlan.gatewayDynamic, 'utf8'), /http:\/\/enterprise-/u)

  // An explicitly supplied collection is how an older release is gated against the collection it
  // actually shipped with. Its own size becomes the contract, so the pinned default count must not
  // reject it, and the plan must record the count that will really be executed.
  const suppliedCollection = join(testRoot, 'supplied.postman_collection.json')
  writeFileSync(suppliedCollection, `${JSON.stringify({
    info: {name: 'supplied', schema: 'https://schema.getpostman.com/json/collection/v2.1.0/collection.json'},
    item: [
      {name: 'folder', item: [{name: 'one', request: {method: 'GET', url: 'http://example.test/1'}}]},
      {name: 'two', request: {method: 'GET', url: 'http://example.test/2'}},
    ],
  }, null, 2)}
`, 'utf8')
  const suppliedReportDir = join(testRoot, 'dry-run-supplied-collection')
  mkdirSync(suppliedReportDir)
  const suppliedDryRun = spawnSync(powershell, [
    '-NoLogo',
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy', 'Bypass',
    '-File', wrapperPath,
    '-Tag', '0.25.0-RC3-contract',
    '-ProjectName', 'edk_customer_supplied_contract',
    '-ReportDir', suppliedReportDir,
    '-AccessMode', 'Localtest',
    '-BaseDomain', 'saas.localtest.me',
    '-CollectionPath', suppliedCollection,
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
  assert.equal(suppliedDryRun.status, 0, `${suppliedDryRun.stdout}
${suppliedDryRun.stderr}`)
  const suppliedPlan = JSON.parse(readFileSync(join(suppliedReportDir, 'release-gate-plan.json'), 'utf8').replace(/^﻿/u, ''))
  assert.equal(suppliedPlan.collection, suppliedCollection)
  assert.equal(suppliedPlan.requestCount, 2)

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
    'enterprise-blob',
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
  assert.match(edgeRouter, /Host\(`platform\.compose-rc3\.nk\.sphereon\.com`\)/u)
  assert.equal(edgeRouter.includes('priority: 20000'), true)
  assert.match(edgeRouter, /url: "http:\/\/gw-compose-rc3:80"/u)
  assert.match(edgeRouter, /certResolver: le/u)
} finally {
  rmSync(testRoot, {recursive: true, force: true})
}

console.log('customer compose Postman release-gate contract: passed')
