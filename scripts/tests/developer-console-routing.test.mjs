import test from 'node:test'
import assert from 'node:assert/strict'
import {readFileSync} from 'node:fs'
import {renderFederationGateway} from '../render-federation-gateway.mjs'

const source = readFileSync(new URL('../../compose/gateway/traefik/dynamic.yml', import.meta.url), 'utf8')

function rewrite(name, path) {
  const middleware = source.split(`    ${name}:`)[1]
  const expression = new RegExp(JSON.parse(middleware.match(/regex: (".*")/)[1]))
  const replacement = JSON.parse(middleware.match(/replacement: (".*")/)[1])
  return path.replace(expression, replacement)
}

test('Developer Console page rewrite preserves the root and callback slash shape', () => {
  for (const suffix of ['', '/oauth/callback', '/bff/oauth/callback']) {
    assert.equal(rewrite('developer-console-page-rewrite', `/developer-console${suffix}`),
      `/admin-console/developer-console${suffix}`,
      'the root must not gain a trailing slash that redirects to the internal mount')
  }
})

test('Developer Console page routing stays exact and API paths retain their separate rewrite', () => {
  const page = source.split('    developer-console-page:')[1].split('    developer-journeys-artifact:')[0]
  assert.ok(page.includes('Path(`/developer-console`)'))
  assert.ok(page.includes('Path(`/developer-console/oauth/callback`)'))
  assert.ok(!page.includes('PathPrefix(`/developer-console`)'))
  assert.equal(rewrite('developer-console-api-rewrite', '/developer-console/api/developer-console/v1/catalog'),
    '/admin-console/api/developer-console/v1/catalog')
})

const portalRouters = [
  'instance-testing-console-page', 'instance-testing-console-api', 'instance-testing-console-support',
  'developer-console-page', 'developer-journeys-artifact', 'developer-console-api',
  'developer-console-api-bearer', 'tenant-developer-console-api', 'developer-console-auth',
]

function blocks(source, section) {
  const body = source.replaceAll('\r\n', '\n').split(`  ${section}:\n`)[1].split(/^  \w+:/m)[0]
  return Object.fromEntries([...body.matchAll(/^    ([\w-]+):\n([\s\S]*?)(?=^    [\w-]+:|$(?![\s\S]))/gm)]
    .map(([, name, value]) => [name, value]))
}

