import assert from 'node:assert/strict'
import {createServer} from 'node:http'
import {once} from 'node:events'
import {test} from 'node:test'
import fs from 'node:fs'
import {createHash} from 'node:crypto'
import {
  activateTenantOwner,
  bearerize,
  clientCredentialsToken,
  executedIdentities,
  instrumentRequests,
  mergeJunit,
  reconcileCoverage,
  requestLeaves,
  resolveTemplate,
  signInWithPkce,
  topLevelPhases,
} from './run-customer-postman-with-auth.mjs'
import {validateJunitText} from './compose-postman-release-gate-support.mjs'

const collection = JSON.parse(fs.readFileSync(new URL('../postman/EDK-Enterprise-Deployment.postman_collection.json', import.meta.url), 'utf8'))

function effectiveAuth(items, inherited = null, out = []) {
  for (const item of items ?? []) {
    if (Array.isArray(item.item)) effectiveAuth(item.item, item.auth ?? inherited, out)
    else out.push({name: item.name, auth: item.request?.auth ?? inherited})
  }
  return out
}

test('the shipped collection has one top-level folder per token, recognised by its OAuth2 settings', () => {
  const phases = topLevelPhases(collection)
  assert.deepEqual(phases.map((phase) => phase.role), ['operator', 'tenantOwner', 'serviceClient'])
  assert.equal(phases[0].settings.clientId, 'platform-operator-cli')
  assert.equal(phases[2].settings.grant_type, 'client_credentials')
  assert.ok(phases[2].settings.tokenRequestParams.some((param) => param.key === 'audience'))
})

test('bearerize gives every request that inherited a top-level OAuth2 token its bearer variable', () => {
  const before = effectiveAuth(collection.item)
  const after = effectiveAuth(bearerize(collection).item)
  assert.equal(after.length, before.length)
  let converted = 0
  for (let index = 0; index < before.length; index++) {
    const original = before[index].auth
    const current = after[index].auth
    if (original?.type === 'oauth2' && current?.type === 'bearer') {
      converted++
      assert.match(current.bearer[0].value, /^\{\{customerGate\w+Token\}\}$/u)
    } else {
      // Requests with their own auth and the nested wallet OAuth2 folder keep what they had.
      assert.deepEqual(current, original, `${before[index].name} must keep its own auth`)
    }
  }
  assert.ok(converted > 80, `expected most requests to use a folder token, got ${converted}`)
  assert.ok(effectiveAuth(bearerize(collection).item).some((entry) => entry.auth?.type === 'oauth2'),
    'the optional Keycloak wallet folder keeps its own OAuth2 configuration')
  assert.equal(JSON.stringify(bearerize(collection)).includes('"type":"oauth2","oauth2":[{"key":"tokenName","value":"Platform operator"'), false)
})

test('coverage separates optional self-skips from required ones and rejects unknown requests', () => {
  const leaves = requestLeaves(collection)
  assert.equal(leaves.length, 122)
  const required = leaves.filter((leaf) => !leaf.optional).map((leaf) => leaf.identity)
  const full = reconcileCoverage(leaves, required)
  assert.equal(full.skippedRequired.length, 0)
  assert.equal(full.executed, required.length)
  const partial = reconcileCoverage(leaves, required.slice(1))
  assert.deepEqual(partial.skippedRequired, [required[0]])
  assert.throws(() => reconcileCoverage(leaves, ['Not > A > Request']), /not part of the collection/u)
})

test('instrumented requests are recognised in JUnit, and merged JUnit passes the gate validator', () => {
  const instrumented = instrumentRequests(collection)
  const first = instrumented.item[0].item[0].item[0]
  assert.ok(first.event.some((event) => event.script.exec[0].startsWith("pm.test('__executed_request__ 1. Platform operator > Tenants > 1. List tenants'")))
  const suite = (name, cases) => `<?xml version="1.0" encoding="UTF-8"?>\n<testsuites name="x" tests="${cases.length}" failures="0" errors="0" time="0.1">\n` +
    `<testsuite name="${name}" tests="${cases.length}" failures="0" errors="0" time="0.1">${cases.map((c) => `<testcase name="${c}" classname="x" time="0.001"/>`).join('')}</testsuite>\n</testsuites>\n`
  const phaseOne = suite('single-tenant', ['__executed_request__ 1. Platform operator &gt; Tenants &gt; 1. List tenants', 'HTTP 200'])
  const phaseTwo = suite('single-tenant', ['__executed_request__ 2. Tenant owner: create a service client &gt; 1. List authorization servers'])
  assert.deepEqual(executedIdentities(phaseOne), ['1. Platform operator > Tenants > 1. List tenants'])
  const merged = mergeJunit([phaseOne, phaseTwo], 'EDK')
  const result = validateJunitText(merged)
  assert.equal(result.tests, 3)
  assert.equal(result.suites, 2)
})

test('resolveTemplate fills placeholders and refuses empty values', () => {
  const lookup = (name) => ({tenantSlug: 'acme', baseDomain: 'example.com', empty: ''})[name]
  assert.equal(resolveTemplate('https://{{tenantSlug}}.{{baseDomain}}/as/{{tenantSlug}}/token', lookup), 'https://acme.example.com/as/acme/token')
  assert.throws(() => resolveTemplate('{{empty}}', lookup), /\{\{empty\}\}/u)
  assert.throws(() => resolveTemplate('{{missing}}', lookup), /\{\{missing\}\}/u)
})

