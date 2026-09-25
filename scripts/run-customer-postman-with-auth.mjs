#!/usr/bin/env node

// Headless adapter for the shipped customer Postman collection.
//
// The collection has three top-level folders, each with its own Postman OAuth2
// configuration: the platform operator (authorization code + PKCE), the tenant
// owner (authorization code + PKCE) and the tenant's service client (client
// credentials). Postman obtains those tokens interactively; Newman cannot. This
// adapter performs the same sign-ins itself, reading every OAuth2 setting from
// the collection, and runs the unchanged request graph in three phases:
//
//   1. operator token        -> folder "1. Platform operator"
//   2. activate the owner,
//      owner token           -> folder "2. Tenant owner: create a service client"
//   3. service client token  -> folder "3. Tenant APIs"
//
// Collection variables captured in one phase (tenantId, the owner activation
// link, ...) reach the next phase through the runner's continuation files.
// Tokens reach the runner only through its EDK_E2E_ENV_ channel, which keeps
// them out of the collection and redacts them from evidence.
//
// Credentials: operatorEmail / operatorPassword and tenantOwnerPassword come
// from the (private) Postman environment, or from EDK_OPERATOR_EMAIL,
// EDK_OPERATOR_PASSWORD and EDK_TENANT_OWNER_PASSWORD.
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import {randomBytes, createHash} from 'node:crypto'
import {spawnSync} from 'node:child_process'
import {fileURLToPath, pathToFileURL} from 'node:url'

const scriptDir = path.dirname(fileURLToPath(import.meta.url))
const repoRoot = path.resolve(scriptDir, '..', '..', '..')
const DEFAULT_RUNNER = path.join(repoRoot, 'deploy', 'edk', 'e2e', 'runner', 'run-e2e.js')

// Environment keys the runner receives the tokens under (via EDK_E2E_ENV_<key>).
export const TOKEN_KEYS = Object.freeze({
  operator: 'customerGateOperatorToken',
  tenantOwner: 'customerGateTenantOwnerToken',
  serviceClient: 'customerGateServiceClientToken',
})

const clone = (value) => structuredClone(value)
const readJson = (file) => JSON.parse(fs.readFileSync(file, 'utf8'))

// --- Collection analysis --------------------------------------------------------

/** Postman stores OAuth2 settings as a key/value list; turn it into an object. */
export function oauth2Settings(auth) {
  if (auth?.type !== 'oauth2') return null
  return Object.fromEntries((auth.oauth2 ?? []).map((entry) => [entry.key, entry.value]))
}

/**
 * Which token a top-level folder needs, derived from its OAuth2 settings rather
 * than its name: client credentials is the service client, the platform
 * operator client is the operator, any other authorization-code client is the
 * tenant owner.
 */
export function tokenRoleOf(settings) {
  if (!settings) return null
  if (settings.grant_type === 'client_credentials') return 'serviceClient'
  if (String(settings.grant_type).startsWith('authorization_code')) {
    return settings.clientId === 'platform-operator-cli' ? 'operator' : 'tenantOwner'
  }
  throw new Error(`Unsupported OAuth2 grant type in the customer collection: ${settings.grant_type}`)
}

/** The top-level folders with their token role and OAuth2 settings, in order. */
export function topLevelPhases(collection) {
  return (collection.item ?? []).filter((item) => Array.isArray(item.item)).map((folder) => {
    const settings = oauth2Settings(folder.auth)
    return {name: folder.name, role: tokenRoleOf(settings), settings}
  })
}

/**
 * Replace the OAuth2 auth each request inherits from its top-level folder with
 * a bearer token variable. Requests with their own auth, and requests under a
 * nested OAuth2 folder (the optional wallet sign-in at Keycloak), keep theirs.
 */
export function bearerize(collection) {
  const result = clone(collection)
  for (const folder of result.item ?? []) {
    const role = tokenRoleOf(oauth2Settings(folder.auth))
    if (!role) continue
    const variable = `{{${TOKEN_KEYS[role]}}}`
    const visit = (items) => {
      for (const item of items ?? []) {
        if (Array.isArray(item.item)) {
          if (item.auth) continue // A nested folder with its own auth owns its requests.
          visit(item.item)
        } else if (!item.request?.auth) {
          item.request.auth = {type: 'bearer', bearer: [{key: 'token', value: variable, type: 'string'}]}
        }
      }
    }
    visit(folder.item)
    folder.auth = {type: 'noauth'}
  }
  return result
}

