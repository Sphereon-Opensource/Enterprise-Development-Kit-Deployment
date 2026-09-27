// An installation with the default (disabled) wallet workloads needs no wallet secrets or keys.
import assert from 'node:assert/strict'
import {spawnSync} from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import {fileURLToPath} from 'node:url'

const kit = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const chart = path.join(kit, 'helm', 'edk-enterprise')
const helmAvailable = spawnSync('helm', ['version', '--short'], {encoding: 'utf8'}).status === 0

// The maintained values file the README tells a customer to start from.
function readmeValues() {
  const readme = fs.readFileSync(path.join(kit, 'README.md'), 'utf8')
  const block = /```yaml\n(global:[\s\S]*?)```/.exec(readme)
  assert.ok(block, 'README has no customer-values.yaml example')
  return block[1]
    .replace('"<approved-release-tag>"', '"0.25.0"')
    .replace('"<stable-installation-id>"', '"deployment-1"')
    .replace('"<installed-gateway-class>"', '"gateway"')
}

function render(t, extra = []) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'edk-helm-wallet-'))
  t.after(() => fs.rmSync(dir, {recursive: true, force: true}))
  const values = path.join(dir, 'customer-values.yaml')
  fs.writeFileSync(values, readmeValues())
  const result = spawnSync('helm', ['template', 'edk', chart, '--namespace', 'edk', '-f', values, ...extra], {encoding: 'utf8', maxBuffer: 64 * 1024 * 1024})
  assert.equal(result.status, 0, result.stderr)
  return result.stdout
}

test('the README values render without any wallet client secret or wallet assertion key', {skip: !helmAvailable && 'helm is not installed'}, t => {
  const rendered = render(t)
  assert.doesNotMatch(rendered, /wallet-(unit|interaction|onboarding)-service-client-secret/)
  assert.doesNotMatch(rendered, /service-wallet-(unit|interaction|onboarding)-assertion\.pub\.pem/)
  assert.match(rendered, /public\/service-blob-assertion\.pub\.pem/)
})

test('enabled wallet workloads get their assertion keys and client secrets', {skip: !helmAvailable && 'helm is not installed'}, t => {
  const rendered = render(t, [
    '--set', 'services.wallet-unit.enabled=true',
    '--set', 'services.wallet-interaction.enabled=true',
    '--set-string', 'secretAuthority.existingSecrets.wallet-unit=edk-secret-authority-wallet-unit',
    '--set-string', 'secretAuthority.existingSecrets.wallet-interaction=edk-secret-authority-wallet-interaction',
    '--set', 'secretManagement.internalResolution.allowedServiceActors={tenant-as-service,issuer-service,kms-service,did-service,blob-service,verifier-service,wallet-unit-service,wallet-interaction-service}',
  ])
  assert.match(rendered, /public\/service-wallet-unit-assertion\.pub\.pem/)
  assert.match(rendered, /public\/service-wallet-interaction-assertion\.pub\.pem/)
  assert.match(rendered, /key: wallet-unit-service-client-secret/)
  assert.match(rendered, /key: wallet-interaction-service-client-secret/)
})

test('the Helm wrapper adds wallet client secrets instead of requiring them', () => {
  const wrapper = fs.readFileSync(path.join(kit, 'scripts', 'upgrade-helm.sh'), 'utf8')
  const required = /\nCLIENT_SECRET_KEYS=\(\n([\s\S]*?)\n\)/.exec(wrapper)[1]
  const optional = /\nOPTIONAL_CLIENT_SECRET_KEYS=\(\n([\s\S]*?)\n\)/.exec(wrapper)[1]
  assert.doesNotMatch(required, /wallet/)
  assert.match(optional, /wallet-unit-service-client-secret/)
  assert.match(optional, /wallet-interaction-service-client-secret/)
})
