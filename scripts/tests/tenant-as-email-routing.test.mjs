import test from 'node:test'
import assert from 'node:assert/strict'
import {readFileSync} from 'node:fs'

// The tenant AS binds EmailService to the routed email commands and carries no email implementation. Its session
// graph resolves all three commands, so a missing route fails every sign-in with
// "No implementation for email.service.send at target LOCAL". These checks keep the three routes present and pointed
// at a service the kit really runs.
const EMAIL_COMMANDS = ['email.service.send', 'email.service.send-templated', 'email.service.is-available']

const read = (relative) => readFileSync(new URL(relative, import.meta.url), 'utf8').replaceAll('\r\n', '\n')

/** Lines of the mapping under `path` (keys from the document root), with the indentation of its entries. */
function mappingAt(source, path) {
  const lines = source.split('\n')
  let start = 0
  let end = lines.length
  let indent = -1
  for (const key of path) {
    let found = -1
    let childIndent = -1
    for (let i = start; i < end; i++) {
      const line = lines[i]
      if (!line.trim() || line.trim().startsWith('#')) continue
      const lineIndent = line.length - line.trimStart().length
      if (childIndent < 0) {
        assert.ok(lineIndent > indent, `No entries under ${path.join('.')}`)
        childIndent = lineIndent
      }
      if (lineIndent === childIndent && new RegExp(`^${escape(key)}:(\\s|$)`).test(line.trim())) {
        found = i
        break
      }
    }
    assert.ok(found >= 0, `Missing ${path.join('.')} (no '${key}')`)
    let next = found + 1
    while (next < end) {
      const line = lines[next]
      if (line.trim() && !line.trim().startsWith('#') && line.length - line.trimStart().length <= childIndent) break
      next++
    }
    start = found + 1
    end = next
    indent = childIndent
  }
  return lines.slice(start, end).filter((line) => line.trim() && !line.trim().startsWith('#'))
}

const escape = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')

