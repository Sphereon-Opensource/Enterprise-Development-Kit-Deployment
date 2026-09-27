import assert from 'node:assert/strict'
import {randomBytes} from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import {fileURLToPath} from 'node:url'
import {completeComposeEnv, manifestDigest, secretAuthorityKeys, secretKeys} from './generate-compose-secrets.mjs'

const composeDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../compose')
const template = path.join(composeDir, '.env.example')
const assignments = text => Object.fromEntries(text.split(/\r?\n/).filter(line => /^[A-Za-z_][A-Za-z0-9_]*=/.test(line)).map(line => line.split(/=(.*)/s).slice(0, 2)))

function workspace(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'edk-compose-env-'))
  t.after(() => fs.rmSync(dir, {recursive: true, force: true}))
  return dir
}
function writeWindow(dir, id = 'secret-authority-1') {
  const root = path.join(dir, '.secret-authority', 'current')
  fs.mkdirSync(root, {recursive: true})
  const values = Object.fromEntries(secretAuthorityKeys.map(key => [key, `${id}|0|1|/app/secret-authority/${key.toLowerCase()}.pem`]))
  fs.writeFileSync(path.join(root, 'window.env'), [`SECRET_AUTHORITY_KEY_ID=${id}`, ...Object.entries(values).map(([key, value]) => `${key}=${value}`)].join('\n') + '\n')
  return values
}

test('fills every secret and the authority coordinates once, then leaves the file unchanged', t => {
  const dir = workspace(t)
  const envFile = path.join(dir, '.env')
  fs.copyFileSync(template, envFile)
  const window = writeWindow(dir)
  const report = completeComposeEnv(envFile)
  assert.deepEqual(report.generated, secretKeys)
  assert.deepEqual(report.copied, secretAuthorityKeys)
  const first = fs.readFileSync(envFile, 'utf8')
  const values = assignments(first)
  assert.equal(new Set(secretKeys.map(key => values[key])).size, secretKeys.length)
  for (const key of secretKeys) {
    const pattern = key === 'EDK_FEDERATION_SESSION_ENCRYPTION_KEY' ? /^[A-Za-z0-9+/]{43}=$/ : /^[A-Za-z0-9_-]{43}$/
    assert.match(values[key], pattern, key)
  }
  for (const key of secretAuthorityKeys) assert.equal(values[key], window[key])
  assert.equal(values.EDK_PLATFORM_BASE_DOMAIN, '')
  assert.equal(values.EDK_TAG, '')
  assert.deepEqual(completeComposeEnv(envFile).generated, [])
  assert.equal(fs.readFileSync(envFile, 'utf8'), first)
})

test('keeps operator values, appends missing fields and warns without a key window', t => {
  const dir = workspace(t)
  const envFile = path.join(dir, '.env')
  const original = `EDK_PLATFORM_DB_PASSWORD=${randomBytes(16).toString('hex')}\n`
  fs.writeFileSync(envFile, original)
  const report = completeComposeEnv(envFile)
  assert.equal(report.generated.length, secretKeys.length - 1)
  assert.match(report.warnings.join('\n'), /generate-secret-authority-keys/)
  const updated = fs.readFileSync(envFile, 'utf8')
  assert.ok(updated.startsWith(original))
  assert.match(updated, /^EDK_FEDERATION_SESSION_ENCRYPTION_KEY=[A-Za-z0-9+/]{43}=$/m)
})

test('reports published template values instead of rotating a running installation', t => {
  const dir = workspace(t)
  const envFile = path.join(dir, '.env')
  const original = fs.readFileSync(template, 'utf8')
    .replace('EDK_PIPELINE_MASTER_KEK=', 'EDK_PIPELINE_MASTER_KEK=9rA4YvY5MJHr9VNwBw8jK-3m6DnQQ30hkzIi7Fu3z3I')
    .replace('EDK_INTERNAL_CLIENT_SECRET_DID=', 'EDK_INTERNAL_CLIENT_SECRET_DID=replace-me-edk-internal-did')
  fs.writeFileSync(envFile, original)
  const report = completeComposeEnv(envFile)
  assert.deepEqual(report.published, ['EDK_INTERNAL_CLIENT_SECRET_DID', 'EDK_PIPELINE_MASTER_KEK'])
  const values = assignments(fs.readFileSync(envFile, 'utf8'))
  assert.equal(values.EDK_PIPELINE_MASTER_KEK, '9rA4YvY5MJHr9VNwBw8jK-3m6DnQQ30hkzIi7Fu3z3I')
  assert.equal(values.EDK_INTERNAL_CLIENT_SECRET_DID, 'replace-me-edk-internal-did')
})

