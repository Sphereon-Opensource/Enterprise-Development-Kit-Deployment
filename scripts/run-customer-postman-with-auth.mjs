#!/usr/bin/env node

// Private Newman adapter for the shipped customer projection. Postman's GUI
// OAuth helper is interactive; Newman is not. The public request graph and its
// assertions remain authoritative while source folders provide only auth setup.
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import {randomBytes, createHash} from 'node:crypto'
import {spawnSync} from 'node:child_process'

const arg = (name, fallback = '') => { const i = process.argv.indexOf(name); return i >= 0 ? (process.argv[i + 1] ?? '') : fallback }
const rawCollectionPath = arg('--collection')
const rawSourcePath = arg('--source')
const rawEnvironmentPath = arg('--environment')
const rawReportDir = arg('--report-dir')
if (!rawCollectionPath || !rawSourcePath || !rawEnvironmentPath || !rawReportDir) throw new Error('Usage: run-customer-postman-with-auth.mjs --collection FILE --source FILE --environment FILE --report-dir DIR [--runner FILE]')
const collectionPath = path.resolve(rawCollectionPath)
const sourcePath = path.resolve(rawSourcePath)
const environmentPath = path.resolve(rawEnvironmentPath)
const reportDir = path.resolve(rawReportDir)
const runner = path.resolve(arg('--runner', 'deploy/edk/e2e/runner/run-e2e.js'))