function routeMatches(block, {host, path, method = 'GET', authorization = ''}) {
  const rule = block.match(/rule: >-\n([\s\S]*?)(?=      entryPoints:)/)?.[1].trim()
    ?? JSON.parse(block.match(/rule: (".*")/)[1])
  const expression = rule.replace(/`([^`]+)`/g, (_, value) => JSON.stringify(value))
  return Function('Host', 'HostRegexp', 'Path', 'PathPrefix', 'PathRegexp', 'Method', 'HeaderRegexp',
    `return (${expression})`)(
    value => host === value, value => new RegExp(value).test(host),
    value => path === value, value => path.startsWith(value), value => new RegExp(value).test(path),
    value => method === value, (name, value) => name === 'Authorization' && new RegExp(value).test(authorization))
}

function routed(source, request) {
  return Object.entries(blocks(source, 'routers'))
    .filter(([, block]) => routeMatches(block, request))
    .sort((a, b) => Number(b[1].match(/priority: (\d+)/)[1]) - Number(a[1].match(/priority: (\d+)/)[1]))[0]
}

function forwardedPath(source, block, path) {
  const names = JSON.parse(block.match(/middlewares: (\[.*\])/).at(1))
  for (const name of names) {
    const middleware = blocks(source, 'middlewares')[name]
    if (middleware.includes('addPrefix:')) path = middleware.match(/prefix: (.*)/)[1] + path
    else path = path.replace(new RegExp(JSON.parse(middleware.match(/regex: (".*")/)[1])),
      JSON.parse(middleware.match(/replacement: (".*")/)[1]))
  }
  return path
}

for (const behindEdge of [false, true]) {
  test(`federation portals preserve tenant routing and rewrites (behindEdge=${behindEdge})`, () => {
    const source = renderFederationGateway({baseDomain: 'fed.example.com', withAdminConsole: true, behindEdge})
    const host = 'tenant.fed.example.com'
    const routes = blocks(source, 'routers')
    for (const name of portalRouters) {
      assert.ok(routes[name], name)
      assert.ok(routes[name].includes(behindEdge ? 'entryPoints: ["web"]' : 'entryPoints: ["websecure"]'), name)
      assert.equal(routes[name].includes('tls: {}'), !behindEdge, name)
      assert.ok(!routeMatches(routes[name], {host: 'other.example.com', path: '/developer-console'}), name)
    }
    const paths = [
      ['instance-testing-console-page', '/testing-console/issuer/issuer-id', '/admin-console/testing-console/issuer/issuer-id'],
      ['instance-testing-console-page', '/testing-console/verifier/verifier-id/', '/admin-console/testing-console/verifier/verifier-id/'],
      ['instance-testing-console-api', '/testing-console/api/oid4vci/v1/testing/issuer-id', '/admin-console/api/oid4vci/v1/testing/issuer-id'],
      ['instance-testing-console-api', '/testing-console/api/oid4vp/v1/testing/verifier-id', '/admin-console/api/oid4vp/v1/testing/verifier-id'],
      ['instance-testing-console-api', '/testing-console/api/portal-oauth/callback', '/admin-console/api/portal-oauth/callback'],
      ['developer-console-page', '/developer-console', '/admin-console/developer-console'],
      ['developer-console-page', '/developer-console/oauth/callback', '/admin-console/developer-console/oauth/callback'],
      ['developer-journeys-artifact', '/developer-journeys/index.json', '/admin-console/developer-journeys/index.json'],
      ['developer-console-api', '/developer-console/api/developer-console/v1/catalog', '/admin-console/api/developer-console/v1/catalog'],
      ...['session', 'login', 'token', 'logout', 'callback'].map(op =>
        ['developer-console-auth', `/developer-console/api/auth/${op}`, `/admin-console/api/developer-console-auth/${op}`]),
    ]
    for (const [name, path, forwarded] of paths) {
      const [selected, block] = routed(source, {host, path})
      assert.equal(selected, name, path)
      assert.match(block, /service: svc-admin-console-tenant/)
      assert.equal(forwardedPath(source, block, path), forwarded)
      assert.equal(routed(source, {host: 'platform.fed.example.com', path})[0], 'platform', path)
    }
    for (const path of ['/testing-console/admin/id', '/testing-console/issuer/id/extra',
      '/developer-console/api/platform/admin/v1', '/developer-console/api/auth/unknown', '/developer-console/extra']) {
      assert.ok(!portalRouters.some(name => routeMatches(routes[name], {host, path})), path)
    }
    for (const path of ['/admin-console/_next/static/app.js', '/admin-console/public/assets/logo.png',
      '/admin-console/health', '/admin-console/api/portal-oauth/callback']) {
      assert.ok(routeMatches(routes['instance-testing-console-support'], {host, path}), path)
      assert.match(routed(source, {host, path})[1], /service: svc-admin-console-tenant/)
    }
    assert.ok(!routeMatches(routes['instance-testing-console-support'], {host, path: '/admin-console/api/platform/admin/v1'}))
    const middlewares = blocks(source, 'middlewares')
    for (const name of portalRouters) {
      const names = routes[name].match(/middlewares: (\[.*\])/)
      if (names) for (const name of JSON.parse(names[1])) assert.ok(middlewares[name], name)
    }
    const services = blocks(source, 'services')
    assert.match(services['svc-admin-console-tenant'], /passHostHeader: true/)
    assert.match(services['svc-admin-console-tenant'], /http:\/\/admin-console-tenant:3000/)
    assert.match(services['svc-platform'], /passHostHeader: true/)
    assert.match(routes['platform-admin-console'], /priority: 1100/)
    assert.equal(routed(source, {host: 'platform.fed.example.com', path: '/admin-console/health'})[0], 'platform-admin-console')
  })

  test(`federation bearer reads reach backend while session writes stay on BFF (behindEdge=${behindEdge})`, () => {
    const source = renderFederationGateway({baseDomain: 'fed.example.com', withAdminConsole: true, behindEdge})
    const host = 'tenant.fed.example.com'
    for (const endpoint of ['bootstrap', 'catalog', 'related-surfaces', 'specs/spec-id', 'artifacts/postman/collection', 'artifacts/postman/environment']) {
      for (const method of ['GET', 'HEAD']) {
        const path = `/developer-console/api/developer-console/v1/${endpoint}`
        const [name, block] = routed(source, {host, path, method, authorization: 'Bearer token'})
        assert.equal(name, 'developer-console-api-bearer')
        assert.match(block, /service: svc-platform/)
        assert.equal(forwardedPath(source, block, path), `/api/developer-console/v1/${endpoint}`)
        const [directName, direct] = routed(source, {host, path: `/api/developer-console/v1/${endpoint}`, method})
        assert.equal(directName, 'tenant-developer-console-api')
        assert.match(direct, /service: svc-platform/)
        assert.doesNotMatch(direct, /middlewares:/)
        assert.equal(routed(source, {host, path, method})[0], 'developer-console-api')
      }
    }
    for (const path of ['/developer-console/api/developer-console/v1/bff', '/developer-console/api/developer-console/v1/catalog']) {
      const [name, block] = routed(source, {host, path, method: 'POST', authorization: 'Bearer token'})
      assert.equal(name, 'developer-console-api')
      assert.match(block, /service: svc-admin-console-tenant/)
    }
    assert.equal(routed(source, {host, path: '/api/developer-console/v1/bff', method: 'POST'}), undefined)
  })
}

test('federation portals and middleware disappear with the admin console profile disabled', () => {
  for (const withVdxServices of [false, true]) {
    const source = renderFederationGateway({baseDomain: 'fed.example.com', withVdxServices})
    for (const name of portalRouters) assert.ok(!source.includes(`    ${name}:`), name)
    assert.doesNotMatch(source, /svc-admin-console|testing-console|developer-console|developer-journeys/)
    const middlewares = blocks(source, 'middlewares')
    for (const block of Object.values(blocks(source, 'routers'))) {
      const names = block.match(/middlewares: (\[.*\])/)
      if (names) for (const name of JSON.parse(names[1])) assert.ok(middlewares[name], name)
    }
  }
})
