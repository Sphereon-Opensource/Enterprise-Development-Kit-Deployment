#!/usr/bin/env node

import {createHash, randomBytes} from 'node:crypto'
import {readFileSync, statSync, writeFileSync} from 'node:fs'
import {basename} from 'node:path'
import {pathToFileURL} from 'node:url'

function parseArgs(args) {
  const value = (name) => {
    const index = args.indexOf(name)
    return index >= 0 ? args[index + 1] : ''
  }
  return {
    platformUrl: value('--platform-url').replace(/\/+$/, ''),
    mailpitUrl: value('--mailpit-url').replace(/\/+$/, ''),
    environmentPath: value('--environment'),
    evidencePath: value('--evidence'),
    licenseBundlePath: value('--license-bundle'),
    preProvisioned: args.includes('--pre-provisioned'),
  }
}

function readEnvironment(path) {
  const environment = JSON.parse(readFileSync(path, 'utf8'))
  return new Map(
    (environment.values ?? [])
      .filter((entry) => entry?.key && entry.enabled !== false)
      .map((entry) => [entry.key, String(entry.value ?? '')]),
  )
}

export function classifySetupStatus(status, body) {
  if (status === 404) return {state: 'closed', productStateVerified: false}
  if (status !== 200) throw new Error(`Setup status returned unexpected HTTP ${status}`)
  if (
    !body ||
    typeof body !== 'object' ||
    body.gateOpen !== true ||
    !Array.isArray(body.firstTenantConfigMissingKeys) ||
    typeof body.emailConfigured !== 'boolean' ||
    typeof body.licenseConfigured !== 'boolean'
  ) {
    throw new Error('Setup status HTTP 200 did not contain the required structured open-gate product state')
  }
  return {state: 'open', productStateVerified: true}
}

function parseSetCookies(headers) {
  const values = typeof headers.getSetCookie === 'function'
    ? headers.getSetCookie()
    : [headers.get('set-cookie')].filter(Boolean)
  return values.flatMap((value) =>
    String(value).split(/,(?=\s*[^;,=\s]+=[^;,]+)/u),
  )
}

class CookieJar {
  constructor() {
    this.cookies = new Map()
  }

  capture(response) {
    for (const header of parseSetCookies(response.headers)) {
      const pair = header.split(';', 1)[0]
      const separator = pair.indexOf('=')
      if (separator > 0) this.cookies.set(pair.slice(0, separator).trim(), pair.slice(separator + 1).trim())
    }
  }

  header() {
    return [...this.cookies].map(([key, value]) => `${key}=${value}`).join('; ')
  }
}

function sameOriginLocation(platformUrl, location, label) {
  if (!location) throw new Error(`${label} did not return a Location header`)
  const resolved = new URL(location, platformUrl)
  if (resolved.origin !== new URL(platformUrl).origin) {
    throw new Error(`${label} redirected outside the configured platform origin`)
  }
  return resolved
}

function hiddenValue(html, name) {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&')
  const match = new RegExp(`name=["']${escaped}["']\\s+value=["']([^"']+)["']`, 'iu').exec(html)
  if (!match) throw new Error(`Hosted login page did not contain hidden input '${name}'`)
  return match[1]
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
}

async function responseBody(response) {
  const text = await response.text()
  if (!text) return {}
  try {
    return JSON.parse(text)
  } catch {
    return text
  }
}

async function mailpitMessages(fetchImpl, mailpitUrl) {
  const response = await fetchImpl(`${mailpitUrl}/api/v1/messages`, {headers: {Accept: 'application/json'}})
  if (!response.ok) throw new Error(`Mailpit message listing failed (HTTP ${response.status})`)
  const body = await response.json()
  return Array.isArray(body) ? body : (Array.isArray(body?.messages) ? body.messages : [])
}

