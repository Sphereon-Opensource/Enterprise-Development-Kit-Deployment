import test from 'node:test'
import assert from 'node:assert/strict'
import {readFileSync} from 'node:fs'
import {renderFederationGateway} from '../render-federation-gateway.mjs'

function block(source, name) {
  const match = source.replaceAll('\r\n', '\n').match(new RegExp(`^    ${name}:\\n([\\s\\S]*?)(?=^    [a-zA-Z0-9_-]+:|^  [a-zA-Z0-9_-]+:|$(?![\\s\\S]))`, 'm'))
  assert.ok(match, `Missing router ${name}`)
  return match[1]
}
for (const filename of ['dynamic.federation.template.yml', 'dynamic.public-cert.template.yml', 'dynamic.letsencrypt.template.yml', 'dynamic.yml']) {
  test(`${filename}: platform party API reaches tenant AS without moving other platform APIs`, () => {
    const source = readFileSync(new URL(`../../compose/gateway/traefik/${filename}`, import.meta.url), 'utf8')
    const party = block(source, 'platform-party')
    const platform = block(source, 'platform')
    assert.match(party, /Host\(`platform\.[^`]+`\) && PathRegexp\(`\^\/api\/party\/v1\(\/\.\*\)\?\$`\)/)
    assert.match(party, /service: svc-as/)
    assert.ok(Number(party.match(/priority: (\d+)/)[1]) > Number(platform.match(/priority: (\d+)/)[1]))
    assert.doesNotMatch(party, /middlewares:|replacePath|stripPrefix/)
    assert.match(platform, /service: svc-platform/)
    assert.doesNotMatch(platform, /PathPrefix|PathRegexp/)
    const rule = party.match(/PathRegexp\(`([^`]+)`\)/)[1]
    const paths = new RegExp(rule)
    for (const path of ['/api/party/v1', '/api/party/v1/organizations']) assert.ok(paths.test(path))
    for (const path of ['/api/party/v10', '/api/party/v1other', '/api/oauth2/v1/authorize', '/api/platform/config/v1', '/api/tenants/t/federations/f/admin/v1']) assert.ok(!paths.test(path), path)
    const service = source.replaceAll('\r\n', '\n').match(/^    svc-as:\n([\s\S]*?)(?=^    [a-zA-Z0-9_-]+:|$(?![\s\S]))/m)?.[1]
    assert.ok(service)
    assert.match(service, /passHostHeader: true/)
  })
}
test('federation renderer preserves platform party priority and host through edge mode', () => {
  for (const behindEdge of [false, true]) {
    const source = renderFederationGateway({baseDomain: 'fed.example.com', behindEdge})
    const party = block(source, 'platform-party')
    assert.ok(party.includes('Host(`platform.fed.example.com`)'))
    assert.match(party, /service: svc-as/)
    assert.match(party, /priority: 1100/)
    assert.ok(party.includes(behindEdge ? 'entryPoints: ["web"]' : 'entryPoints: ["websecure"]'))
  }
})
