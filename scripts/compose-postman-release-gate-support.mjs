#!/usr/bin/env node

import {createHash} from 'node:crypto'
import {spawn} from 'node:child_process'
import {
  appendFileSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  statSync,
  writeFileSync,
} from 'node:fs'
import {dirname, relative, resolve} from 'node:path'
import {pathToFileURL} from 'node:url'
import {
  findCanaryMatches,
  postmanValues,
  secretVariants,
} from './assert-plaintext-canary-absent.mjs'

const SENSITIVE_KEY = /(password|secret|token|code.?verifier|private.?key|authorization|credential)/iu
const TEXT_EXTENSIONS = new Set([
  '.json', '.jsonl', '.log', '.md', '.patch', '.sql', '.txt', '.xml', '.yaml', '.yml',
])

function usage(message) {
  if (message) console.error(message)
  console.error(
    'Usage: compose-postman-release-gate-support.mjs ' +
      '<classify-project|scan-producer|validate-junit|finalize-evidence> [options]',
  )
  process.exit(64)
}

function parseArgs(argv) {
  const separator = argv.indexOf('--')
  const optionArgs = separator >= 0 ? argv.slice(0, separator) : argv
  const tail = separator >= 0 ? argv.slice(separator + 1) : []
  const options = new Map()
  for (let index = 0; index < optionArgs.length; index += 2) {
    const name = optionArgs[index]
    const value = optionArgs[index + 1]
    if (!name?.startsWith('--') || value === undefined) usage(`Invalid option near '${name ?? ''}'.`)
    options.set(name, value)
  }
  return {options, tail}
}

function required(options, name) {
  const value = options.get(name)
  if (!value) usage(`${name} is required.`)
  return value
}

function bool(options, name) {
  const value = required(options, name)
  if (value !== 'true' && value !== 'false') usage(`${name} must be true or false.`)
  return value === 'true'
}

