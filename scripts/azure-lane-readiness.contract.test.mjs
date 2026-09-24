#!/usr/bin/env node

import assert from 'node:assert/strict'
import {readFileSync} from 'node:fs'
import {dirname, join, resolve} from 'node:path'
import {fileURLToPath} from 'node:url'
import test from 'node:test'

const scriptDir = dirname(fileURLToPath(import.meta.url))
const customerRoot = resolve(scriptDir, '..')
const repoRoot = resolve(customerRoot, '..', '..')
const wrapper = readFileSync(join(scriptDir, 'run-compose-postman-release-gate.ps1'), 'utf8')
const support = readFileSync(join(scriptDir, 'compose-postman-release-gate-support.mjs'), 'utf8')
const e2eWrapper = readFileSync(join(repoRoot, 'deploy', 'edk', 'e2e', 'scripts', 'run-e2e.ps1'), 'utf8')

test('customer Azure provider lane gates vault credentials separately from BYOK/BYOC references', () => {
  const readiness = wrapper.match(/\$azureKmsEnvNames\s*=\s*@\(([^)]*)\)/u)?.[1]
  assert.ok(readiness, 'the runner must declare an explicit Azure readiness input set')
  assert.deepEqual(
    [...readiness.matchAll(/'([^']+)'/gu)].map((match) => match[1]),
    ['AZURE_KEYVAULT_URL', 'AZURE_KEYVAULT_TENANT_ID', 'AZURE_KEYVAULT_CLIENT_ID', 'AZURE_KEYVAULT_CLIENT_SECRET'],
    'the customer Azure provider-configuration lane requires its four vault credentials',
  )
  assert.doesNotMatch(readiness, /AZURE_HSM_KEY_NAME|AZURE_CERT_NAME/u,
    'optional key/certificate aliases are not provider-credential readiness inputs')
  assert.match(wrapper, /Readiness requires the four\s+#\s+AZURE_KEYVAULT_\* credential variables checked below/u)
  assert.match(support, /all four AZURE_KEYVAULT_\* provider\s+\*?\s*credentials are present/u)
})

test('external customer BYOK/BYOC cycle requires its distinct existing-key and certificate inputs', () => {
  assert.ok(e2eWrapper.includes("'EDK_AZURE_TEST_EXISTING_KEY_ALIAS'"))
  assert.ok(e2eWrapper.includes("'EDK_AZURE_TEST_CERTIFICATE_DER_BASE64'"))
})
