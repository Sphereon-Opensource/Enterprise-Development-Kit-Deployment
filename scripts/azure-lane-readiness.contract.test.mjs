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

test('the platform Azure provider environment is set before Compose starts the stack', () => {
  const normalized = wrapper.replaceAll('\r\n', '\n')
  const laneFunction = normalized.indexOf('\nfunction Set-AzureKmsLaneEnvironment {')
  assert.ok(laneFunction >= 0, 'the runner must keep the Azure lane in its own function')
  const laneBody = normalized.slice(laneFunction, normalized.indexOf('\n}', laneFunction + 1))
  assert.match(laneBody, /\$env:EDK_PLATFORM_KMS_AZURE_CLIENT_SECRET/u)
  assert.match(laneBody, /\$env:EDK_SECRET_MANAGEMENT_ENVIRONMENT_MANIFEST =/u)
  const optionalStart = normalized.indexOf('\nfunction Set-OptionalLaneEnvironment {')
  const optionalBody = normalized.slice(optionalStart, normalized.indexOf('\n}', optionalStart + 1))
  assert.doesNotMatch(optionalBody, /EDK_PLATFORM_KMS_AZURE|EDK_SECRET_MANAGEMENT_ENVIRONMENT_MANIFEST/u,
    'the platform Azure environment must not wait for the Newman lane values')
  const call = normalized.indexOf('\nSet-AzureKmsLaneEnvironment\n')
  const composeUp = normalized.indexOf("Invoke-Compose @('up'")
  assert.ok(call >= 0, 'the runner must configure the Azure lane at script level')
  assert.ok(composeUp >= 0, 'the runner must start Compose')
  assert.ok(call < composeUp, 'the Azure lane must be configured before Compose starts the platform')
})