/** Keep only the named top-level folders. */
export function onlyFolders(collection, names) {
  const result = clone(collection)
  result.item = result.item.filter((item) => names.includes(item.name))
  return result
}

/** Overlay runtime collection variables from a previous phase. */
export function mergeVariables(collection, variables) {
  const merged = new Map((collection.variable ?? []).map((entry) => [entry.key, entry]))
  for (const entry of variables ?? []) merged.set(entry.key, clone(entry))
  collection.variable = [...merged.values()]
  return collection
}

/** Tag every request so JUnit shows which ones actually executed. */
export function instrumentRequests(collection) {
  const result = clone(collection)
  const visit = (items, parents) => {
    for (const item of items ?? []) {
      const trail = [...parents, item.name]
      if (Array.isArray(item.item)) {
        visit(item.item, trail)
        continue
      }
      const identity = trail.join(' > ').replaceAll('\\', '\\\\').replaceAll("'", "\\'")
      item.event ??= []
      item.event.push({listen: 'test', script: {type: 'text/javascript', exec: [`pm.test('__executed_request__ ${identity}', () => {});`]}})
    }
  }
  visit(result.item, [])
  return result
}

/** Every request in the collection with its identity and whether it is optional. */
export function requestLeaves(collection) {
  const out = []
  const visit = (items, parents, optional) => {
    for (const item of items ?? []) {
      const trail = [...parents, item.name]
      const isOptional = optional || /\(optional\)/u.test(item.name)
      if (Array.isArray(item.item)) visit(item.item, trail, isOptional)
      else out.push({identity: trail.join(' > '), optional: isOptional})
    }
  }
  visit(collection.item, [], false)
  return out
}

export function executedIdentities(junitXml) {
  return [...junitXml.matchAll(/<testcase\s+name="__executed_request__ ([^"]*)"/gu)]
    .map((match) => match[1].replaceAll('&gt;', '>').replaceAll('&lt;', '<').replaceAll('&quot;', '"').replaceAll('&apos;', "'").replaceAll('&amp;', '&'))
}

/**
 * Compare the requests the collection contains with the ones that executed.
 * Requests may skip themselves (an optional input is empty, an object already
 * exists); they are reported, not failed. Executing an unknown request fails.
 */
export function reconcileCoverage(leaves, executed) {
  const known = new Set(leaves.map((leaf) => leaf.identity))
  const unknown = [...new Set(executed)].filter((identity) => !known.has(identity))
  if (unknown.length) throw new Error(`Executed request is not part of the collection: ${unknown.join(', ')}`)
  const ran = new Set(executed)
  const skipped = leaves.filter((leaf) => !ran.has(leaf.identity))
  return {
    requests: leaves.length,
    executed: ran.size,
    skippedOptional: skipped.filter((leaf) => leaf.optional).map((leaf) => leaf.identity),
    skippedRequired: skipped.filter((leaf) => !leaf.optional).map((leaf) => leaf.identity),
  }
}

/** Combine the phase JUnit reports under one testsuites root. */
export function mergeJunit(xmlDocuments, name = 'EDK customer collection') {
  const suites = xmlDocuments.flatMap((xml) => [...xml.matchAll(/<testsuite\b[\s\S]*?<\/testsuite>|<testsuite\b[^>]*\/>/gu)].map((match) => match[0]))
  const total = (attribute) => suites.reduce((sum, suite) => sum + Number((new RegExp(`\\b${attribute}="(\\d+(?:\\.\\d+)?)"`, 'u').exec(suite.slice(0, suite.indexOf('>'))) ?? [0, 0])[1]), 0)
  const escapeAttribute = (value) => String(value).replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;')
  return `<?xml version="1.0" encoding="UTF-8"?>\n<testsuites name="${escapeAttribute(name)}" tests="${total('tests')}" failures="${total('failures')}" errors="${total('errors')}" time="${total('time').toFixed(3)}">\n${suites.join('\n')}\n</testsuites>\n`
}

