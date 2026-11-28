import test from 'node:test'
import assert from 'node:assert/strict'
import {readFileSync} from 'node:fs'

// The registered administration operation catalog; HTTP adapter IDs are deliberately excluded.
const commandIds = [
  "oidfed.admin-configuration.patch",
  "oidfed.admin-configuration.read",
  "oidfed.admin-configuration.replace",
  "oidfed.admin-configuration.statement",
  "oidfed.admin-keys.create",
  "oidfed.admin-keys.delete",
  "oidfed.admin-keys.list",
  "oidfed.admin-keys.read",
  "oidfed.admin-keys.rotate",
  "oidfed.admin-node.read",
  "oidfed.admin-subordinates.create",
  "oidfed.admin-subordinates.delete",
  "oidfed.admin-subordinates.list",
  "oidfed.admin-subordinates.patch",
  "oidfed.admin-subordinates.read",
  "oidfed.admin-subordinates.replace",
  "oidfed.admin-subordinates.statement",
  "oidfed.admin-subordinates.status",
  "oidfed.admin-trust-mark-subjects.delete",
  "oidfed.admin-trust-mark-subjects.list",
  "oidfed.admin-trust-mark-subjects.replace",
  "oidfed.admin-trust-mark-subjects.status",
  "oidfed.admin-trust-mark-subjects.token",
  "oidfed.admin-trust-marks.create",
  "oidfed.admin-trust-marks.delete",
  "oidfed.admin-trust-marks.list",
  "oidfed.admin-trust-marks.read",
  "oidfed.admin-trust-marks.replace"
]
const permittedRoles = ['tenant-admin', 'platform-admin']
for (const relative of ['compose/config/platform.application.yml', 'compose/federation-publication-pdp/platform.application.yml']) {
  test(`${relative}: all standard administration operations use exact existing administrator roles`, () => {
    const source = readFileSync(new URL(`../../${relative}`, import.meta.url), 'utf8')
    const selected = [...source.matchAll(/^        - (oidfed\.admin-[^\s]+)$/gm)].map(m => m[1]).sort()
    const rules = [...source.matchAll(/^          - pattern: (oidfed\.admin-[^\s]+)\r?\n            any-of: \[([^\]]+)\]/gm)]
    assert.deepEqual(selected, commandIds)
    assert.deepEqual(rules.map(m => m[1]).sort(), commandIds)
    for (const rule of rules) assert.deepEqual(rule[2].split(', '), permittedRoles)
    assert.ok(!selected.some(id => id.includes('*') || id.startsWith('oidfed.admin-http.')))
  })
}
test('OPA role data contains exactly the standard catalog and preserves deny-by-default role matching', () => {
  const data = JSON.parse(readFileSync(new URL('../../compose/federation-publication-pdp/federation-publication-policy-data.json', import.meta.url), 'utf8')).federation_publication_policy
  assert.deepEqual(Object.keys(data.role_rules).filter(id => id.startsWith('oidfed.admin-')).sort(), commandIds)
  for (const id of commandIds) assert.deepEqual(data.role_rules[id], permittedRoles)
  const policy = readFileSync(new URL('../../compose/federation-publication-pdp/federation-publication-policy.rego', import.meta.url), 'utf8')
  assert.match(policy, /default allow = false/)
  assert.ok(policy.includes('data.federation_publication_policy.role_rules[input.action.name]'))
  assert.ok(policy.includes('role == required[_]'))
})

const readConfig = relative => readFileSync(new URL(`../../${relative}`, import.meta.url), 'utf8')
test('subordinate discovery uses the exact tenant administrator policy in both engines', () => {
  const id = 'oidfed.diagnostics.discover-subordinates'
  for (const relative of ['compose/config/platform.application.yml', 'compose/federation-publication-pdp/platform.application.yml']) {
    const source = readConfig(relative).replaceAll('\r\n', '\n')
    assert.equal(source.split(`        - ${id}\n`).length - 1, 1)
    assert.equal(source.split(`          - pattern: ${id}\n            any-of: [tenant-admin, platform-admin]\n`).length - 1, 1)
  }
  const data = JSON.parse(readConfig('compose/federation-publication-pdp/federation-publication-policy-data.json')).federation_publication_policy
  assert.deepEqual(data.role_rules[id], permittedRoles)
  assert.ok(!Object.hasOwn(data.service_rules, id))
})
const federationKeyCommands = [
  'kms.key.prepare-federation',
  'kms.key.read-federation-public',
  'kms.key.sign-federation-jws',
  'kms.key.discard-federation-preparation',
]

