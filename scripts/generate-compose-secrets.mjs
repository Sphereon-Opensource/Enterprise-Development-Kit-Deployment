#!/usr/bin/env node
// Completes compose/.env for a Docker Compose installation:
//  - fills every empty secret with an independent random value,
//  - copies the secret-authority coordinates from <EDK_SECRET_AUTHORITY_ROOT>/window.env,
//  - writes the digest of the selected secret-management environment manifest.
// Values that are already set are never changed. Values copied from earlier published templates
// are reported so the operator can plan their rotation.
import {createHash, randomBytes} from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import {fileURLToPath} from 'node:url'

const composeDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../compose')

export const secretKeys = [
  'EDK_PLATFORM_DB_PASSWORD',
  'EDK_TENANT_DB_PASSWORD',
  'EDK_SECRET_MANAGEMENT_ADMIN_DB_PASSWORD',
  'EDK_SECRET_MANAGEMENT_TENANT_DB_PASSWORD',
  'EDK_SECRET_MANAGEMENT_RUNTIME_DB_PASSWORD',
  'EDK_KEYSTORE_PASSWORD',
  'EDK_INTERNAL_CLIENT_SECRET_TENANT_KMS',
  'EDK_INTERNAL_CLIENT_SECRET_TENANT_AS',
  'EDK_INTERNAL_CLIENT_SECRET_DID',
  'EDK_INTERNAL_CLIENT_SECRET_BLOB',
  'EDK_INTERNAL_CLIENT_SECRET_ISSUER',
  'EDK_INTERNAL_CLIENT_SECRET_VERIFIER',
  'EDK_ADMIN_CONSOLE_WORKLOAD_CLIENT_SECRET',
  'EDK_PIPELINE_MASTER_KEK',
  'EDK_PIPELINE_BLIND_INDEX_KEY',
  'EDK_FEDERATION_SESSION_ENCRYPTION_KEY',
  'EDK_KEYCLOAK_DB_PASSWORD',
  'EDK_KEYCLOAK_ADMIN_PASSWORD',
]
export const secretAuthorityKeys = [
  'SECRET_AUTHORITY_CENTRAL_PERMIT_SIGNING_KEY',
  'SECRET_AUTHORITY_CENTRAL_ASSERTION_VERIFICATION_KEYS',
  'SECRET_AUTHORITY_SATELLITE_ASSERTION_SIGNING_KEY',
  'SECRET_AUTHORITY_SATELLITE_PERMIT_VERIFICATION_KEYS',
]
const DEFAULT_AUTHORITY_ROOT = './.secret-authority/current'
const DEFAULT_MANIFEST = './config/secret-management-environment.manifest'
const MANIFEST_KEY = 'EDK_SECRET_MANAGEMENT_ENVIRONMENT_MANIFEST'
const MANIFEST_DIGEST_KEY = 'EDK_SECRET_MANAGEMENT_ENVIRONMENT_MANIFEST_SHA256'
// Values shipped in earlier templates. They are public and must be rotated with a planned procedure.
const publishedExamples = new Set([
  '9rA4YvY5MJHr9VNwBw8jK-3m6DnQQ30hkzIi7Fu3z3I',
  'hTOiPZSnQtL3eL_XLJR46xbvCrKmh6equWPqukhTVEA',
])
const isPublished = value => publishedExamples.has(value) || value.startsWith('replace-me-')
const newSecret = key => randomBytes(32).toString(key === 'EDK_FEDERATION_SESSION_ENCRYPTION_KEY' ? 'base64' : 'base64url')

function parseAssignments(text, source) {
  const values = new Map()
  for (const line of text.split(/\r?\n/)) {
    const match = /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/.exec(line)
    if (!match) continue
    if (values.has(match[1])) throw new Error(`Duplicate variable in ${source}: ${match[1]}`)
    values.set(match[1], match[2])
  }
  return values
}

