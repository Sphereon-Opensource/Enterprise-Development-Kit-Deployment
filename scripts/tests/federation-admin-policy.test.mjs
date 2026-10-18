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