// --- Variables ------------------------------------------------------------------

/** Resolve {{name}} placeholders; a missing value is an error, not an empty string. */
export function resolveTemplate(value, lookup) {
  return String(value ?? '').replace(/\{\{([^{}]+)\}\}/gu, (_, name) => {
    const resolved = lookup(name.trim())
    if (resolved === undefined || resolved === null || String(resolved) === '') {
      throw new Error(`OAuth2 setting refers to {{${name}}}, which has no value.`)
    }
    return String(resolved)
  })
}

function variableLookup(environment, collectionVariables = []) {
  const environmentValues = new Map((environment.values ?? []).filter((entry) => entry.enabled !== false).map((entry) => [entry.key, entry.value]))
  const collectionValues = new Map(collectionVariables.map((entry) => [entry.key, entry.value]))
  return (name) => {
    const fromEnvironment = environmentValues.get(name)
    if (fromEnvironment !== undefined && String(fromEnvironment) !== '') return fromEnvironment
    return collectionValues.get(name)
  }
}

// --- HTTP sign-in ---------------------------------------------------------------

class CookieJar {
  constructor() { this.cookies = new Map() }
  capture(response) {
    const headers = typeof response.headers.getSetCookie === 'function' ? response.headers.getSetCookie() : []
    for (const header of headers) {
      const pair = header.split(';', 1)[0]
      const index = pair.indexOf('=')
      if (index > 0) this.cookies.set(pair.slice(0, index).trim(), pair.slice(index + 1))
    }
  }
  header() { return [...this.cookies].map(([name, value]) => `${name}=${value}`).join('; ') }
}

async function send(jar, url, options = {}) {
  const headers = {...(options.headers ?? {})}
  if (jar.cookies.size) headers.Cookie = jar.header()
  const response = await fetch(url, {...options, headers, redirect: 'manual'})
  jar.capture(response)
  return response
}

const hiddenField = (html, name) => new RegExp(`name=["']${name}["']\\s+value=["']([^"']*)["']`, 'iu').exec(html)?.[1] ?? ''

/**
 * Authorization code with PKCE against a hosted authorization server, the same
 * way a browser does it: authorize, login page, login form, callback, token.
 */
export async function signInWithPkce({authUrl, tokenUrl, clientId, redirectUri, scope, username, password}) {
  const jar = new CookieJar()
  const verifier = randomBytes(48).toString('base64url')
  const challenge = createHash('sha256').update(verifier).digest('base64url')
  const state = randomBytes(18).toString('base64url')
  const authorize = new URL(authUrl)
  for (const [key, value] of Object.entries({
    response_type: 'code', client_id: clientId, redirect_uri: redirectUri, scope, state, prompt: 'login',
    code_challenge: challenge, code_challenge_method: 'S256',
  })) authorize.searchParams.set(key, value)

  const started = await send(jar, authorize)
  if (started.status < 300 || started.status >= 400) throw new Error(`${clientId}: authorize returned HTTP ${started.status}`)
  const loginPage = new URL(started.headers.get('location'), authorize)
  const page = await send(jar, loginPage)
  const html = await page.text()
  if (!page.ok) throw new Error(`${clientId}: login page returned HTTP ${page.status}`)
  const form = new URLSearchParams({
    username, password,
    session_id: loginPage.searchParams.get('session_id') ?? '',
    tab_id: hiddenField(html, 'tab_id'),
    session_code: hiddenField(html, 'session_code'),
    return_url: loginPage.searchParams.get('return_url') ?? '',
  })
  let response = await send(jar, new URL(loginPage.pathname, loginPage), {
    method: 'POST', headers: {'Content-Type': 'application/x-www-form-urlencoded'}, body: form,
  })
  let location = null
  for (let hop = 0; hop < 5; hop++) {
    if (response.status < 300 || response.status >= 400) throw new Error(`${clientId}: sign-in stopped at HTTP ${response.status}`)
    location = new URL(response.headers.get('location'), response.url || loginPage)
    if (location.searchParams.get('error') === 'invalid_credentials') throw new Error(`${clientId}: sign-in rejected: invalid credentials for ${username}`)
    if (location.href.startsWith(redirectUri)) break
    response = await send(jar, location)
  }
  if (!location?.href.startsWith(redirectUri)) throw new Error(`${clientId}: sign-in never returned to ${redirectUri}`)
  if (location.searchParams.get('state') !== state) throw new Error(`${clientId}: PKCE state mismatch`)
  const code = location.searchParams.get('code')
  if (!code) throw new Error(`${clientId}: no authorization code (${location.searchParams.get('error') ?? 'no error given'})`)
  const token = await send(jar, tokenUrl, {
    method: 'POST', headers: {'Content-Type': 'application/x-www-form-urlencoded'},
    body: new URLSearchParams({grant_type: 'authorization_code', code, redirect_uri: redirectUri, client_id: clientId, code_verifier: verifier}),
  })
  const json = await token.json().catch(() => ({}))
  if (!token.ok || !json.access_token) throw new Error(`${clientId}: token endpoint returned HTTP ${token.status}`)
  return json.access_token
}

