import test from 'node:test'
import assert from 'node:assert/strict'
import {mkdtempSync, readFileSync, rmSync} from 'node:fs'
import {spawnSync} from 'node:child_process'
import {tmpdir} from 'node:os'
import path from 'node:path'
import {fileURLToPath} from 'node:url'
import {renderInboxGateway} from '../render-inbox-gateway.mjs'

const kit = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')
const read = file => readFileSync(path.join(kit, file), 'utf8')
const traefik = 'compose/gateway/traefik/'

function router(source, name) {
  const match = source.replaceAll('\r\n', '\n').match(new RegExp(`^    ${name}:\\n([\\s\\S]*?)(?=^    [a-zA-Z0-9_-]+:|^  [a-zA-Z0-9_-]+:|$(?![\\s\\S]))`, 'm'))
  assert.ok(match, `Missing router ${name}`)
  return match[1]
}

test('adds only the Inbox router and service to the base table', () => {
  const base = read(traefik + 'dynamic.yml')
  const rendered = renderInboxGateway(base, 'saas.localtest.me')
  assert.equal(rendered.split('# Traefik dynamic configuration:').length - 1, 1)
  assert.ok(rendered.length < base.length + 1000, 'the renderer duplicated the routing table')
  const inbox = router(rendered, 'inbox-api')
  assert.match(inbox, /HostRegexp\(`\^\[a-z0-9-\]\+\\\.saas\\\.localtest\\\.me\$`\) &&/)
  assert.match(inbox, /PathPrefix\(`\/api\/inbox\/v1`\)/)
  assert.match(inbox, /service: svc-inbox/)
  assert.match(inbox, /entryPoints: \["websecure"\]/)
  assert.match(inbox, /tls: \{\}/)
  assert.match(router(rendered, 'svc-inbox'), /url: "http:\/\/vdx-inbox:8080"/)
  assert.doesNotMatch(rendered, /enterprise-portal|enterprise-workflow|\/api\/portal\/v1|journey-/)
  // Everything outside the two inserted blocks is the base table unchanged.
  const stripped = rendered
    .replace(/    # Tenant Inbox API \(optional Inbox overlay\)\.\n    inbox-api:\n[\s\S]*?\n\n/, '')
    .replace(/    svc-inbox:\n(?: {6,}.*\n)+/, '')
  assert.equal(stripped, base)
})

test('follows the base table entry point and certificate resolver', () => {
  const letsEncrypt = renderInboxGateway(read(traefik + 'dynamic.letsencrypt.template.yml'), 'example.invalid')
  assert.match(router(letsEncrypt, 'inbox-api'), /tls:\n        certResolver: le/)
  const base = read(traefik + 'dynamic.yml')
  const behindEdge = renderInboxGateway(base.replaceAll('entryPoints: ["websecure"]', 'entryPoints: ["web"]').replace(/^ +tls: \{\}\r?\n/gm, ''), 'example.invalid')
  const edgeRouter = router(behindEdge, 'inbox-api')
  assert.match(edgeRouter, /entryPoints: \["web"\]/)
  assert.doesNotMatch(edgeRouter, /tls:/)
  const crlf = renderInboxGateway(base.replaceAll('\n', '\r\n'), 'example.invalid')
  assert.doesNotMatch(crlf.replaceAll('\r\n', ''), /\n/)
})

test('refuses a second render, a bad base domain and a malformed table', () => {
  const base = read(traefik + 'dynamic.yml')
  const rendered = renderInboxGateway(base, 'saas.localtest.me')
  assert.throws(() => renderInboxGateway(rendered, 'saas.localtest.me'), /already contains Inbox routes/)
  for (const domain of ['BAD domain', 'localhost', '-bad.example.com', undefined]) {
    assert.throws(() => renderInboxGateway(base, domain), /lowercase DNS name/)
  }
  assert.throws(() => renderInboxGateway(`${base}\n  routers:\n`, 'saas.localtest.me'), /missing required sections/)
  assert.throws(() => renderInboxGateway(undefined, 'saas.localtest.me'), /must be text/)
})

test('the command line writes the rendered table and reports usage errors', () => {
  const dir = mkdtempSync(path.join(tmpdir(), 'inbox-gateway-'))
  try {
    const script = path.join(kit, 'scripts/render-inbox-gateway.mjs')
    const output = path.join(dir, 'dynamic.inbox.generated.yml')
    const ok = spawnSync(process.execPath, [script, '--base-domain', 'example.invalid', '--output', output], {encoding: 'utf8'})
    assert.equal(ok.status, 0, ok.stderr)
    assert.match(readFileSync(output, 'utf8'), /inbox-api:/)
    const bad = spawnSync(process.execPath, [script, '--base-domain'], {encoding: 'utf8'})
    assert.equal(bad.status, 1)
    assert.match(bad.stderr, /Missing value for --base-domain\nUsage: node scripts\/render-inbox-gateway\.mjs/)
  } finally {
    rmSync(dir, {recursive: true, force: true})
  }
})

test('the Inbox overlay runs only the Inbox and names the rendered gateway table', () => {
  const overlay = read('compose/docker-compose.inbox.yml')
  const services = [...overlay.matchAll(/^  ([\w-]+):\s*$/gm)].map(([, name]) => name)
  assert.deepEqual(services, ['traefik', 'enterprise-platform', 'vdx-inbox'])
  assert.doesNotMatch(overlay, /temporal|enterprise-workflow|enterprise-portal|^volumes:/m)
  assert.match(overlay, /\$\{EDK_INBOX_GATEWAY_CONFIG:\?Render an Inbox gateway config with scripts\/render-inbox-gateway\.mjs\}/)
  assert.match(overlay, /\.\/config\/platform\.inbox\.application-container\.yml:\/app\/config\/application-container\.yml:ro/)
  assert.match(overlay, /image: \$\{VDX_REGISTRY:\?[^}]+\}\/vdx-inbox:\$\{VDX_TAG:\?[^}]+\}/)
  assert.match(overlay, /AUTHZ_POLICY_ENGINES_OPA_MAIN_ENDPOINT: \$\{EDK_INBOX_OPA_ENDPOINT:\?/)
  assert.match(overlay, /INBOX_NOTICES_WORKLOADS: \$\{INBOX_NOTICES_WORKLOADS:-\}/)
  assert.match(overlay, /workload\/service-inbox:/)
  assert.doesNotMatch(overlay, /EDK_WORKFLOW_OPA_ENDPOINT|CLIENT_SECRET_(WORKFLOW|PORTAL)|workflow-service/)
  assert.match(read('compose/.gitignore'), /^gateway\/traefik\/dynamic\.inbox\.generated\.yml$/m)
})

