#!/usr/bin/env node
import fs from 'node:fs'
import path from 'node:path'
import {fileURLToPath} from 'node:url'

const traefikDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../compose/gateway/traefik')
const usage = 'Usage: node scripts/render-federation-gateway.mjs --base-domain <dns> [--with-admin-console] [--behind-edge] [--output <path>]'

export function renderFederationGateway({baseDomain, withAdminConsole = false, behindEdge = false}) {
  const label = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/
  if (typeof baseDomain !== 'string' || baseDomain.length > 253 || !baseDomain.includes('.') ||
      !baseDomain.split('.').every(part => label.test(part))) {
    throw new Error('--base-domain must be a lowercase DNS name, for example fed.example.com')
  }
  let text = fs.readFileSync(path.join(traefikDir, 'dynamic.federation.template.yml'), 'utf8')
  if (!withAdminConsole) text = text.replace(/^ *# BEGIN admin-console\r?\n[\s\S]*?^ *# END admin-console\r?\n/gm, '')
  text = text.replaceAll('__BASE_DOMAIN_REGEX__', baseDomain.replaceAll('.', '\\.'))
    .replaceAll('__BASE_DOMAIN__', baseDomain)
  if (behindEdge) {
    text = text.replace(/^tls:\r?\n[\s\S]*?(?=^http:)/m, '')
      .replaceAll('entryPoints: ["websecure"]', 'entryPoints: ["web"]')
      .replace(/^ +tls: \{\}\r?\n/gm, '')
  }
  if (/__\w+__/.test(text)) throw new Error('Unresolved template placeholder')
  return text
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const options = {}
    let output = path.join(traefikDir, 'dynamic.federation.generated.yml')
    const args = process.argv.slice(2)
    for (let i = 0; i < args.length; i++) {
      switch (args[i]) {
        case '--base-domain':
        case '--output': {
          const name = args[i]
          const value = args[++i]
          if (!value || value.startsWith('--')) throw new Error(`Missing value for ${name}`)
          if (name === '--base-domain') options.baseDomain = value
          else output = path.resolve(value)
          break
        }
        case '--with-admin-console': options.withAdminConsole = true; break
        case '--behind-edge': options.behindEdge = true; break
        default: throw new Error(`Unknown option: ${args[i]}`)
      }
    }
    const text = renderFederationGateway(options)
    fs.writeFileSync(output, text)
    console.log(`Rendered ${output}`)
  } catch (error) {
    console.error(`${error.message}\n${usage}`)
    process.exitCode = 1
  }
}
