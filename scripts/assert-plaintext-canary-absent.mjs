#!/usr/bin/env node

import {readFileSync} from 'node:fs'
import {pathToFileURL} from 'node:url'

function option(args, name) {
  const index = args.indexOf(name)
  return index >= 0 ? args[index + 1] : ''
}

export function postmanValues(environmentPath) {
  const document = JSON.parse(readFileSync(environmentPath, 'utf8'))
  return new Map(
    (document.values ?? [])
      .filter((entry) => entry?.key && entry.enabled !== false)
      .map((entry) => [String(entry.key), String(entry.value ?? '')]),
  )
}

function postgresCopyEscape(value) {
  return value
    .replaceAll('\\', '\\\\')
    .replaceAll('\b', '\\b')
    .replaceAll('\f', '\\f')
    .replaceAll('\n', '\\n')
    .replaceAll('\r', '\\r')
    .replaceAll('\t', '\\t')
    .replaceAll('\v', '\\v')
}

export function secretVariants(secret) {
  if (!secret) return []
  const jsonEscaped = JSON.stringify(secret).slice(1, -1)
  const variants = new Set([
    secret,
    jsonEscaped,
    postgresCopyEscape(secret),
    encodeURIComponent(secret),
  ])
  return [...variants].filter(Boolean)
}

export function findCanaryMatches(text, canary) {
  return secretVariants(canary).filter((variant) => text.includes(variant))
}

export function requireStableCanary(canary, label = 'canary') {
  if (!/^[A-Za-z0-9_-]{16,128}$/u.test(canary)) {
    throw new Error(
      `${label} must be an encoding-stable 16-128 character ASCII token using only letters, digits, '_' or '-'`,
    )
  }
}

async function main(args) {
  const environmentPath = option(args, '--environment')
  const canaryKey = option(args, '--canary-key')
  const environmentName = option(args, '--canary-env')
  const label = option(args, '--label')
  if (
    !/^[a-zA-Z][a-zA-Z0-9_.-]{1,127}$/u.test(canaryKey || environmentName) ||
    !/^[a-z0-9][a-z0-9-]{0,63}$/u.test(label) ||
    (!!environmentPath === !!environmentName)
  ) {
    throw new Error(
      'Usage: assert-plaintext-canary-absent.mjs ' +
        '(--environment FILE --canary-key KEY | --canary-env ENV_NAME) --label safe-label',
    )
  }
  const canary = environmentPath
    ? postmanValues(environmentPath).get(canaryKey)
    : process.env[environmentName]
  requireStableCanary(canary ?? '', canaryKey || environmentName)

  const chunks = []
  for await (const chunk of process.stdin) chunks.push(chunk)
  const text = Buffer.concat(chunks).toString('utf8')
  if (!text.trim()) throw new Error(`Plaintext-canary scan input was empty for ${label}`)
  const matches = findCanaryMatches(text, canary)
  if (matches.length > 0) {
    throw new Error(`PLAINTEXT_CANARY_EXPOSED_IN_${label.toUpperCase().replaceAll('-', '_')}`)
  }
  console.log(JSON.stringify({
    label,
    status: 'passed',
    checkedAt: new Date().toISOString(),
    checkedRepresentations: secretVariants(canary).length,
  }))
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2)).catch((error) => {
    console.error(error instanceof Error ? error.message : String(error))
    process.exitCode = 1
  })
}
