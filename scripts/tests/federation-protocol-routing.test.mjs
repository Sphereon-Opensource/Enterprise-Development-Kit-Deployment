import test from 'node:test'
import assert from 'node:assert/strict'
import {readFileSync} from 'node:fs'
import {renderFederationGateway} from '../render-federation-gateway.mjs'

function router(source, name) {
  const match = source.replaceAll('\r\n', '\n').match(new RegExp(`^    ${name}:\\n([\\s\\S]*?)(?=^    [a-zA-Z0-9_-]+:|^  [a-zA-Z0-9_-]+:|$(?![\\s\\S]))`, 'm'))
  assert.ok(match, `Missing router ${name}`)
  return match[1]
}

function checkFederationPaths(source) {
  const fallback = router(source, 'tenant-oidfed-path')
  const paths = new RegExp(fallback.match(/PathRegexp\(`([^`]+)`\)/)[1])
  assert.match(fallback, /HostRegexp\(`/)
  assert.match(fallback, /service: svc-platform/)
  assert.doesNotMatch(fallback, /middlewares:|replacePath|stripPrefix/)
  const suffixes = [
    '/.well-known/openid-federation', '/federation_fetch', '/federation_list',
    '/federation_resolve', '/federation_trust_mark_status', '/federation_trust_mark_list',
    '/federation_trust_mark', '/federation_historical_keys', '/federation_enrollment',
    '/federation_enrollment_invitation', '/federation_trust_mark_application',
    ...['status', 'response', 'withdrawal', 'keys'].map(op => `/federation_enrollment/application-id/${op}`),
    ...['status', 'response', 'withdrawal'].map(op => `/federation_trust_mark_application/application-id/${op}`),
  ]
  for (let depth = 0; depth <= 6; depth++) {
    const prefix = '/entity'.repeat(depth)
    for (const suffix of suffixes) assert.ok(paths.test(prefix + suffix), prefix + suffix)
  }
  for (const path of [
    '/entity'.repeat(7) + '/.well-known/openid-federation', '/.well-known/openid-federation/entity',
    '/federation/.well-known/openid-federation/extra', '/federation_fetch_extra',
    '/federation_enrollment/application-id/delete', '/federation_trust_mark_application/application-id/keys',
    '/admin/v1/configuration', '/api/platform/config/v1/tenants/t', '/as/org/authorize',
    '/oid4vci/issuer/credential', '/oid4vp/verifier/authorize', '/federation_registration',
  ]) assert.ok(!paths.test(path), path)

  // Service-owned protocol paths still reach their owning federation adapters.
  const priority = Number(fallback.match(/priority: (\d+)/)[1])
  for (const name of ['tenant-as', 'tenant-issuer', 'tenant-verifier']) {
    if (!source.includes(`    ${name}:`)) continue
    assert.ok(priority < Number(router(source, name).match(/priority: (\d+)/)[1]), name)
  }
}

for (const filename of ['dynamic.federation.template.yml', 'dynamic.public-cert.template.yml', 'dynamic.letsencrypt.template.yml', 'dynamic.yml']) {
  test(`${filename}: path-based federation publication and enrollment retain service ownership`, () => {
    const source = readFileSync(new URL(`../../compose/gateway/traefik/${filename}`, import.meta.url), 'utf8')
    checkFederationPaths(source)
    if (filename.includes('letsencrypt')) assert.match(router(source, 'tenant-oidfed-path'), /certResolver: le/)
  })
}

test('rendered federation gateway preserves fallback routing through TLS and edge modes', () => {
  for (const behindEdge of [false, true]) {
    const source = renderFederationGateway({baseDomain: 'fed.example.com', withVdxServices: true, behindEdge})
    checkFederationPaths(source)
    const fallback = router(source, 'tenant-oidfed-path')
    assert.ok(fallback.includes('^[a-z0-9-]+\\.fed\\.example\\.com$'))
    assert.ok(fallback.includes(behindEdge ? 'entryPoints: ["web"]' : 'entryPoints: ["websecure"]'))
    assert.match(router(source, 'tenant-oidfed'), /priority: 230/)
  }
})