/** The command entries of a `commands:` mapping, with YAML anchors and aliases of that mapping resolved. */
function commandRoutes(lines) {
  const entryIndent = lines[0].length - lines[0].trimStart().length
  const anchors = new Map()
  const routes = new Map()
  let current = null
  for (const line of lines) {
    const indent = line.length - line.trimStart().length
    const text = line.trim()
    if (indent === entryIndent) {
      const match = text.match(/^"\[([^\]]+)\]":\s*(?:&(\S+)|\*(\S+))?\s*$/)
      assert.ok(match, `Unexpected command entry: ${text}`)
      const [, commandId, anchor, alias] = match
      if (alias) {
        assert.ok(anchors.has(alias), `Alias *${alias} has no anchor in this mapping`)
        routes.set(commandId, anchors.get(alias))
        current = null
      } else {
        current = {}
        routes.set(commandId, current)
        if (anchor) anchors.set(anchor, current)
      }
    } else {
      assert.ok(current, `Field without a command entry: ${text}`)
      const field = text.match(/^([A-Za-z]+):\s*(.+)$/)
      assert.ok(field, `Unexpected route field: ${text}`)
      current[field[1]] = field[2].replace(/^["']|["']$/g, '')
    }
  }
  return routes
}

function composeService(compose, name) {
  const services = compose.match(/^services:\n([\s\S]*?)(?=^[A-Za-z][\w-]*:|$(?![\s\S]))/m)?.[1]
  assert.ok(services, 'docker-compose.yml has no services mapping')
  return services.match(new RegExp(`^  ${escape(name)}:\\n([\\s\\S]*?)(?=^  [A-Za-z][\\w-]*:|$(?![\\s\\S]))`, 'm'))?.[1]
}

test('compose tenant AS routes every email command to a service the kit runs', () => {
  const config = read('../../compose/config/tenant-as.application.yml')
  const compose = read('../../compose/docker-compose.yml')
  const modulePath = ['transport', 'routing', 'modules', 'email']
  const moduleFields = mappingAt(config, modulePath).map((line) => line.trim())
  const audience = moduleFields.map((line) => line.match(/^serviceTokenAudience:\s*(\S+)$/)?.[1]).find(Boolean)
  assert.ok(audience, 'The email module names no serviceTokenAudience')
  // Sign-in sessions are anonymous or carry a person's bearer; the platform admits these calls from the workload.
  assert.ok(moduleFields.includes('preferServiceTokenOverSessionBearer: true'))

  const routes = commandRoutes(mappingAt(config, [...modulePath, 'services', 'service', 'commands']))
  for (const commandId of EMAIL_COMMANDS) {
    const route = routes.get(commandId)
    assert.ok(route, `No route for ${commandId}`)
    assert.equal(route.target, 'SERVER', commandId)
    const endpoint = route.endpoint?.match(/^(grpc|http):\/\/([a-z0-9-]+):(\d+)$/)
    assert.ok(endpoint, `${commandId} has no usable endpoint: ${route.endpoint}`)
    const [, scheme, host, port] = endpoint
    assert.equal(route.transport, scheme.toUpperCase(), commandId)
    const service = composeService(compose, host)
    assert.ok(service, `${commandId} is routed to '${host}', which docker-compose.yml does not run`)
    if (scheme === 'grpc') {
      assert.match(service, /^\s+GRPC_ENABLED: "true"$/m, `${host} does not serve gRPC`)
      assert.match(service, new RegExp(`^\\s+GRPC_PORT: "${port}"$`, 'm'), `${host} does not serve gRPC on ${port}`)
    }
    assert.match(
      service,
      new RegExp(`^\\s+TRANSPORT_AUTH_EXPECTED_AUDIENCE: ${escape(audience)}$`, 'm'),
      `${host} does not accept tokens for audience ${audience}`,
    )
  }

  // The platform is the email owner; an email route in its own config would send these calls away from it again.
  const platform = read('../../compose/config/platform.application.yml')
  const platformModules = mappingAt(platform, ['transport', 'routing', 'modules']).map((line) => line.trimEnd())
  assert.ok(!platformModules.some((line) => /^ {6}email:/.test(line)), 'The platform must serve the email commands locally')
})

test('helm tenant AS routes every email command to the platform', () => {
  const source = read('../../helm/edk-enterprise/templates/configmap-tenant-as.yaml')
  const transportStart = source.indexOf('\n    transport:\n')
  assert.ok(transportStart >= 0, 'The tenant AS ConfigMap has no transport section')
  // Lines that hold only a template action carry no YAML of their own at their indentation.
  const template = source
    .slice(transportStart + 1)
    .split('\n')
    .filter((line) => !line.trim().startsWith('{{'))
    .join('\n')
  const modulePath = ['transport', 'routing', 'modules', 'email']
  const platformAudience = '{{ include "edk-enterprise.serviceAudience" (dict "root" . "name" "platform") | quote }}'
  const platformEndpoint =
    '{{ printf "grpc://%s:%v" (include "edk-enterprise.serviceName" (dict "root" . "name" "platform")) .Values.grpc.port | quote }}'
  const moduleFields = mappingAt(template, modulePath).map((line) => line.trim())
  assert.ok(moduleFields.includes(`serviceTokenAudience: ${platformAudience}`))
  assert.ok(moduleFields.includes('preferServiceTokenOverSessionBearer: true'))
  const routes = commandRoutes(mappingAt(template, [...modulePath, 'services', 'service', 'commands']))
  for (const commandId of EMAIL_COMMANDS) {
    const route = routes.get(commandId)
    assert.ok(route, `No route for ${commandId}`)
    assert.equal(route.target, 'SERVER', commandId)
    assert.equal(route.transport, 'GRPC', commandId)
    assert.equal(route.endpoint, platformEndpoint.replace(/^["']|["']$/g, ''), commandId)
  }
})