async function findActivationLinkInMailpit(fetchImpl, mailpitUrl, platformUrl, baselineIds) {
  const platformOrigin = new URL(platformUrl).origin
  const deadline = Date.now() + 20_000
  while (Date.now() < deadline) {
    const messages = await mailpitMessages(fetchImpl, mailpitUrl)
    for (const message of messages) {
      if (!message?.ID || baselineIds.has(message.ID)) continue
      const detailResponse = await fetchImpl(
        `${mailpitUrl}/api/v1/message/${encodeURIComponent(message.ID)}`,
        {headers: {Accept: 'application/json'}},
      )
      if (!detailResponse.ok) continue
      const detail = await detailResponse.json()
      const content = `${detail?.HTML ?? ''}\n${detail?.Text ?? ''}`.replaceAll('&amp;', '&')
      const candidates = content.match(/https?:\/\/[^\s"'<>]+\/admin-console\/account-action#[^\s"'<>]+/giu) ?? []
      for (const candidate of candidates) {
        try {
          const activationUrl = new URL(candidate)
          if (
            activationUrl.origin === platformOrigin &&
            activationUrl.pathname === '/admin-console/account-action' &&
            activationUrl.hash.length > 1
          ) return activationUrl.href
        } catch {
          // Ignore unrelated or malformed links in the message body.
        }
      }
    }
    await new Promise((resolve) => setTimeout(resolve, 250))
  }
  return null
}

async function request(fetchImpl, platformUrl, jar, method, target, {body, headers = {}} = {}) {
  const url = target instanceof URL ? target : new URL(target, platformUrl)
  if (url.origin !== new URL(platformUrl).origin) throw new Error('Refusing setup request outside the platform origin')
  const cookie = jar?.header()
  const response = await fetchImpl(url, {
    method,
    headers: cookie ? {...headers, Cookie: cookie} : headers,
    body,
    redirect: 'manual',
  })
  jar?.capture(response)
  return response
}

export async function authenticateExactOperator({
  fetchImpl,
  platformUrl,
  operatorEmail,
  operatorPassword,
}) {
  const jar = new CookieJar()
  const verifier = randomBytes(48).toString('base64url')
  const challenge = createHash('sha256').update(verifier).digest('base64url')
  const state = randomBytes(18).toString('base64url')
  const redirectUri = `${platformUrl}/admin-console/callback`
  const authorize = new URL('/authorize', platformUrl)
  for (const [key, value] of Object.entries({
    response_type: 'code',
    client_id: 'platform-operator-cli',
    redirect_uri: redirectUri,
    scope: 'openid',
    state,
    prompt: 'login',
    code_challenge: challenge,
    code_challenge_method: 'S256',
  })) authorize.searchParams.set(key, value)

  const authorizeResponse = await request(fetchImpl, platformUrl, jar, 'GET', authorize)
  if (authorizeResponse.status !== 302) {
    const details = await responseBody(authorizeResponse)
    const detailText = typeof details === 'string'
      ? details.replace(/<[^>]*>/gu, ' ').replace(/\s+/gu, ' ').trim().slice(0, 500)
      : JSON.stringify(details)
    throw new Error(`Operator authorization did not start (HTTP ${authorizeResponse.status}): ${detailText}`)
  }
  const loginUrl = sameOriginLocation(platformUrl, authorizeResponse.headers.get('location'), 'Operator authorization')
  const loginPage = await request(fetchImpl, platformUrl, jar, 'GET', loginUrl)
  if (loginPage.status !== 200) throw new Error(`Hosted operator login did not render (HTTP ${loginPage.status})`)
  const loginHtml = await loginPage.text()
  const credentials = new URLSearchParams({
    username: operatorEmail,
    password: operatorPassword,
    session_id: loginUrl.searchParams.get('session_id') ?? '',
    tab_id: hiddenValue(loginHtml, 'tab_id'),
    session_code: hiddenValue(loginHtml, 'session_code'),
    return_url: loginUrl.searchParams.get('return_url') ?? '',
  })
  const loginResponse = await request(fetchImpl, platformUrl, jar, 'POST', '/login', {
    headers: {'Content-Type': 'application/x-www-form-urlencoded'},
    body: credentials,
  })
  if (loginResponse.status !== 302) {
    throw new Error(`Exact operator credentials were not accepted (HTTP ${loginResponse.status})`)
  }
  const callbackUrl = sameOriginLocation(platformUrl, loginResponse.headers.get('location'), 'Operator login')
  if (callbackUrl.pathname !== '/authorize/callback') {
    throw new Error('Exact operator login did not return to the authorization callback')
  }
  const callbackResponse = await request(fetchImpl, platformUrl, jar, 'GET', callbackUrl)
  if (callbackResponse.status !== 302) {
    throw new Error(`Operator authorization callback failed (HTTP ${callbackResponse.status})`)
  }
  const clientRedirect = sameOriginLocation(
    platformUrl,
    callbackResponse.headers.get('location'),
    'Operator authorization callback',
  )
  const code = clientRedirect.searchParams.get('code')
  if (!code || clientRedirect.searchParams.get('state') !== state) {
    throw new Error('Operator authorization callback did not return the expected code and state')
  }
  const tokenResponse = await request(fetchImpl, platformUrl, null, 'POST', '/token', {
    headers: {'Content-Type': 'application/x-www-form-urlencoded'},
    body: new URLSearchParams({
      grant_type: 'authorization_code',
      code,
      redirect_uri: redirectUri,
      client_id: 'platform-operator-cli',
      code_verifier: verifier,
    }),
  })
  const tokenBody = await responseBody(tokenResponse)
  if (!tokenResponse.ok || typeof tokenBody?.access_token !== 'string') {
    throw new Error(`Exact operator token exchange failed (HTTP ${tokenResponse.status})`)
  }
  const segments = tokenBody.access_token.split('.')
  if (segments.length < 2) throw new Error('Exact operator access token was not a JWT')
  const claims = JSON.parse(Buffer.from(segments[1], 'base64url').toString('utf8'))
  const roles = claims.roles ?? claims.realm_access?.roles ?? []
  if (!Array.isArray(roles) || !roles.includes('platform-admin')) {
    throw new Error('Authenticated operator token did not contain the platform-admin role')
  }
  return {
    operatorEmailSha256: createHash('sha256').update(operatorEmail.trim().toLowerCase()).digest('hex'),
    subject: String(claims.sub ?? ''),
    roles: ['platform-admin'],
  }
}

async function main(argv, fetchImpl = fetch) {
  const args = parseArgs(argv)
  if (
    !args.platformUrl ||
    !args.environmentPath ||
    !args.evidencePath ||
    (args.preProvisioned === !!args.licenseBundlePath)
  ) {
    throw new Error(
      'Usage: prepare-compose-postman-setup.mjs --platform-url URL --environment FILE ' +
        '--evidence FILE (--license-bundle ZIP | --pre-provisioned)',
    )
  }
  const platformOrigin = new URL(args.platformUrl)
  if (platformOrigin.protocol !== 'https:' || platformOrigin.pathname !== '/' || platformOrigin.search || platformOrigin.hash) {
    throw new Error('--platform-url must be one HTTPS origin without a path, query, or fragment')
  }

  const values = readEnvironment(args.environmentPath)
  const operatorEmail = values.get('operatorEmail')?.trim()
  const operatorPassword = values.get('operatorPassword') ?? ''
  const operatorDisplayName = values.get('operatorDisplayName')?.trim() || 'Platform Operator'
  if (!operatorEmail || !operatorPassword || /^PASTE-/iu.test(operatorPassword)) {
    throw new Error('The Postman environment must contain non-placeholder operatorEmail and operatorPassword values')
  }
  const evidence = {
    checkedAt: new Date().toISOString(),
    platformUrl: args.platformUrl,
    mode: args.preProvisioned ? 'pre-provisioned' : 'license-bundle',
    setupStatus: '',
    setupPerformed: false,
    productStateVerified: false,
    operatorAuthenticated: false,
    activationDeliveryState: null,
    activationSource: null,
    licenseBundle: args.licenseBundlePath ? {provided: true, consumed: false} : {provided: false, consumed: false},
  }
  const statusResponse = await request(fetchImpl, args.platformUrl, null, 'GET', '/api/platform/setup/v1/status', {
    headers: {Accept: 'application/json'},
  })
  const statusBody = await responseBody(statusResponse)
  const setup = classifySetupStatus(statusResponse.status, statusBody)
  evidence.setupStatus = setup.state
  evidence.productStateVerified = setup.productStateVerified

  if (setup.state === 'open') {
    if (args.preProvisioned) {
      throw new Error('Setup gate is open but --pre-provisioned was selected; provide a protected license bundle')
    }
    const stats = statSync(args.licenseBundlePath)
    if (!stats.isFile() || stats.size === 0) throw new Error('Protected license bundle must be a non-empty file')
    evidence.licenseBundle = {
      provided: true,
      consumed: false,
      bytes: stats.size,
      sha256: createHash('sha256').update(readFileSync(args.licenseBundlePath)).digest('hex'),
    }
    const importBundle = async (pathname) => {
      const form = new FormData()
      form.append(
        'bundle',
        new Blob([readFileSync(args.licenseBundlePath)], {type: 'application/zip'}),
        basename(args.licenseBundlePath),
      )
      const response = await request(fetchImpl, args.platformUrl, null, 'POST', pathname, {body: form})
      if (!response.ok) {
        const details = await responseBody(response)
        const detailText = typeof details === 'string' ? details : JSON.stringify(details)
        throw new Error(`POST ${pathname} failed (HTTP ${response.status}): ${detailText}`)
      }
    }
    await importBundle('/api/platform/setup/v1/license/import/preview')
    await importBundle('/api/platform/setup/v1/license/import')
    evidence.licenseBundle.consumed = true
    const mailpitBaseline = args.mailpitUrl
      ? new Set((await mailpitMessages(fetchImpl, args.mailpitUrl)).map((message) => message?.ID).filter(Boolean))
      : new Set()
    const bootstrapResponse = await request(fetchImpl, args.platformUrl, null, 'POST', '/api/platform/setup/v1/bootstrap', {
      headers: {Accept: 'application/json', 'Content-Type': 'application/json'},
      body: JSON.stringify({adminEmail: operatorEmail, adminDisplayName: operatorDisplayName}),
    })
    const bootstrapBody = await responseBody(bootstrapResponse)
    if (!bootstrapResponse.ok) {
      throw new Error(`Platform operator bootstrap failed (HTTP ${bootstrapResponse.status})`)
    }
    evidence.activationDeliveryState = bootstrapBody?.activation?.deliveryState ?? null
    let activationLink = bootstrapBody?.activation?.manualActivationLink
    if (activationLink) evidence.activationSource = 'api-manual'
    if (!activationLink && args.mailpitUrl) {
      activationLink = await findActivationLinkInMailpit(fetchImpl, args.mailpitUrl, args.platformUrl, mailpitBaseline)
      if (activationLink) evidence.activationSource = 'mailpit'
    }
    const separator = typeof activationLink === 'string' ? activationLink.indexOf('#') : -1
    if (separator < 0 || separator === activationLink.length - 1) {
      throw new Error(
        'Unattended setup requires the product bootstrap API to return a manual activation link; ' +
          'otherwise pre-provision the operator before running this gate',
      )
    }
    const completeResponse = await request(fetchImpl, args.platformUrl, null, 'POST', '/api/account-actions/v1/complete', {
      headers: {Accept: 'application/json', 'Content-Type': 'application/json'},
      body: JSON.stringify({token: activationLink.slice(separator + 1), password: operatorPassword}),
    })
    if (!completeResponse.ok) {
      throw new Error(`Platform operator activation failed (HTTP ${completeResponse.status})`)
    }
    evidence.setupPerformed = true
    const closedResponse = await request(
      fetchImpl,
      args.platformUrl,
      null,
      'GET',
      '/api/platform/setup/v1/status',
      {headers: {Accept: 'application/json'}},
    )
    if (closedResponse.status !== 404) {
      throw new Error(`Setup gate did not close after operator activation (HTTP ${closedResponse.status})`)
    }
    evidence.setupStatus = 'closed'
  }

  evidence.operatorIdentity = await authenticateExactOperator({
    fetchImpl,
    platformUrl: args.platformUrl,
    operatorEmail,
    operatorPassword,
  })
  evidence.operatorAuthenticated = true
  evidence.productStateVerified = true
  writeFileSync(args.evidencePath, `${JSON.stringify(evidence, null, 2)}\n`, 'utf8')
  console.log(
    `customer-compose-setup:${evidence.setupPerformed ? 'performed' : 'pre-provisioned'}:` +
      `operator-authenticated:bundle-${evidence.licenseBundle.consumed ? 'consumed' : 'not-consumed'}`,
  )
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2)).catch((error) => {
    const details = []
    for (let current = error; current; current = current.cause) {
      const message = current instanceof Error ? current.message : String(current)
      const code = typeof current?.code === 'string' ? `${current.code}: ` : ''
      details.push(`${code}${message}`)
    }
    console.error(details.join('\ncaused by: '))
    process.exitCode = 1
  })
}