async function startAuthorizationServer() {
  const seen = {}
  const server = createServer(async (request, response) => {
    const chunks = []
    for await (const chunk of request) chunks.push(chunk)
    const body = Buffer.concat(chunks).toString('utf8')
    const url = new URL(request.url, 'http://stub')
    const base = `http://127.0.0.1:${server.address().port}`
    const redirect = (location, cookie) => {
      response.writeHead(302, {location, ...(cookie ? {'set-cookie': cookie} : {})})
      response.end()
    }
    const json = (status, value) => {
      response.writeHead(status, {'content-type': 'application/json'})
      response.end(JSON.stringify(value))
    }
    if (url.pathname === '/as/acme/authorize') {
      seen.authorize = Object.fromEntries(url.searchParams)
      return redirect(`/as/acme/login?session_id=s1&return_url=${encodeURIComponent(`${base}/as/acme/authorize/callback?session_id=s1`)}`, 'csrf=abc; Path=/; HttpOnly')
    }
    if (url.pathname === '/as/acme/login' && request.method === 'GET') {
      seen.loginCookie = request.headers.cookie
      response.writeHead(200, {'content-type': 'text/html'})
      return response.end('<input type="hidden" name="tab_id" value="t1"><input type="hidden" name="session_code" value="c1">')
    }
    if (url.pathname === '/as/acme/login' && request.method === 'POST') {
      seen.login = Object.fromEntries(new URLSearchParams(body))
      if (seen.login.password !== 'right-password') return redirect(`${seen.authorize.redirect_uri}?error=invalid_credentials`)
      return redirect(`${base}/as/acme/authorize/callback?session_id=s1`)
    }
    if (url.pathname === '/as/acme/authorize/callback') {
      return redirect(`${seen.authorize.redirect_uri}?code=the-code&state=${seen.authorize.state}`)
    }
    if (url.pathname === '/as/acme/token') {
      const form = new URLSearchParams(body)
      seen.token = {grantType: form.get('grant_type'), audiences: form.getAll('audience'), form: Object.fromEntries(form)}
      if (form.get('grant_type') === 'authorization_code') {
        const challenge = createHash('sha256').update(form.get('code_verifier')).digest('base64url')
        if (challenge !== seen.authorize.code_challenge || form.get('code') !== 'the-code') return json(400, {error: 'invalid_grant'})
      }
      return json(200, {access_token: `${form.get('grant_type')}-token`})
    }
    if (url.pathname === '/api/account-actions/v1/complete') {
      seen.activation = JSON.parse(body)
      return json(200, {})
    }
    return json(404, {})
  })
  server.listen(0, '127.0.0.1')
  await once(server, 'listening')
  return {base: `http://127.0.0.1:${server.address().port}`, seen, close: () => new Promise((resolve) => server.close(resolve))}
}

test('signInWithPkce follows the hosted login flow and proves the PKCE verifier', async () => {
  const as = await startAuthorizationServer()
  try {
    const token = await signInWithPkce({
      authUrl: `${as.base}/as/acme/authorize`, tokenUrl: `${as.base}/as/acme/token`, clientId: 'developer-postman',
      redirectUri: 'https://oauth.pstmn.io/v1/browser-callback', scope: 'openid profile email',
      username: 'admin@acme.example', password: 'right-password',
    })
    assert.equal(token, 'authorization_code-token')
    assert.equal(as.seen.authorize.code_challenge_method, 'S256')
    assert.equal(as.seen.loginCookie, 'csrf=abc')
    assert.deepEqual(
      {username: as.seen.login.username, session_id: as.seen.login.session_id, tab_id: as.seen.login.tab_id, session_code: as.seen.login.session_code},
      {username: 'admin@acme.example', session_id: 's1', tab_id: 't1', session_code: 'c1'},
    )
    await assert.rejects(signInWithPkce({
      authUrl: `${as.base}/as/acme/authorize`, tokenUrl: `${as.base}/as/acme/token`, clientId: 'developer-postman',
      redirectUri: 'https://oauth.pstmn.io/v1/browser-callback', scope: 'openid',
      username: 'admin@acme.example', password: 'wrong',
    }), /invalid credentials/u)
  } finally {
    await as.close()
  }
})

test('client credentials sends the folder audiences, and owner activation posts the link token', async () => {
  const as = await startAuthorizationServer()
  try {
    const token = await clientCredentialsToken({
      tokenUrl: `${as.base}/as/acme/token`, clientId: 'svc', clientSecret: 'secret',
      params: [{key: 'audience', value: 'enterprise-platform'}, {key: 'audience', value: 'enterprise-issuer'}, {key: 'audience', value: 'off', enabled: false}],
    })
    assert.equal(token, 'client_credentials-token')
    assert.deepEqual(as.seen.token.audiences, ['enterprise-platform', 'enterprise-issuer'])
    assert.equal(as.seen.token.form.client_secret, 'secret')
    await activateTenantOwner(`${as.base}/as/acme/account-action#36%3Aabc`, 'Owner-Passw0rd')
    assert.deepEqual(as.seen.activation, {token: '36:abc', password: 'Owner-Passw0rd'})
  } finally {
    await as.close()
  }
})
