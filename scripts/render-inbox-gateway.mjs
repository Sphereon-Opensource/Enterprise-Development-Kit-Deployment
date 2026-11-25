#!/usr/bin/env node
// Adds the optional tenant Inbox route to a rendered gateway routing table. The base deployment does not route the
// Inbox; run this only for a stack started with compose/docker-compose.inbox.yml, and point EDK_INBOX_GATEWAY_CONFIG
// at the output.
import fs from 'node:fs'
import path from 'node:path'
import {fileURLToPath} from 'node:url'

const traefikDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../compose/gateway/traefik')
const usage = 'Usage: node scripts/render-inbox-gateway.mjs --base-domain <dns> [--input <path>] [--output <path>]'
const label = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/

function sectionIndex(text, header) {
  const matches = [...text.matchAll(new RegExp(`^${header}:[ \\t]*\\r?$`, 'gm'))]
  return matches.length === 1 ? matches[0].index + matches[0][0].length + 1 : -1
}

function insertAfter(text, header, block) {
  const at = sectionIndex(text, header)
  return text.slice(0, at) + block + text.slice(at)
}

export function renderInboxGateway(base, baseDomain) {
  if (typeof baseDomain !== 'string' || baseDomain.length > 253 || !baseDomain.includes('.') ||
      !baseDomain.split('.').every(part => label.test(part))) {
    throw new Error('--base-domain must be a lowercase DNS name, for example acme.example.com')
  }
  if (typeof base !== 'string') throw new Error('the base routing table must be text')
  if (/^ {4}(inbox-[\w-]+|svc-inbox):/m.test(base)) throw new Error('the routing table already contains Inbox routes')
  if (['^http', '^  routers', '^  middlewares', '^  services'].some(header => sectionIndex(base, header) < 0)) {
    throw new Error('the routing table is missing required sections (one each of http, routers, middlewares and services)')
  }
  const eol = base.includes('\r\n') ? '\r\n' : '\n'
  const entryPoint = base.includes('entryPoints: ["websecure"]') ? 'websecure' : 'web'
  // Follow the base table's TLS form: a Let's Encrypt resolver, the static certificate store, or none behind an edge.
  const tls = /^ +tls:\r?\n +certResolver: le\r?$/m.test(base) ? ['      tls:', '        certResolver: le']
    : /^ +tls: \{\}\r?$/m.test(base) ? ['      tls: {}'] : []
  const host = `HostRegexp(\`^[a-z0-9-]+\\.${baseDomain.replaceAll('.', '\\.')}$\`)`
  const routers = [
    '    # Tenant Inbox API (optional Inbox overlay).',
    '    inbox-api:',
    '      rule: >-',
    `        ${host} &&`,
    '        PathPrefix(`/api/inbox/v1`)',
    `      entryPoints: ["${entryPoint}"]`,
    '      service: svc-inbox',
    '      priority: 310',
    ...tls,
    '',
  ]
  const services = [
    '    svc-inbox:',
    '      loadBalancer:',
    '        passHostHeader: true',
    '        servers:',
    '          - url: "http://vdx-inbox:8080"',
  ]
  const block = lines => lines.join(eol) + eol
  return insertAfter(insertAfter(base, '^  routers', block(routers)), '^  services', block(services))
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    let baseDomain
    let input = path.join(traefikDir, 'dynamic.yml')
    let output = path.join(traefikDir, 'dynamic.inbox.generated.yml')
    const args = process.argv.slice(2)
    for (let i = 0; i < args.length; i++) {
      const name = args[i]
      if (!['--base-domain', '--input', '--output'].includes(name)) throw new Error(`Unknown option: ${name}`)
      const value = args[++i]
      if (!value || value.startsWith('--')) throw new Error(`Missing value for ${name}`)
      if (name === '--base-domain') baseDomain = value
      else if (name === '--input') input = path.resolve(value)
      else output = path.resolve(value)
    }
    fs.writeFileSync(output, renderInboxGateway(fs.readFileSync(input, 'utf8'), baseDomain))
    console.log(`Rendered ${output}`)
  } catch (error) {
    console.error(`${error.message}\n${usage}`)
    process.exitCode = 1
  }
}
