import assert from 'node:assert/strict'
import fs from 'node:fs'
import test from 'node:test'
import vm from 'node:vm'

import {normalizeEnvironment, reconcileCoverage} from './run-customer-postman-with-auth.mjs'

test('customer coverage deduplicates repeated executions and skips optional gaps', () => {
  const projected = [
    {identity: '01 > required', optional: false},
    {identity: '02 > optional', optional: true},
    {identity: '03 > repeated', optional: false},
  ]
  const coverage = reconcileCoverage(projected, ['__executed_request__ 01 > required', '__executed_request__ 03 > repeated', '__executed_request__ 03 > repeated'])
  assert.deepEqual(coverage, {
    projectedPublicRequests: 3, executedPublicRequests: 2, skippedOptionalRequests: 1, repeatedPublicExecutions: 1,
    publicRequestIdentities: ['01 > required', '03 > repeated'], skippedOptionalRequestIdentities: ['02 > optional'],
    repeatedPublicRequestIdentities: [{identity: '03 > repeated', count: 2}],
  })
})

test('customer coverage rejects missing nonoptional leaves', () => {
  assert.throws(() => reconcileCoverage([{identity: 'required', optional: false}], []), /Missing nonoptional public request/)
})

test('customer coverage rejects execution identities absent from projection', () => {
  assert.throws(() => reconcileCoverage([{identity: 'required', optional: false}], ['__executed_request__ drifted']), /not projected/)
})

test('customer coverage classifies Optional scenario guard descriptions as optional', () => {
  const source = fs.readFileSync(new URL('./run-customer-postman-with-auth.mjs', import.meta.url), 'utf8')
  assert.match(source, /Optional scenario guard/)
  assert.deepEqual(reconcileCoverage([{identity: 'guarded', optional: true}], []), {
    projectedPublicRequests: 1, executedPublicRequests: 0, skippedOptionalRequests: 1, repeatedPublicExecutions: 0,
    publicRequestIdentities: [], skippedOptionalRequestIdentities: ['guarded'], repeatedPublicRequestIdentities: [],
  })
})

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

test('customer auth removes stale Acme routing before owner discovery and preserves inputs', () => {
  const environment = {
    values: [
      {key: 'baseDomain', value: 'example.com', enabled: true},
      {key: 'tenantSubdomain', value: 'diag06cust1690922', enabled: true},
      {key: 'tenantSlug', value: 'acme', enabled: true},
      {key: 'tenantHost', value: 'acme.example.com', enabled: true},
      {key: 'tenantGatewayUrl', value: 'https://acme.example.com', enabled: true},
      {key: 'keycloakIssuer', value: 'https://identity.example.com/realms/customer', enabled: true},
      {key: 'enableKeycloakWalletProxy', value: 'true', enabled: true},
      {key: 'walletProofJwt', value: 'private-proof', enabled: true, type: 'secret'},
    ],
  }
  const normalized = normalizeEnvironment(environment)
  const environmentValues = new Map(normalized.values.map((entry) => [entry.key, entry.value]))
  for (const key of ['tenantSlug', 'tenantHost', 'tenantGatewayUrl']) assert.equal(environmentValues.has(key), false, `${key} must not shadow collection routing`)
  for (const [key, value] of [
    ['baseDomain', 'example.com'],
    ['tenantSubdomain', 'diag06cust1690922'],
    ['keycloakIssuer', 'https://identity.example.com/realms/customer'],
    ['enableKeycloakWalletProxy', 'true'],
    ['walletProofJwt', 'private-proof'],
  ]) assert.equal(environmentValues.get(key), value, `${key} must remain available to the walkthrough`)

  const collection = JSON.parse(fs.readFileSync(new URL('../postman/EDK-Enterprise-Deployment.postman_collection.json', import.meta.url), 'utf8'))
  const sourceCollection = JSON.parse(fs.readFileSync(new URL('../../../deploy/edk/e2e/postman/EDK-Enterprise-Deployment.walkthrough-source.postman_collection.json', import.meta.url), 'utf8'))
  const collectionVariables = new Map((collection.variable ?? []).map((entry) => [entry.key, entry.value]))
  const store = (map) => ({
    get: (key) => map.get(key),
    set: (key, value) => map.set(key, value),
    unset: (key) => map.delete(key),
  })
  const requests = []
  const pm = {
    environment: store(environmentValues),
    collectionVariables: store(collectionVariables),
    variables: {get: (key) => environmentValues.get(key) ?? collectionVariables.get(key)},
    sendRequest: (request, callback) => {
      requests.push(request)
      callback(null, {code: 200, json: () => ({authorization_endpoint: 'https://diag06cust1690922.example.com/as/diag/authorize'})})
    },
  }
  const cryptoJs = {
    enc: {Base64: {}},
    lib: {WordArray: {random: () => ({toString: () => 'verifier'})}},
    SHA256: () => ({toString: () => 'challenge'}),
  }
  const rootScript = collection.event.find((event) => event.listen === 'prerequest').script.exec.join('\n')
  vm.runInNewContext(rootScript, {pm, CryptoJS: cryptoJs})
  assert.equal(collectionVariables.get('tenantGatewayUrl'), 'https://diag06cust1690922.example.com')

  const ownerFolder = sourceCollection.item.find((item) => item.name === '03 Tenant Owner Activation and Sign-in')
  const ownerAuthorization = ownerFolder.item.find((item) => item.name === '03 Start tenant owner authorization')
  const ownerScript = ownerAuthorization.event.find((event) => event.listen === 'prerequest').script.exec.join('\n')
  vm.runInNewContext(ownerScript, {pm, CryptoJS: cryptoJs})
  assert.equal(requests[0].url, 'https://diag06cust1690922.example.com/.well-known/openid-configuration')
})