// Select the actual nested YAML block, rather than accepting a matching string
// in a comment, another service, or an overridden configuration namespace.
function configBlock(source, path, rootIndent = 0) {
  let lines = source.replaceAll('\r\n', '\n').split('\n')
  let indent = rootIndent
  for (const key of path) {
    const matches = lines.flatMap((line, index) => {
      const match = line.match(/^( *)([^#].*?):\s*(.*)$/)
      const name = match?.[2].replace(/^(["'])(.*)\1$/, '$2')
      return match && match[1].length === indent && name === key ? [index] : []
    })
    assert.equal(matches.length, 1, `Expected one YAML block ${path.join('.')}: ${key}`)
    const start = matches[0]
    let end = start + 1
    while (end < lines.length) {
      const line = lines[end]
      if (line.trim() && !line.trimStart().startsWith('#') && line.search(/\S/) <= indent) break
      end++
    }
    lines = lines.slice(start + 1, end)
    indent += 2
  }
  return {lines, indent}
}

function scalarConfig(source, path) {
  const {lines, indent} = configBlock(source, path)
  const entries = lines.filter(line => line.trim() && !line.trimStart().startsWith('#')).map(line => {
    const match = line.match(/^( *)([^#].*?):\s*(\S.*)$/)
    assert.ok(match && match[1].length === indent, `Expected scalar configuration at ${path.join('.')}`)
    return [match[2].replace(/^(["'])(.*)\1$/, '$2'), match[3].replace(/^(["'])(.*)\1$/, '$2')]
  })
  assert.equal(new Set(entries.map(([key]) => key)).size, entries.length, 'Duplicate configuration property')
  return Object.fromEntries(entries)
}

for (const relative of ['compose/config/platform.application.yml', 'compose/federation-publication-pdp/platform.application.yml']) {
  test(`${relative}: managed federation signing has its dedicated APP identity and four exact remote operations`, () => {
    const source = readConfig(relative)
    assert.deepEqual(scalarConfig(source, ['oidfed', 'key-management', 'service-identity']), {
      'token-endpoint': 'http://enterprise-platform:18080/token',
      'token-endpoint-allow-http': 'true',
      'platform-issuer': '${env:EXTERNAL_BASE_URL}',
      'client-id': 'federation-signing-service',
      audience: 'enterprise-tenant-kms',
    })
    const module = ['transport', 'routing', 'modules', 'kms']
    const {lines} = configBlock(source, module)
    assert.match(lines.join('\n'), /^        serviceTokenAudience: enterprise-tenant-kms$/m)
    assert.match(lines.join('\n'), /^        preferServiceTokenOverSessionBearer: true$/m)
    const key = [...module, 'services', 'key']
    const keyBlock = configBlock(source, key).lines.join('\n')
    assert.match(keyBlock, /^            transport: GRPC$/m)
    assert.match(keyBlock, /^            endpoint: grpc:\/\/enterprise-tenant-kms:9090$/m)
    const commands = configBlock(source, [...key, 'commands']).lines
    const selected = commands.filter(line => line.search(/\S/) === 14).map(line => line.trim().replace(/^"\[(.*)\]":$/, '$1'))
    assert.deepEqual(selected, federationKeyCommands)
    for (const id of federationKeyCommands) {
      assert.deepEqual(scalarConfig(source, [...key, 'commands', `[${id}]`]), {target: 'SERVER'})
    }
  })
}

test('tenant KMS admits the exact federation workload and uses its own token for central authority callbacks', () => {
  const source = readConfig('compose/config/tenant-kms.application.yml')
  const trusted = configBlock(source, ['security', 'workload-trust-policy', 'trusted_service_ids']).lines
    .filter(line => line.trim() && !line.trimStart().startsWith('#')).map(line => line.trim().replace(/^- /, ''))
  assert.equal(trusted.filter(id => id === 'federation-signing-service').length, 1)
  assert.ok(!trusted.some(id => /[*:]/.test(id)), 'Trust base clients only; tenant suffixes are matched against the resolved tenant')
  assert.deepEqual(scalarConfig(source, ['kms', 'federation-signing']), {'allowed-service-actors': 'federation-signing-service'})
  assert.deepEqual(scalarConfig(source, ['kms', 'hosted-as-signing']), {'allowed-service-actors': 'tenant-as-service'})
  const callback = scalarConfig(source, ['transport', 'routing', 'modules', 'oidfed', 'services', 'key'])
  assert.deepEqual(callback, {
    target: 'SERVER', transport: 'GRPC', endpoint: 'grpc://enterprise-platform:9090',
    serviceTokenAudience: 'enterprise-platform', preferServiceTokenOverSessionBearer: 'true',
  })
  const platformConfig = scalarConfig(source, ['transport', 'routing', 'modules', 'platform', 'services', 'config'])
  assert.equal(callback.endpoint, platformConfig.endpoint)
  assert.equal(callback.serviceTokenAudience, platformConfig.serviceTokenAudience)
  assert.equal(scalarConfig(source, ['config', 'overrides', 'transport', 'routing', 'modules', 'kms', 'services', 'key']).target, 'LOCAL')
})

test('Helm tenant KMS also trusts the dedicated federation client before command-level actor authorization', () => {
  const source = readConfig('helm/edk-enterprise/templates/configmap-tenant-kms.yaml')
  const trusted = configBlock(source, ['security', 'workload-trust-policy', 'trusted_service_ids'], 4).lines.join('\n')
  assert.equal([...trusted.matchAll(/^          - federation-signing-service$/gm)].length, 1)
  const guard = configBlock(source, ['kms', 'federation-signing'], 4).lines.join('\n')
  assert.match(guard, /^        allowed-service-actors: federation-signing-service$/m)
})

test('managed key authority callbacks permit only the KMS workload through the guarded service policy', () => {
  const data = JSON.parse(readConfig('compose/federation-publication-pdp/federation-publication-policy-data.json')).federation_publication_policy
  const callbacks = ['oidfed.key.claim-generation', 'oidfed.key.get-authority']
  assert.deepEqual(Object.keys(data.service_rules).filter(id => id.startsWith('oidfed.key.')).sort(), callbacks)
  for (const id of callbacks) {
    assert.deepEqual(data.service_rules[id], ['kms-service'])
    assert.ok(!Object.hasOwn(data.role_rules, id), 'Administrator roles must not authorize custody callbacks')
  }
  assert.ok(!Object.keys(data.service_rules).some(id => id.includes('*')), 'Service rules must select exact commands')
  const policy = readConfig('compose/federation-publication-pdp/federation-publication-policy.rego')
  assert.match(policy, /^default allow = false\r?$/m)
  const serviceRules = [...policy.matchAll(/^allow if \{\r?\n([\s\S]*?)^\}/gm)]
    .map(match => match[1]).filter(body => body.includes('service_rules'))
  assert.equal(serviceRules.length, 1)
  assert.deepEqual(serviceRules[0].trim().split(/\r?\n/).map(line => line.trim()), [
    'input.principal.type == "workload"',
    'input.context.session_principal_type in {"service", "workload"}',
    'workload_client_id in data.federation_publication_policy.service_rules[input.action.name]',
  ], 'A human or unrelated session must not enter the workload permit')
  assert.match(policy, /workload_client_id := input\.principal\.id if \{\s*is_string\(input\.principal\.id\)\s*indexof\(input\.principal\.id, ":"\) == -1\s*\}/)
  assert.match(policy, /workload_client_id := parts\[0\] if \{\s*is_string\(input\.principal\.id\)\s*parts := split\(input\.principal\.id, ":"\)\s*count\(parts\) == 2\s*is_string\(input\.context\.tenantId\)\s*parts\[1\] == input\.context\.tenantId\s*\}/,
    'A tenant-bound client must match the exact session tenant, with no extra suffixes')
})

test('publication PDP admits the deployed workload clients for tenant distribution, semantic scope and connector attachments', () => {
  const {role_rules: roles, service_rules: services} =
    JSON.parse(readConfig('compose/federation-publication-pdp/federation-publication-policy-data.json')).federation_publication_policy
  const satelliteClients = ['blob-service', 'did-service', 'issuer-service', 'kms-service', 'tenant-as-service', 'verifier-service']
  assert.deepEqual(services['platform.tenant.list-workloads'], satelliteClients)
  assert.deepEqual(services['platform.tenant.watch-invalidations'], satelliteClients)
  assert.deepEqual(services['model.element.scope'], ['issuer-service', 'verifier-service'])
  const connectorClients = ['issuer-service', 'tenant-as-service', 'verifier-service']
  for (const id of ['connector.attachment.resolve-bindings', 'connector.invocation-binding.list']) {
    assert.deepEqual(services[id], connectorClients)
    assert.ok(!Object.hasOwn(roles, id), `A human role must not authorize ${id}`)
  }
  for (const id of ['platform.tenant.list-workloads', 'platform.tenant.watch-invalidations', 'model.element.scope']) {
    assert.ok(!Object.hasOwn(roles, id), `A human role must not authorize ${id}`)
  }
})

test('publication PDP platform configuration inherits current base service settings', () => {
  const base = readConfig('compose/config/platform.application.yml').replaceAll('\r\n', '\n')
  const overlay = readConfig('compose/federation-publication-pdp/platform.application.yml').replaceAll('\r\n', '\n')
  assert.match(overlay, /^    default-engine: federation-publication-opa$/m)
  assert.match(overlay, /^        - oidfed\.entity-publication-work\.run$/m)
  assert.deepEqual(scalarConfig(overlay, ['authz', 'policy', 'engines', 'federation-publication-opa']), {
    type: 'opa',
    endpoint: 'http://federation-publication-pdp:8181',
    'policy-path': '/v1/data/sphereon/authz',
    'health-path': '/health',
  })
  const normalized = overlay
    .replace('    default-engine: federation-publication-opa\n', '    default-engine: federationadmin\n')
    .replace('        - oidfed.entity-publication-work.run\n', '')
    .replace(/^      federation-publication-opa:\n(?:        [^\n]+\n)+/m, '')
  assert.ok(normalized === base, 'The publication PDP overlay has drifted from the base platform configuration')
})

test('publication PDP selects exact tenant administration permissions for trust and VICAL', () => {
  const {role_rules: roleRules, service_rules: serviceRules, trust_admin_resources: resources,
    trust_source_refresh_worker_id: worker} =
    JSON.parse(readConfig('compose/federation-publication-pdp/federation-publication-policy-data.json')).federation_publication_policy

  assert.deepEqual(resources, {
    'trust.lote.create-draft': 'TrustDomainLoTE',
    'trust.lote.delete-provider': 'TrustDomainLoTE',
    'trust.lote.publish': 'TrustDomainLoTE',
    'trust.lote.upsert-provider': 'TrustDomainLoTE',
    'trust.lote.validate-draft': 'TrustDomainLoTE',
    'trust.mdoc-vical.manage': 'TrustSourceDomain',
    'trust.sources.activate': 'TrustSourceDomain',
    'trust.sources.manage': 'TrustSourceDomain',
    'trust.sources.refresh': 'TrustSourceDomain',
  })
  for (const action of Object.keys(resources)) {
    assert.ok(!Object.hasOwn(roleRules, action), `${action} must retain its typed resource and tenant checks`)
    assert.ok(!Object.hasOwn(serviceRules, action), `${action} must use the typed trust policy`)
  }
  const overlay = readConfig('compose/federation-publication-pdp/platform.application.yml')
  const refresh = scalarConfig(overlay, ['trust', 'sources', 'refresh', 'worker'])
  assert.equal(refresh.enabled, 'true')
  assert.equal(refresh['principal-id'], worker)
})