test('the platform Inbox profile registers only the Inbox client and workload binding', () => {
  const profile = read('compose/config/platform.inbox.application-container.yml').replaceAll('\r\n', '\n')
  assert.match(profile, /^        inbox:\n          client-id: inbox-service\n          client-secret: \$\{env:EDK_INTERNAL_CLIENT_SECRET_INBOX\}\n/m)
  assert.match(profile, /allowed-access-token-audiences: enterprise-tenant-kms\n/)
  assert.match(profile, /^        inbox:\n          client-id: inbox-service\n          allowed-audiences: enterprise-platform,enterprise-tenant-kms\n/m)
  assert.match(profile, /"\[service-inbox\]": inbox-service/)
  assert.doesNotMatch(profile, /workflow|portal|delegation|^transport:/m)
})

test('the base route tables keep forms on the platform and route no workflow or lifecycle API', () => {
  for (const file of ['dynamic.yml', 'dynamic.letsencrypt.template.yml', 'dynamic.public-cert.template.yml', 'dynamic.federation.template.yml']) {
    const source = read(traefik + file)
    assert.match(router(source, 'tenant-backend-platform'), /PathPrefix\(`\/api\/forms\/v1`\)/, file)
    assert.doesNotMatch(source, /\/api\/(workflow|lifecycle)\/v1|\/api\/inbox\/v1/, file)
  }
})