function writeJson(path, value) {
  mkdirSync(dirname(resolve(path)), {recursive: true})
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`, 'utf8')
}

export function decideProjectDisposition(inventory, {useExisting, reset}) {
  const normalized = {
    containers: Array.isArray(inventory?.containers) ? inventory.containers.filter(Boolean) : [],
    networks: Array.isArray(inventory?.networks) ? inventory.networks.filter(Boolean) : [],
    volumes: Array.isArray(inventory?.volumes) ? inventory.volumes.filter(Boolean) : [],
  }
  const assetCount = normalized.containers.length + normalized.networks.length + normalized.volumes.length
  if (useExisting && reset) throw new Error('Use-existing and reset modes are mutually exclusive.')
  if (useExisting) {
    if (assetCount === 0) {
      throw new Error('Cannot adopt a Compose project with no existing containers, networks, or volumes.')
    }
    return {mode: 'adopted', ownsProject: false, assetCount, inventory: normalized}
  }
  if (reset) return {mode: 'owned-reset', ownsProject: true, assetCount, inventory: normalized}
  if (assetCount > 0) {
    throw new Error(
      `Compose project already owns ${normalized.containers.length} container(s), ` +
        `${normalized.networks.length} network(s), and ${normalized.volumes.length} volume(s). ` +
        'Use explicit adoption or reset.',
    )
  }
  return {mode: 'owned-new', ownsProject: true, assetCount: 0, inventory: normalized}
}

function sensitiveEntries(environmentPath) {
  return [...postmanValues(environmentPath).entries()]
    .filter(([key, value]) => SENSITIVE_KEY.test(key) && value)
    .map(([key, value]) => ({key, value}))
}

export function redactSensitiveText(text, entries) {
  let result = String(text)
  let replacements = 0
  for (const {value} of entries) {
    for (const variant of secretVariants(value).sort((left, right) => right.length - left.length)) {
      if (!variant) continue
      const parts = result.split(variant)
      if (parts.length > 1) {
        replacements += parts.length - 1
        result = parts.join('[REDACTED_CONFIGURED_SECRET]')
      }
    }
  }
  const patterns = [
    [/(Bearer\s+)[A-Za-z0-9._~+/=-]{12,}/giu, '$1[REDACTED_BEARER_TOKEN]'],
    [/(Basic\s+)[A-Za-z0-9+/=]{8,}/giu, '$1[REDACTED_BASIC_CREDENTIAL]'],
    [/((?:set-cookie|cookie)\s*:\s*)[^\r\n]+/giu, '$1[REDACTED_COOKIE]'],
    [/\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/gu, '[REDACTED_JWT]'],
    [
      /(["']?(?:access_token|refresh_token|id_token|token|password|secret|code_verifier)["']?\s*[:=]\s*["'])[^"'\r\n]+(["'])/giu,
      '$1[REDACTED_SECRET_FIELD]$2',
    ],
    [
      /([?&#](?:access_token|refresh_token|id_token|token|password|secret|code|code_verifier)=)[^&#\s]+/giu,
      '$1[REDACTED_SECRET_PARAMETER]',
    ],
  ]
  for (const [pattern, replacement] of patterns) {
    result = result.replace(pattern, (...args) => {
      replacements += 1
      return typeof replacement === 'string'
        ? replacement.replace(/\$(\d)/gu, (_, index) => args[Number(index)] ?? '')
        : replacement(...args)
    })
  }
  return {text: result, replacements}
}

function walkFiles(root) {
  const files = []
  for (const entry of readdirSync(root, {withFileTypes: true})) {
    const path = resolve(root, entry.name)
    if (entry.isDirectory()) files.push(...walkFiles(path))
    else if (entry.isFile()) files.push(path)
  }
  return files
}

function looksTextual(path, bytes) {
  const dot = path.lastIndexOf('.')
  if (dot >= 0 && TEXT_EXTENSIONS.has(path.slice(dot).toLowerCase())) return true
  return !bytes.subarray(0, Math.min(bytes.length, 8192)).includes(0)
}

function sanitizeTree(root, entries, excluded = new Set()) {
  const changed = []
  let replacements = 0
  for (const path of walkFiles(root)) {
    if (excluded.has(resolve(path))) continue
    const bytes = readFileSync(path)
    if (!looksTextual(path, bytes)) continue
    const original = bytes.toString('utf8')
    const redacted = redactSensitiveText(original, entries)
    if (redacted.text !== original) {
      writeFileSync(path, redacted.text, 'utf8')
      changed.push(relative(root, path).replaceAll('\\', '/'))
      replacements += redacted.replacements
    }
  }
  return {changed, replacements}
}

function sha256File(path) {
  return createHash('sha256').update(readFileSync(path)).digest('hex')
}

function numericAttribute(attributes, name, label) {
  const match = new RegExp(`\\b${name}="([0-9]+)"`, 'u').exec(attributes)
  if (!match) throw new Error(`${label} must contain a numeric ${name} attribute.`)
  return Number(match[1])
}

export function validateJunitText(xml) {
  const rootMatch = /^\s*<\?xml[^>]*>\s*<testsuites\b([^>]*)>/u.exec(xml)
  if (!rootMatch || !/<\/testsuites>\s*$/u.test(xml)) {
    throw new Error('JUnit must contain one complete testsuites root element.')
  }
  const root = {
    tests: numericAttribute(rootMatch[1], 'tests', 'JUnit testsuites'),
    failures: numericAttribute(rootMatch[1], 'failures', 'JUnit testsuites'),
    errors: numericAttribute(rootMatch[1], 'errors', 'JUnit testsuites'),
  }
  if (root.tests <= 0) throw new Error('JUnit must contain at least one test.')
  if (root.failures !== 0 || root.errors !== 0) {
    throw new Error(`JUnit reports ${root.failures} failure(s) and ${root.errors} error(s).`)
  }
  const suites = [...xml.matchAll(/<testsuite\b([^>]*)>/gu)].map((match, index) => ({
    tests: numericAttribute(match[1], 'tests', `JUnit testsuite ${index + 1}`),
    failures: numericAttribute(match[1], 'failures', `JUnit testsuite ${index + 1}`),
    errors: numericAttribute(match[1], 'errors', `JUnit testsuite ${index + 1}`),
  }))
  const testcaseCount = [...xml.matchAll(/<testcase\b/gu)].length
  if (suites.length === 0 || testcaseCount === 0) {
    throw new Error('JUnit must contain at least one testsuite and testcase.')
  }
  const sums = suites.reduce(
    (total, suite) => ({
      tests: total.tests + suite.tests,
      failures: total.failures + suite.failures,
      errors: total.errors + suite.errors,
    }),
    {tests: 0, failures: 0, errors: 0},
  )
  if (sums.tests !== root.tests || sums.failures !== root.failures || sums.errors !== root.errors) {
    throw new Error('JUnit root totals must equal the sum of testsuite totals.')
  }
  if (testcaseCount !== root.tests) {
    throw new Error(`JUnit declares ${root.tests} tests but contains ${testcaseCount} testcase elements.`)
  }
  return {...root, suites: suites.length, testcases: testcaseCount}
}

function spawnTracked(command, args, options = {}) {
  return spawn(command, args, {
    windowsHide: true,
    stdio: ['pipe', 'pipe', 'pipe'],
    ...options,
  })
}

export async function runProducerScan({
  command,
  arguments: producerArguments,
  scannerPath,
  environmentPath,
  canaryKey,
  label,
}) {
  const producer = spawnTracked(command, producerArguments)
  const scanner = spawnTracked(process.execPath, [
    scannerPath,
    '--environment', environmentPath,
    '--canary-key', canaryKey,
    '--label', label,
  ])
  const producerErrors = []
  const scannerOutput = []
  const scannerErrors = []
  producer.stdout.pipe(scanner.stdin)
  producer.stderr.on('data', (chunk) => producerErrors.push(chunk))
  scanner.stdout.on('data', (chunk) => scannerOutput.push(chunk))
  scanner.stderr.on('data', (chunk) => scannerErrors.push(chunk))

  const wait = (child) => new Promise((resolvePromise) => {
    child.once('error', (error) => resolvePromise({code: null, error}))
    child.once('close', (code, signal) => resolvePromise({code, signal}))
  })
  const [producerResult, scannerResult] = await Promise.all([wait(producer), wait(scanner)])
  return {
    producer: producerResult,
    scanner: scannerResult,
    producerStderr: Buffer.concat(producerErrors).toString('utf8'),
    scannerStdout: Buffer.concat(scannerOutput).toString('utf8'),
    scannerStderr: Buffer.concat(scannerErrors).toString('utf8'),
  }
}

function manifestEvidence(root, excluded) {
  return walkFiles(root)
    .filter((path) => !excluded.has(resolve(path)))
    .map((path) => ({
      path: relative(root, path).replaceAll('\\', '/'),
      bytes: statSync(path).size,
      sha256: sha256File(path),
    }))
    .sort((left, right) => left.path.localeCompare(right.path))
}

/**
 * Evidence kinds. `release` is the gate verdict for the release under test. `baseline` is the
 * prior-release install an upgrade rehearsal starts from: it is not release-verified, so it gets
 * its own label and can never be read as a gate pass.
 */
export const EVIDENCE_LABELS = Object.freeze({
  release: 'customer-compose-evidence',
  baseline: 'customer-compose-baseline',
})

/**
 * Optional lanes the gate can run. Every lane is always recorded so a reader can tell a lane
 * that was not exercised from one that does not exist. keycloak and webhookSink follow their
 * switches; azureKms is ran only when -AzureKms is given and every AZURE_* value is present;
 * eudi has no switch yet and is recorded as skipped until it does.
 */
export const OPTIONAL_LANES = Object.freeze(['keycloak', 'webhookSink', 'azureKms', 'eudi'])
export const OPTIONAL_LANE_STATES = Object.freeze(['ran', 'skipped'])

export function normalizeOptionalLanes(input = {}) {
  for (const [name, state] of Object.entries(input)) {
    if (!OPTIONAL_LANES.includes(name)) throw new Error(`Unknown optional lane '${name}'.`)
    if (!OPTIONAL_LANE_STATES.includes(state)) {
      throw new Error(`Optional lane '${name}' must be ran or skipped; got '${state}'.`)
    }
  }
  const lanes = {}
  for (const name of OPTIONAL_LANES) lanes[name] = input[name] ?? 'skipped'
  return lanes
}

/** Parses the CLI form `keycloak=ran,webhookSink=skipped`. Unlisted lanes are skipped. */
export function parseOptionalLanes(text) {
  const lanes = {}
  const entries = String(text ?? '').split(',').map((entry) => entry.trim()).filter(Boolean)
  for (const entry of entries) {
    const parts = entry.split('=')
    if (parts.length !== 2 || !parts[0]) {
      throw new Error(`Invalid optional lane entry '${entry}'; expected name=ran|skipped.`)
    }
    lanes[parts[0]] = parts[1]
  }
  return normalizeOptionalLanes(lanes)
}

export function finalizeEvidence({
  root,
  environmentPath,
  canaryKey,
  candidateStatus,
  teardownStatus,
  projectName,
  tag,
  requestCount,
  manifestPath,
  manifestHashPath,
  evidenceKind = 'release',
  optionalLanes = {},
}) {
  if (!Object.hasOwn(EVIDENCE_LABELS, evidenceKind)) {
    throw new Error(`Unknown evidence kind '${evidenceKind}'.`)
  }
  const lanes = normalizeOptionalLanes(optionalLanes)
  const entries = sensitiveEntries(environmentPath)
  const canary = postmanValues(environmentPath).get(canaryKey) ?? ''
  const manifest = resolve(manifestPath)
  const manifestHash = resolve(manifestHashPath)
  const excluded = new Set([manifest, manifestHash])
  const canaryExposures = []
  for (const path of walkFiles(root)) {
    if (excluded.has(resolve(path))) continue
    const bytes = readFileSync(path)
    if (!looksTextual(path, bytes)) continue
    if (findCanaryMatches(bytes.toString('utf8'), canary).length > 0) {
      canaryExposures.push(relative(root, path).replaceAll('\\', '/'))
    }
  }
  const sanitation = sanitizeTree(root, entries, excluded)
  const status =
    candidateStatus === 'passed' && teardownStatus !== 'failed' && canaryExposures.length === 0
      ? 'passed'
      : 'failed'
  const sanitationPath = resolve(root, 'evidence-sanitization.json')
  writeJson(sanitationPath, {
    checkedAt: new Date().toISOString(),
    configuredSecretCount: entries.length,
    replacements: sanitation.replacements,
    changedFiles: sanitation.changed,
    canaryExposureFiles: canaryExposures,
  })
  const evidence = manifestEvidence(root, excluded)
  writeJson(manifest, {
    status,
    kind: evidenceKind,
    completedAt: new Date().toISOString(),
    projectName,
    tag,
    requestCount,
    teardownStatus,
    canaryStatus: canaryExposures.length === 0 ? 'absent' : 'exposed-and-redacted',
    optionalLanes: lanes,
    evidence,
    detachedManifestHash: {
      algorithm: 'sha256',
      path: relative(root, manifestHash).replaceAll('\\', '/'),
      scope: relative(root, manifest).replaceAll('\\', '/'),
      note: 'The detached hash accounts for the manifest; the hash file cannot self-hash.',
    },
  })
  writeFileSync(
    manifestHash,
    `${sha256File(manifest)}  ${relative(root, manifest).replaceAll('\\', '/')}\n`,
    'utf8',
  )
  return {status, canaryExposures, sanitation, evidenceKind, optionalLanes: lanes}
}

async function main(argv) {
  const [command, ...rest] = argv
  const {options, tail} = parseArgs(rest)
  if (command === 'classify-project') {
    const inventory = JSON.parse(readFileSync(required(options, '--inventory'), 'utf8'))
    const result = decideProjectDisposition(inventory, {
      useExisting: bool(options, '--use-existing'),
      reset: bool(options, '--reset'),
    })
    writeJson(required(options, '--output'), result)
    console.log(`customer-compose-project:${result.mode}`)
    return
  }
  if (command === 'scan-producer') {
    if (tail.length === 0) usage('scan-producer requires a command after --.')
    const environmentPath = required(options, '--environment')
    const entries = sensitiveEntries(environmentPath)
    const evidencePath = required(options, '--evidence')
    const label = required(options, '--label')
    const result = await runProducerScan({
      command: tail[0],
      arguments: tail.slice(1),
      scannerPath: required(options, '--scanner'),
      environmentPath,
      canaryKey: required(options, '--canary-key'),
      label,
    })
    const producerError = result.producer.error?.message ?? result.producerStderr
    const scannerError = result.scanner.error?.message ?? result.scannerStderr
    const safeProducerError = redactSensitiveText(producerError, entries).text.trim()
    const safeScannerError = redactSensitiveText(scannerError, entries).text.trim()
    if (result.producer.code !== 0 || result.scanner.code !== 0) {
      appendFileSync(evidencePath, `${JSON.stringify({
        label,
        status: 'failed',
        checkedAt: new Date().toISOString(),
        producerExitCode: result.producer.code,
        scannerExitCode: result.scanner.code,
      })}\n`, 'utf8')
      if (safeProducerError) console.error(`producer:${safeProducerError}`)
      if (safeScannerError) console.error(`scanner:${safeScannerError}`)
      throw new Error(
        `${label} requires producer and scanner exit 0; got ` +
          `${result.producer.code ?? 'spawn-error'} and ${result.scanner.code ?? 'spawn-error'}.`,
      )
    }
    const scanEvidence = JSON.parse(result.scannerStdout.trim())
    appendFileSync(evidencePath, `${JSON.stringify({
      ...scanEvidence,
      producerExitCode: result.producer.code,
      scannerExitCode: result.scanner.code,
    })}\n`, 'utf8')
    console.log(`customer-compose-producer-scan:${label}:passed`)
    return
  }
  if (command === 'validate-junit') {
    const result = validateJunitText(readFileSync(required(options, '--file'), 'utf8'))
    writeJson(required(options, '--output'), {
      checkedAt: new Date().toISOString(),
      ...result,
    })
    console.log(`customer-compose-junit:${result.tests}:passed`)
    return
  }
  if (command === 'finalize-evidence') {
    const result = finalizeEvidence({
      root: resolve(required(options, '--root')),
      environmentPath: required(options, '--environment'),
      canaryKey: required(options, '--canary-key'),
      candidateStatus: required(options, '--candidate-status'),
      teardownStatus: required(options, '--teardown-status'),
      projectName: required(options, '--project-name'),
      tag: required(options, '--tag'),
      requestCount: Number(required(options, '--request-count')),
      manifestPath: required(options, '--manifest'),
      manifestHashPath: required(options, '--manifest-hash'),
      evidenceKind: options.get('--evidence-kind') ?? 'release',
      optionalLanes: parseOptionalLanes(options.get('--optional-lanes') ?? ''),
    })
    console.log(`${EVIDENCE_LABELS[result.evidenceKind]}:${result.status}`)
    console.log(
      `customer-compose-optional-lanes:${OPTIONAL_LANES.map((name) => `${name}=${result.optionalLanes[name]}`).join(',')}`,
    )
    if (result.status !== 'passed') process.exitCode = 1
    return
  }
  usage(`Unknown command '${command ?? ''}'.`)
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2)).catch((error) => {
    console.error(error instanceof Error ? error.message : String(error))
    process.exitCode = 1
  })
}