/** Digest the platform expects for a secret-management environment manifest: sorted ids, each followed by NUL and SHA-256(""). */
export function manifestDigest(manifestFile) {
  const ids = fs.readFileSync(manifestFile, 'utf8').split(/\r?\n/).map(line => line.trim())
    .filter(line => line && !line.startsWith('#')).map(line => line.split('=')[0].trim()).sort()
  const empty = createHash('sha256').update('').digest()
  const hash = createHash('sha256')
  for (const id of ids) hash.update(Buffer.concat([Buffer.from(id, 'utf8'), Buffer.from([0]), empty]))
  return `sha256:${hash.digest('hex')}`
}

export function completeComposeEnv(envFile = path.join(composeDir, '.env')) {
  const original = fs.readFileSync(envFile, 'utf8')
  const newline = original.includes('\r\n') ? '\r\n' : '\n'
  const lines = original.split(/\r?\n/)
  const current = parseAssignments(original, envFile)
  const envDir = path.dirname(envFile)
  const updates = new Map()
  const report = {generated: [], published: [], copied: [], derived: [], warnings: []}

  for (const key of secretKeys) {
    const value = current.get(key) ?? ''
    if (value) {
      if (isPublished(value)) report.published.push(key)
      continue
    }
    updates.set(key, newSecret(key))
    report.generated.push(key)
  }

  const authorityRoot = path.resolve(envDir, current.get('EDK_SECRET_AUTHORITY_ROOT') || DEFAULT_AUTHORITY_ROOT)
  const windowFile = path.join(authorityRoot, 'window.env')
  if (fs.existsSync(windowFile)) {
    const window = parseAssignments(fs.readFileSync(windowFile, 'utf8'), windowFile)
    for (const key of secretAuthorityKeys) {
      const generated = window.get(key)
      if (!generated) throw new Error(`${windowFile} has no ${key}. Generate the secret-authority key set again.`)
      const value = current.get(key) ?? ''
      if (!value) {
        updates.set(key, generated)
        report.copied.push(key)
      } else if (value !== generated) {
        throw new Error(`${key} in .env does not match ${windowFile}. During a planned authority key rotation, clear the four SECRET_AUTHORITY_* values in .env and run this script again.`)
      }
    }
  } else if (secretAuthorityKeys.some(key => !current.get(key))) {
    report.warnings.push(`No ${windowFile}. Run scripts/generate-secret-authority-keys first, then run this script again.`)
  }

  const manifest = current.get(MANIFEST_KEY)
  if (manifest || current.has(MANIFEST_DIGEST_KEY)) {
    const digest = manifestDigest(path.resolve(envDir, manifest || DEFAULT_MANIFEST))
    if (current.get(MANIFEST_DIGEST_KEY) !== digest) {
      updates.set(MANIFEST_DIGEST_KEY, digest)
      report.derived.push(MANIFEST_DIGEST_KEY)
    }
  }

  if (updates.size) {
    const pending = new Map(updates)
    const output = lines.map(line => {
      const match = /^([A-Za-z_][A-Za-z0-9_]*)=/.exec(line)
      if (!match || !pending.has(match[1])) return line
      const replacement = `${match[1]}=${pending.get(match[1])}`
      pending.delete(match[1])
      return replacement
    })
    while (output.length && output.at(-1) === '') output.pop()
    for (const [key, value] of pending) output.push(`${key}=${value}`)
    fs.writeFileSync(envFile, output.join(newline) + newline, {mode: 0o600})
  }
  return report
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2)
  if (args.length > 2 || (args.length && args[0] !== '--env') || (args[0] === '--env' && !args[1])) {
    console.error('Usage: node scripts/generate-compose-secrets.mjs [--env path/to/compose/.env]')
    process.exit(2)
  }
  try {
    const report = completeComposeEnv(args[1] || path.join(composeDir, '.env'))
    console.log(`Generated ${report.generated.length} secrets. Existing values were kept.`)
    if (report.published.length) console.warn(`These values come from a published template and are not secret: ${report.published.join(', ')}. Rotate them with a planned procedure.`)
    if (report.copied.length) console.log(`Copied the secret-authority coordinates from window.env.`)
    if (report.derived.length) console.log(`Wrote ${MANIFEST_DIGEST_KEY} for the selected manifest.`)
    for (const warning of report.warnings) console.warn(warning)
  } catch (error) {
    console.error(error.message)
    process.exit(1)
  }
}
