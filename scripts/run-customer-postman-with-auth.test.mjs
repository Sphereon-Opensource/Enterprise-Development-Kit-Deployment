import assert from 'node:assert/strict'
import fs from 'node:fs'
import test from 'node:test'

const source = fs.readFileSync(new URL('./run-customer-postman-with-auth.mjs', import.meta.url), 'utf8')

test('customer adapter routes issuance credential requests through walletAccessToken', () => {
  assert.match(source, /walletCredentialRequest\s*=\s*top\.startsWith\('03 Tenant application'\)/)
  assert.match(source, /walletCredentialRequest \? 'walletAccessToken' : 'tenantAccessToken'/)
  assert.match(source, /Issue transaction-code EuPid credential/)
})

test('customer adapter keeps subtenant administration on platformAccessToken', () => {
  assert.match(source, /top\.startsWith\('05 Subtenants'\)/)
  assert.match(source, /top\.startsWith\('05 Subtenants'\) \? 'platformAccessToken'/)
})
