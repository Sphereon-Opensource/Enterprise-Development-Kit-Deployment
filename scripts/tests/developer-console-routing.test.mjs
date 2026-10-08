import test from 'node:test'
import assert from 'node:assert/strict'
import {readFileSync} from 'node:fs'

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