test('refuses authority coordinates that do not match the key window', t => {
  const dir = workspace(t)
  const envFile = path.join(dir, '.env')
  writeWindow(dir, 'secret-authority-new')
  const original = fs.readFileSync(template, 'utf8').replace('SECRET_AUTHORITY_CENTRAL_PERMIT_SIGNING_KEY=', 'SECRET_AUTHORITY_CENTRAL_PERMIT_SIGNING_KEY=secret-authority-old|0|1|/x.pem')
  fs.writeFileSync(envFile, original)
  assert.throws(() => completeComposeEnv(envFile), /does not match .*window\.env/)
  assert.equal(fs.readFileSync(envFile, 'utf8'), original)
})

test('writes the digest of the selected manifest, matching the Compose default for the shipped one', t => {
  assert.match(fs.readFileSync(path.join(composeDir, 'docker-compose.yml'), 'utf8'),
    new RegExp(`MANIFEST_SHA256:-${manifestDigest(path.join(composeDir, 'config/secret-management-environment.manifest'))}\\}`))
  const dir = workspace(t)
  fs.cpSync(path.join(composeDir, 'config'), path.join(dir, 'config'), {recursive: true})
  const envFile = path.join(dir, '.env')
  fs.writeFileSync(envFile, 'EDK_SECRET_MANAGEMENT_ENVIRONMENT_MANIFEST=./config/secret-management-environment.azure.manifest\n')
  assert.deepEqual(completeComposeEnv(envFile).derived, ['EDK_SECRET_MANAGEMENT_ENVIRONMENT_MANIFEST_SHA256'])
  const digest = assignments(fs.readFileSync(envFile, 'utf8')).EDK_SECRET_MANAGEMENT_ENVIRONMENT_MANIFEST_SHA256
  assert.equal(digest, manifestDigest(path.join(composeDir, 'config/secret-management-environment.azure.manifest')))
  assert.notEqual(digest, manifestDigest(path.join(composeDir, 'config/secret-management-environment.manifest')))
})

test('the template declares exactly the inputs Compose requires, and Compose supplies every config input', () => {
  const compose = fs.readFileSync(path.join(composeDir, 'docker-compose.yml'), 'utf8')
  const declared = Object.keys(assignments(fs.readFileSync(template, 'utf8')))
  for (const key of [...secretKeys, ...secretAuthorityKeys, 'EDK_TAG', 'EDK_PLATFORM_BASE_DOMAIN']) assert.ok(declared.includes(key), `template misses ${key}`)
  const keycloak = fs.readFileSync(path.join(composeDir, 'docker-compose.keycloak.yml'), 'utf8')
  for (const key of declared) assert.ok(compose.includes(`\${${key}`) || keycloak.includes(`\${${key}`), `template declares unused ${key}`)
  const imageLines = compose.split(/\r?\n/).filter(line => /^\s+image: nexus\.sphereon\.com\/edk-docker\//.test(line))
  assert.equal(imageLines.length, 9)
  for (const line of imageLines) assert.match(line, /\$\{EDK_TAG:\?Set EDK_TAG to the approved release tag\}/)
  const configDir = path.join(composeDir, 'config')
  for (const name of fs.readdirSync(configDir).filter(name => name.endsWith('.application.yml'))) {
    const config = fs.readFileSync(path.join(configDir, name), 'utf8')
    for (const [, key] of config.matchAll(/\$\{env:([A-Za-z_][A-Za-z0-9_]*)\}/g)) {
      assert.match(compose, new RegExp(`^\\s+${key}:`, 'm'), `${name} requires ${key}`)
    }
  }
})