const read = file => JSON.parse(fs.readFileSync(file, 'utf8'))
const clone = value => structuredClone(value)
const env = read(environmentPath)
const value = key => String(env.values?.find(v => v.key === key)?.value ?? '').trim()
const setVar = (collection, key, val) => { const entry = (collection.variable ?? []).find(v => v.key === key); if (entry) entry.value = val; else (collection.variable ??= []).push({key, value: val, enabled: true}) }
const setEnvironmentVar = (environment, key, val) => { const entry = (environment.values ?? []).find(v => v.key === key); if (entry) entry.value = val; else (environment.values ??= []).push({key, value: val, enabled: true, type: 'default'}) }
const save = (file, object) => { fs.mkdirSync(path.dirname(file), {recursive: true}); fs.writeFileSync(file, `${JSON.stringify(object, null, 2)}\n`, {mode: 0o600}) }
function leaves(items, parents = [], out = []) { for (const item of items ?? []) item.item ? leaves(item.item, [...parents, item.name], out) : out.push({item, parents}); return out }
function onlyFolders(collection, names) { const c = clone(collection); c.item = c.item.filter(i => names.includes(i.name)); return c }
function mergeVariables(target, from) { const values = new Map((target.variable ?? []).map(v => [v.key, v])); for (const v of from.variable ?? []) values.set(v.key, clone(v)); target.variable = [...values.values()] }
function instrumentRequests(collection) {
  const c = clone(collection)
  const visit = (items, parents = []) => {
    for (const item of items ?? []) {
      if (item.item) visit(item.item, [...parents, item.name])
      else {
        const identity = [...parents, item.name].join(' > ')
        item.event ??= []
        item.event.push({listen: 'test', script: {type: 'text/javascript', exec: [`pm.test('__executed_request__ ${identity.replaceAll('\\', '\\\\').replaceAll("'", "\\'")}', () => {});`]}})
      }
    }
  }
  visit(c.item)
  return c
}
function executedRequestIdentities(reportDir) {
  const junit = path.join(reportDir, 'junit.xml')
  if (!fs.existsSync(junit)) return []
  const xml = fs.readFileSync(junit, 'utf8')
  // The marker text is repeated in the testcase's `classname` attribute for
  // every assertion in that request. Match only the testcase name attribute;
  // otherwise one real request is falsely counted twice (credential issuance
  // requests exposed this when the coverage gate saw four duplicate leaves).
  return [...xml.matchAll(/<testcase\s+name="(__executed_request__[^\"]*)"/g)].map(match => match[1].replaceAll('&gt;', '>').replaceAll('&amp;', '&').replaceAll('&quot;', '"'))
}
function bearerize(collection) {
  const c = clone(collection)
  const visit = (items, parents = [], inheritedAuth = null) => {
    for (const item of items ?? []) {
      const effectiveAuth = item.request?.auth ?? item.auth ?? inheritedAuth
      const nextParents = [...parents, item.name]
      if (item.item) { visit(item.item, nextParents, effectiveAuth); continue }
      if (effectiveAuth?.type !== 'oauth2') continue
      const top = nextParents[0] ?? ''
      // Subtenant administration remains a platform-admin operation even
      // though it is the last top-level customer folder.  Do not let the
      // ordinary tenant-AS client token bleed into platform tenant creation.
      const walletCredentialRequest = top.startsWith('03 Tenant application') &&
        (/Request .*credential|Issue transaction-code EuPid credential/u.test(item.name) || nextParents.some(name => name === '20 Authorization code through Keycloak (optional)'))
      const token = top.startsWith('01 Platform') || top.startsWith('04 Platform') || top.startsWith('05 Subtenants') ? 'platformAccessToken' : top.startsWith('02 Tenant owner') ? 'tenantBootstrapAccessToken' : walletCredentialRequest ? 'walletAccessToken' : 'tenantAccessToken'
      item.request.auth = {type: 'noauth'}; item.event ??= []; item.event.unshift({listen: 'prerequest', script: {type: 'text/javascript', exec: [`const token = String(pm.collectionVariables.get('${token}') || pm.environment.get('${token}') || '').trim();`, `if (!token) throw new Error('Missing private ${token} for customer request');`, `pm.request.headers.upsert({key: 'Authorization', value: 'Bearer ' + token});`]}})
    }
  }
  visit(c.item)
  return c
}
class Jar {
  constructor() { this.map = new Map() }
  capture(response) { const raw = response.headers.get('set-cookie') || ''; for (const part of raw.split(/,(?=\s*[^;,=\s]+=)/u)) { const pair = part.split(';', 1)[0]; const i = pair.indexOf('='); if (i > 0) this.map.set(pair.slice(0, i), pair.slice(i + 1)) } }
  header() { return [...this.map].map(([k, v]) => `${k}=${v}`).join('; ') }
}
async function exactOperatorToken(platformUrl, email, password) {
  const jar = new Jar(); const verifier = randomBytes(48).toString('base64url'); const challenge = createHash('sha256').update(verifier).digest('base64url'); const state = randomBytes(18).toString('base64url'); const redirect = `${platformUrl}/admin-console/callback`
  const request = async (url, options = {}) => { const headers = {...(options.headers ?? {})}; if (jar.header()) headers.Cookie = jar.header(); const response = await fetch(url, {...options, headers, redirect: 'manual'}); jar.capture(response); return response }
  const authorize = new URL('/authorize', platformUrl); for (const [k, v] of Object.entries({response_type: 'code', client_id: 'platform-operator-cli', redirect_uri: redirect, scope: 'openid', state, prompt: 'login', code_challenge: challenge, code_challenge_method: 'S256'})) authorize.searchParams.set(k, v)
  const a = await request(authorize); if (a.status !== 302) throw new Error(`operator authorization start HTTP ${a.status}`)
  const loginUrl = new URL(a.headers.get('location'), platformUrl); const login = await request(loginUrl); const html = await login.text(); const hidden = name => { const m = new RegExp(`name=["']${name}["']\\s+value=["']([^"']+)["']`, 'iu').exec(html); if (!m) throw new Error(`missing login field ${name}`); return m[1] }
  const body = new URLSearchParams({username: email, password, session_id: loginUrl.searchParams.get('session_id') ?? '', tab_id: hidden('tab_id'), session_code: hidden('session_code'), return_url: loginUrl.searchParams.get('return_url') ?? ''})
  const submitted = await request(new URL('/login', platformUrl), {method: 'POST', headers: {'Content-Type': 'application/x-www-form-urlencoded'}, body}); if (submitted.status !== 302) throw new Error(`operator login HTTP ${submitted.status}`)
  const cb = await request(new URL(submitted.headers.get('location'), platformUrl)); if (cb.status !== 302) throw new Error(`operator callback HTTP ${cb.status}`)
  const back = new URL(cb.headers.get('location'), platformUrl); if (back.searchParams.get('state') !== state) throw new Error('operator PKCE state mismatch')
  const token = await request(new URL('/token', platformUrl), {method: 'POST', headers: {'Content-Type': 'application/x-www-form-urlencoded'}, body: new URLSearchParams({grant_type: 'authorization_code', code: back.searchParams.get('code'), redirect_uri: redirect, client_id: 'platform-operator-cli', code_verifier: verifier})}); const json = await token.json(); if (!token.ok || !json.access_token) throw new Error(`operator token HTTP ${token.status}`); return json.access_token
}
function run(collection, environment, privateDir, evidenceDir, extra = []) {
  save(path.join(privateDir, 'private-collection.json'), instrumentRequests(collection)); save(path.join(privateDir, 'private-environment.json'), environment)
  const result = spawnSync(process.execPath, [runner, '--collection', path.join(privateDir, 'private-collection.json'), '--environment', path.join(privateDir, 'private-environment.json'), '--skip-snapshots', '--report-dir', evidenceDir, ...extra], {stdio: 'inherit', env: process.env})
  save(path.join(evidenceDir, 'executed-request-identities.json'), {requestIdentities: executedRequestIdentities(evidenceDir)})
  if (result.error) throw result.error; if ((result.status ?? 1) !== 0) throw new Error(`customer auth phase failed with exit code ${result.status}`)
}

