import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import test from 'node:test'

const source = readFileSync(new URL('./upgrade-helm.sh', import.meta.url), 'utf8')

test('immutable RC3 upgrades require and persist canonical release-set evidence', () => {
  assert.match(source, /--release-set-evidence PATH/)
  assert.match(source, /--release-set-evidence is required for immutable RC3 upgrades/)
  assert.match(source, /report\.tag !== process\.env\.RELEASE_REQUESTED_TAG/)
  assert.match(source, /build\.version !== process\.env\.RELEASE_REQUESTED_TAG/)
  assert.match(source, /report\.images\.length !== 7/)
  assert.match(source, /image\.localContentId/)
  assert.match(source, /sourceFingerprint/)
  assert.match(source, /enterprise-image-set\.json/)
  assert.match(source, /release-identity\.json/)
})

test('stateful upgrade establishes a release-wide barrier and never auto-rolls back migrated databases', () => {
  assert.match(source, /quiesce_release_deployments\(\)/)
  assert.match(source, /scale deployment -l "\$selector" --replicas=0/)
  assert.match(source, /wait --for=delete pod -l "\$selector"/)
  assert.equal(
    source.match(/quiesce_release_deployments/g)?.length,
    3,
    'the barrier must be defined and invoked before both supported upgrade paths',
  )
  assert.doesNotMatch(source, /--atomic/)
  assert.doesNotMatch(source, /--rollback-on-failure/)
  assert.match(source, /restore both database snapshots first/)
  assert.match(source, /explicit 'helm rollback'/)
})