/** Client credentials with the folder's own token request parameters (audiences). */
export async function clientCredentialsToken({tokenUrl, clientId, clientSecret, scope, params = []}) {
  const body = new URLSearchParams({grant_type: 'client_credentials', client_id: clientId, client_secret: clientSecret})
  if (scope) body.set('scope', scope)
  for (const param of params) {
    if (param.enabled === false) continue
    if (param.send_as && param.send_as !== 'request_body') throw new Error(`Unsupported token request parameter placement: ${param.send_as}`)
    body.append(param.key, param.value)
  }
  const response = await fetch(tokenUrl, {method: 'POST', headers: {'Content-Type': 'application/x-www-form-urlencoded'}, body})
  const json = await response.json().catch(() => ({}))
  if (!response.ok || !json.access_token) throw new Error(`${clientId}: client credentials returned HTTP ${response.status}`)
  return json.access_token
}

/** Set the tenant owner's password through the activation link from registration. */
export async function activateTenantOwner(activationLink, password) {
  const link = new URL(activationLink)
  const token = decodeURIComponent(link.hash.replace(/^#/u, ''))
  if (!token) throw new Error('The tenant owner activation link has no token fragment.')
  const response = await fetch(new URL('/api/account-actions/v1/complete', link.origin), {
    method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({token, password}),
  })
  if (!response.ok) throw new Error(`Tenant owner activation returned HTTP ${response.status}: ${await response.text()}`)
}

// --- Orchestration --------------------------------------------------------------

function parseArgs(argv) {
  const args = {passThrough: []}
  for (let index = 0; index < argv.length; index++) {
    const name = argv[index]
    const next = () => {
      const value = argv[++index]
      if (value === undefined) throw new Error(`${name} needs a value`)
      return value
    }
    switch (name) {
      case '--collection': args.collection = path.resolve(next()); break
      case '--environment': args.environment = path.resolve(next()); break
      case '--report-dir': args.reportDir = path.resolve(next()); break
      case '--runner': args.runner = path.resolve(next()); break
      case '--snapshots': args.snapshots = path.resolve(next()); break
      case '--working-dir': args.passThrough.push(name, path.resolve(next())); break
      case '--base-domain': args.passThrough.push(name, next()); break
      case '--update': args.passThrough.push(name); break
      default: throw new Error(`Unknown argument: ${name}`)
    }
  }
  if (!args.collection || !args.environment || !args.reportDir) {
    throw new Error('Usage: run-customer-postman-with-auth.mjs --collection FILE --environment FILE --report-dir DIR [--runner FILE] [--snapshots DIR] [--update] [--working-dir DIR] [--base-domain HOST]')
  }
  if (args.passThrough.includes('--update') && !args.snapshots) throw new Error('--update needs --snapshots.')
  args.runner ??= DEFAULT_RUNNER
  return args
}

function saveJson(file, value) {
  fs.mkdirSync(path.dirname(file), {recursive: true})
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`, {mode: 0o600})
}

function runPhase({args, label, collection, environment, tokens, workDir}) {
  const phaseDir = path.join(workDir, label)
  const reportDir = path.join(args.reportDir, label)
  const collectionFile = path.join(phaseDir, 'collection.json')
  const environmentFile = path.join(phaseDir, 'environment.json')
  const continuationFile = path.join(phaseDir, 'continuation.json')
  saveJson(collectionFile, instrumentRequests(collection))
  saveJson(environmentFile, environment)
  const childEnv = {...process.env}
  for (const [role, key] of Object.entries(TOKEN_KEYS)) {
    if (tokens[role]) childEnv[`EDK_E2E_ENV_${key}`] = tokens[role]
    else delete childEnv[`EDK_E2E_ENV_${key}`]
  }
  console.log(`\n=== Customer collection phase: ${label} ===`)
  // Each phase compares against its own snapshot directory: the runner reports snapshots
  // without a matching request as stale, and would otherwise flag the other phases' files.
  const snapshotArgs = args.snapshots ? ['--snapshots', path.join(args.snapshots, label)] : ['--skip-snapshots']
  const result = spawnSync(process.execPath, [
    args.runner, '--collection', collectionFile, '--environment', environmentFile,
    '--report-dir', reportDir, '--continuation-out', continuationFile, ...snapshotArgs, ...args.passThrough,
  ], {stdio: ['ignore', 'pipe', 'pipe'], env: childEnv, encoding: 'utf8', maxBuffer: 256 * 1024 * 1024})
  process.stdout.write(result.stdout ?? '')
  process.stderr.write(result.stderr ?? '')
  if (result.error) throw result.error
  if (result.status !== 0) throw new Error(`Phase '${label}' failed: the runner exited with ${result.status}.`)
  const junit = fs.existsSync(path.join(reportDir, 'junit.xml')) ? fs.readFileSync(path.join(reportDir, 'junit.xml'), 'utf8') : ''
  const continuation = readJson(continuationFile)
  // Tokens were injected for this run only; do not carry them into the next phase.
  continuation.environment.values = (continuation.environment.values ?? []).filter((entry) => !Object.values(TOKEN_KEYS).includes(entry.key))
  return {junit, continuation}
}

export async function main(argv = process.argv.slice(2)) {
  const args = parseArgs(argv)
  const collection = readJson(args.collection)
  const environment = readJson(args.environment)
  const lookup0 = variableLookup(environment)
  const credential = (environmentKey, processKey) => String(process.env[processKey] || lookup0(environmentKey) || '').trim()
  const operatorEmail = credential('operatorEmail', 'EDK_OPERATOR_EMAIL')
  const operatorPassword = credential('operatorPassword', 'EDK_OPERATOR_PASSWORD')
  const tenantOwnerPassword = credential('tenantOwnerPassword', 'EDK_TENANT_OWNER_PASSWORD')
  for (const [name, value] of Object.entries({operatorEmail, operatorPassword, tenantOwnerPassword})) {
    if (!value) throw new Error(`${name} is not set in the environment file or its EDK_ variable.`)
  }

  const phases = topLevelPhases(collection)
  const byRole = Object.fromEntries(phases.map((phase) => [phase.role, phase]))
  for (const role of ['operator', 'tenantOwner', 'serviceClient']) {
    if (!byRole[role]) throw new Error(`The collection has no top-level folder for the ${role} token.`)
  }
  const publicCollection = bearerize(collection)
  const leaves = requestLeaves(collection)
  const workDir = fs.mkdtempSync(path.join(os.tmpdir(), 'edk-customer-auth-'))
  fs.mkdirSync(args.reportDir, {recursive: true})
  const junitDocuments = []
  try {
    // Phase 1: platform operator.
    const operatorSettings = byRole.operator.settings
    const lookup1 = variableLookup(environment, collection.variable)
    const operatorToken = await signInWithPkce({
      authUrl: resolveTemplate(operatorSettings.authUrl, lookup1),
      tokenUrl: resolveTemplate(operatorSettings.accessTokenUrl, lookup1),
      clientId: resolveTemplate(operatorSettings.clientId, lookup1),
      redirectUri: resolveTemplate(operatorSettings.redirect_uri, lookup1),
      scope: resolveTemplate(operatorSettings.scope ?? 'openid', lookup1),
      username: operatorEmail,
      password: operatorPassword,
    })
    console.log('Platform operator signed in.')
    const phase1 = runPhase({
      args, label: 'platform-operator', collection: onlyFolders(publicCollection, [byRole.operator.name]),
      environment, tokens: {operator: operatorToken}, workDir,
    })
    junitDocuments.push(phase1.junit)

    // Phase 2: activate the tenant owner, then run the owner folder.
    const variables1 = phase1.continuation.collection.variable ?? []
    const lookup2 = variableLookup(phase1.continuation.environment, variables1)
    const activationLink = String(lookup2('ownerActivationLink') ?? '')
    if (!activationLink) {
      throw new Error('Registration returned no manual activation link. Run the gate without an email transport, or activate the owner first.')
    }
    await activateTenantOwner(activationLink, tenantOwnerPassword)
    const ownerSettings = byRole.tenantOwner.settings
    const tenantSlug = String(lookup2('tenantSlug') ?? '')
    const ownerEmail = String(lookup2('tenantOwnerEmail') || `admin@${tenantSlug}.example`)
    const ownerToken = await signInWithPkce({
      authUrl: resolveTemplate(ownerSettings.authUrl, lookup2),
      tokenUrl: resolveTemplate(ownerSettings.accessTokenUrl, lookup2),
      clientId: resolveTemplate(ownerSettings.clientId, lookup2),
      redirectUri: resolveTemplate(ownerSettings.redirect_uri, lookup2),
      scope: resolveTemplate(ownerSettings.scope ?? 'openid', lookup2),
      username: ownerEmail,
      password: tenantOwnerPassword,
    })
    console.log(`Tenant owner ${ownerEmail} activated and signed in.`)
    const phase2 = runPhase({
      args, label: 'tenant-owner',
      collection: mergeVariables(onlyFolders(publicCollection, [byRole.tenantOwner.name]), variables1),
      environment: phase1.continuation.environment, tokens: {tenantOwner: ownerToken}, workDir,
    })
    junitDocuments.push(phase2.junit)

    // Phase 3: the service client created in phase 2.
    const variables2 = phase2.continuation.collection.variable ?? []
    const lookup3 = variableLookup(phase2.continuation.environment, variables2)
    const serviceSettings = byRole.serviceClient.settings
    const serviceToken = await clientCredentialsToken({
      tokenUrl: resolveTemplate(serviceSettings.accessTokenUrl, lookup3),
      clientId: resolveTemplate(serviceSettings.clientId, lookup3),
      clientSecret: resolveTemplate(serviceSettings.clientSecret, lookup3),
      scope: serviceSettings.scope ? resolveTemplate(serviceSettings.scope, lookup3) : '',
      params: (serviceSettings.tokenRequestParams ?? []).map((param) => ({...param, value: resolveTemplate(param.value, lookup3)})),
    })
    console.log('Service client token issued.')
    const phase3 = runPhase({
      args, label: 'tenant-apis',
      collection: mergeVariables(onlyFolders(publicCollection, [byRole.serviceClient.name]), variables2),
      environment: phase2.continuation.environment, tokens: {serviceClient: serviceToken}, workDir,
    })
    junitDocuments.push(phase3.junit)

    const coverage = reconcileCoverage(leaves, junitDocuments.flatMap(executedIdentities))
    fs.writeFileSync(path.join(args.reportDir, 'junit.xml'), mergeJunit(junitDocuments, collection.info?.name))
    saveJson(path.join(args.reportDir, 'customer-auth-handoff.json'), {
      status: 'passed',
      phases: phases.map((phase) => ({folder: phase.name, token: phase.role})),
      ...coverage,
    })
    console.log(`\nCustomer collection finished: ${coverage.executed} of ${coverage.requests} requests executed, ` +
      `${coverage.skippedOptional.length} optional and ${coverage.skippedRequired.length} other requests skipped themselves, exit code 0.`)
    if (coverage.skippedRequired.length) console.log(`Self-skipped: ${coverage.skippedRequired.join('; ')}`)
  } finally {
    fs.rmSync(workDir, {recursive: true, force: true})
  }
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  main().catch((error) => {
    console.error(`ERROR: ${error.message}`)
    process.exit(1)
  })
}