const publicCollection = bearerize(read(collectionPath)); const source = read(sourcePath); const base = fs.mkdtempSync(path.join(os.tmpdir(), 'edk-customer-auth-')); fs.mkdirSync(reportDir, {recursive: true})
try {
  const operator = await exactOperatorToken(value('platformUrl') || `https://platform.${value('baseDomain')}`, value('operatorEmail'), value('operatorPassword')); setVar(publicCollection, 'platformAccessToken', operator)
  const registration = publicCollection.item.find(f => f.name === '01 Platform - create tenant')?.item?.find(i => i.name === '01 Register tenant')
  const registrationTest = registration?.event?.find(e => e.listen === 'test')
  if (!registrationTest) throw new Error('Public registration request has no test event for identity handoff')
  registrationTest.script.exec.push("if (result.created?.ownerIdentityId) pm.collectionVariables.set('tenantOwnerIdentityId', result.created.ownerIdentityId);")
  const checkpoint1 = path.join(base, 'tenant.json'); run(onlyFolders(publicCollection, ['00 Start here', '01 Platform - create tenant']), env, path.join(base, 'phase1'), path.join(reportDir, 'phase1'), ['--continuation-out', checkpoint1, '--through-item', '01 Platform - create tenant > 02 Get tenant onboarding status'])
  const state1 = read(checkpoint1); const state1Vars = new Map((state1.collection.variable ?? []).map(v => [v.key, v])); const activationLink = String(state1Vars.get('tenantOwnerActivationLink')?.value ?? ''); const activationFragment = activationLink.includes('#') ? decodeURIComponent(activationLink.split('#').slice(1).join('#')) : ''; if (!activationFragment) throw new Error('Public registration did not return a tenant owner activation link fragment'); state1Vars.set('tenantOwnerActivationToken', {key: 'tenantOwnerActivationToken', value: activationFragment, enabled: true}); const slug = String(state1Vars.get('tenantSubdomain')?.value ?? ''); if (!slug) throw new Error('Public registration state did not retain tenantSubdomain'); state1Vars.set('tenantOwnerEmail', {key: 'tenantOwnerEmail', value: 'admin@' + slug + '.example', enabled: true}); state1.collection.variable = [...state1Vars.values()]; const owner = onlyFolders(source, ['03 Tenant Owner Activation and Sign-in']); owner.item[0].item = owner.item[0].item.filter(i => i.name !== '07b Register walkthrough tenant service client'); mergeVariables(owner, state1.collection); run(owner, state1.environment, path.join(base, 'owner'), path.join(reportDir, 'owner'), ['--through-item', '03 Tenant Owner Activation and Sign-in > 07a Resolve tenant hosted authorization server', '--continuation-out', path.join(base, 'owner.json')])
  const state2 = read(path.join(base, 'owner.json')); const public2 = bearerize(publicCollection); mergeVariables(public2, state2.collection); const runClientId = String(state2.collection.variable.find(v => v.key === 'tenantSubdomain')?.value ?? 'tenant') + '-service-' + randomBytes(8).toString('hex'); const runClientSecret = randomBytes(32).toString('hex'); setVar(public2, 'tenantServiceClientId', runClientId); setVar(public2, 'tenantServiceClientSecret', runClientSecret); setEnvironmentVar(state2.environment, 'tenantServiceClientId', runClientId); setEnvironmentVar(state2.environment, 'tenantServiceClientSecret', runClientSecret); const checkpoint2 = path.join(base, 'owner-register.json'); run(onlyFolders(public2, ['02 Tenant owner - register application']), state2.environment, path.join(base, 'register'), path.join(reportDir, 'register'), ['--through-item', '02 Tenant owner - register application > 02 Register confidential tenant application', '--continuation-out', checkpoint2])
  const state3 = read(checkpoint2); const generatedClientId = String(state3.collection.variable.find(v => v.key === 'tenantServiceClientId')?.value ?? ''); const generatedClientSecret = String(state3.collection.variable.find(v => v.key === 'tenantServiceClientSecret')?.value ?? ''); if (!generatedClientId || !generatedClientSecret) throw new Error('Registration continuation did not retain generated tenant client credentials'); setEnvironmentVar(state3.environment, 'tenantServiceClientId', generatedClientId); setEnvironmentVar(state3.environment, 'tenantServiceClientSecret', generatedClientSecret); const token = onlyFolders(source, ['04 Tenant Service Token']); mergeVariables(token, state3.collection); const checkpoint3 = path.join(base, 'token.json'); run(token, state3.environment, path.join(base, 'token'), path.join(reportDir, 'token'), ['--through-item', '04 Tenant Service Token > 02 Tenant service token (client credentials)', '--continuation-out', checkpoint3])
  const state4 = read(checkpoint3); const remaining = onlyFolders(bearerize(publicCollection), ['03 Tenant application', '04 Platform - shared Azure vault (optional)', '05 Subtenants']); mergeVariables(remaining, state4.collection); run(remaining, state4.environment, path.join(base, 'public-remaining'), path.join(reportDir, 'public-remaining'))
  const projectedPublicRequests = leaves(publicCollection.item).length
  const publicPhaseDirs = ['phase1', 'register', 'public-remaining']
  const publicRequestIdentities = publicPhaseDirs.flatMap(name => {
    const file = path.join(reportDir, name, 'executed-request-identities.json')
    return fs.existsSync(file) ? read(file).requestIdentities : []
  })
  const executedPublicRequests = publicRequestIdentities.length
  const skippedOptionalRequests = projectedPublicRequests - executedPublicRequests
  if (executedPublicRequests + skippedOptionalRequests !== projectedPublicRequests) throw new Error('Public phase request coverage mismatch: executed ' + executedPublicRequests + ' plus skipped ' + skippedOptionalRequests + ', projection ' + projectedPublicRequests)
  save(path.join(reportDir, 'customer-public-auth-handoff.json'), {status: 'passed', projectedPublicRequests, executedPublicRequests, skippedOptionalRequests, publicRequestIdentities, authorityCoverage: {platformBootstrap: 'native PKCE operator', tenantOwnerBootstrap: 'native PKCE owner', tenantActions: 'tenant-AS client credentials'}, phases: ['platform discovery and registration', 'tenant owner PKCE', 'public owner client registration', 'tenant-AS client credentials', 'public tenant journey']})
} finally { fs.rmSync(base, {recursive: true, force: true}) }


