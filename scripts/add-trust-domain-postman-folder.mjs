/**
 * Adds the "22 Trust Domains" folder to the customer Postman collection.
 *
 * Idempotent: re-running replaces the folder rather than appending a second copy, so the script can
 * be re-applied after the collection is regenerated from OpenAPI.
 *
 * The folder deliberately starts from what tenant onboarding already seeded rather than building a
 * domain from nothing. Creating an anchor needs an identity-identifier id, and the only one a
 * customer installation is guaranteed to have at this point is the issuer material the onboarding
 * seeder materialized. Reading it first also makes the folder a genuine check on that seeder.
 */
import {readFileSync, writeFileSync} from 'node:fs'
import {fileURLToPath} from 'node:url'
import {dirname, join} from 'node:path'

const here = dirname(fileURLToPath(import.meta.url))
const collectionPath = join(here, '..', 'postman', 'EDK-Enterprise-Deployment.postman_collection.json')

const FOLDER_NAME = '22 Trust Domains'
const AUTH = [{key: 'Authorization', value: 'Bearer {{tenantOwnerToken}}'}]
const JSON_HEADERS = [...AUTH, {key: 'Content-Type', value: 'application/json'}]

const deriveBaseUrl = [
  "const gateway = String(pm.environment.get('tenantGatewayUrl') || pm.collectionVariables.get('tenantGatewayUrl') || '').trim().replace(/\\/+$/, '');",
  "pm.collectionVariables.set('tenantTrustDomainApiBaseUrl', gateway + '/api/trust-domain/v1');",
]

const req = (name, {method, url, description, body, headers, test, pre}) => {
  const item = {
    name,
    request: {
      method,
      url,
      description,
      header: headers || (body ? JSON_HEADERS : AUTH),
      ...(body ? {body: {mode: 'raw', raw: body}} : {}),
    },
    event: [],
  }
  if (pre) item.event.push({listen: 'prerequest', script: {type: 'text/javascript', exec: pre}})
  if (test) item.event.push({listen: 'test', script: {type: 'text/javascript', exec: test}})
  return item
}

const B = '{{tenantTrustDomainApiBaseUrl}}'

const items = [
  req('01 List trust domains', {
    method: 'GET',
    url: `${B}/domains`,
    description:
      'Reads the tenant trust-domain inventory. Onboarding seeds one issuer trust domain, so an empty list here means the sample-data seeder did not run or failed.',
    pre: deriveBaseUrl,
    test: [
      "pm.test('trust domains listed', () => pm.response.to.have.status(200));",
      'const items = pm.response.json().items || [];',
      "pm.test('the onboarding-seeded issuer trust domain exists', () => pm.expect(items.length).to.be.above(0));",
      "const seeded = items.find((d) => /issuer trust/i.test(d.displayName)) || items[0];",
      "pm.collectionVariables.set('trustDomainId', seeded.domainId);",
      "pm.collectionVariables.set('trustDomainVersion', String(seeded.version));",
      "pm.test('seeded domain is active', () => pm.expect(seeded.status).to.eql('ACTIVE'));",
    ],
  }),

  req('02 List anchors of the seeded domain', {
    method: 'GET',
    url: `${B}/domains/{{trustDomainId}}/anchors`,
    description:
      'Each entry pairs the stored anchor with an enforcement-safe identifier summary. The seeder creates one anchor per evidence mechanism from the issuer key material.',
    test: [
      "pm.test('anchors listed', () => pm.response.to.have.status(200));",
      'const items = pm.response.json().items || [];',
      "pm.test('seeded anchors present', () => pm.expect(items.length).to.be.above(0));",
      'const mechanisms = items.map((i) => i.anchor.evidenceMechanism);',
      "pm.test('issuer DID anchor seeded', () => pm.expect(mechanisms).to.include('DID'));",
      "const did = items.find((i) => i.anchor.evidenceMechanism === 'DID');",
      "pm.collectionVariables.set('trustAnchorId', did.anchor.anchorId);",
      "pm.collectionVariables.set('trustAnchorVersion', String(did.anchor.version));",
      "pm.collectionVariables.set('trustIdentityIdentifierId', did.anchor.identityIdentifierId);",
      "pm.test('seeded anchors are tenant-produced material', () => pm.expect(did.anchor.origin).to.eql('TENANT_PUBLIC'));",
    ],
  }),

  req('03 List admissions of the issuer anchor', {
    method: 'GET',
    url: `${B}/domains/{{trustDomainId}}/anchors/{{trustAnchorId}}/admissions`,
    description:
      'Membership in a domain is not admission. An anchor answers a usage only when it holds that usage admission class, so an empty list here would mean the anchor is inert.',
    test: [
      "pm.test('admissions listed', () => pm.response.to.have.status(200));",
      'const items = pm.response.json().items || [];',
      "pm.test('issuer anchor is admitted as CREDENTIAL_ISSUER', () =>",
      "  pm.expect(items.map((a) => a.admissionClass)).to.include('CREDENTIAL_ISSUER'));",
    ],
  }),

  req('04 Read the tenant issuer-trust attachment', {
    method: 'GET',
    url: `${B}/attachments/TENANT/{{tenantId}}/CREDENTIAL_ISSUER_TRUST`,
    description:
      'The tenant fallback is an ordinary attachment. A tenant with none fails closed on every credential-issuer decision, which is the state a brand-new tenant starts in.',
    test: [
      "pm.test('tenant attachment returned', () => pm.response.to.have.status(200));",
      'const body = pm.response.json();',
      "pm.test('tenant issuer trust is fail closed', () => pm.expect(body.attachment.policy.mode).to.eql('FAIL_CLOSED'));",
      "pm.test('tenant attachment selects the seeded domain', () =>",
      "  pm.expect(body.domains.map((d) => d.domainId)).to.include(pm.collectionVariables.get('trustDomainId')));",
      "pm.test('domain ordinals are contiguous from zero', () =>",
      "  pm.expect(body.domains.map((d) => d.order !== undefined ? d.order : d.ordinal)).to.eql(body.domains.map((_, i) => i)));",
    ],
  }),

  req('05 Read the verifier eligibility grant', {
    method: 'GET',
    url: `${B}/eligibility/OID4VP_VERIFIER/CREDENTIAL_ISSUER_TRUST`,
    description:
      'The grant caps which domains a verifier may select. It is governance, not selection, and is checked only against non-tenant attachments.',
    test: [
      "pm.test('eligibility grant returned', () => pm.response.to.have.status(200));",
      'const items = pm.response.json().items || [];',
      'const eligible = items.flatMap((g) => g.eligibleDomainIds || []);',
      "pm.test('seeded domain is eligible for verifiers', () =>",
      "  pm.expect(eligible).to.include(pm.collectionVariables.get('trustDomainId')));",
      "pm.collectionVariables.set('trustEligibilityVersion', String(items[0] ? items[0].version : 1));",
      "pm.collectionVariables.set('trustEligibilityGrantId', items[0] ? items[0].grantId : 'grant-verifier-issuer-trust');",
      "pm.collectionVariables.set('trustEligibleDomainIds', JSON.stringify(eligible));",
    ],
  }),

  req('06 List consumers of the seeded domain', {
    method: 'GET',
    url: `${B}/domains/{{trustDomainId}}/consumers`,
    description:
      'Reverse lookup used before disabling or deleting a domain. There is no pointer stored on the domain; this is a query over attachments.',
    test: [
      "const detail = () => pm.response.code + ' ' + pm.response.text();",
      "pm.test('consumers listed', () => pm.expect(pm.response.code, detail()).to.eql(200));",
      'const items = pm.response.json().items || [];',
      "pm.test('the tenant consumes the seeded domain', () =>",
      '// Each consumer is the whole attachment aggregate, so the kind sits on its attachment.',
      "  pm.expect(items.map((c) => (c.attachment || {}).consumerKind)).to.include('TENANT'));",
    ],
  }),

  req('07 Create a second trust domain', {
    method: 'POST',
    url: `${B}/domains`,
    description: 'New domains start as DRAFT. A draft domain can be attached but never resolves, because resolution requires ACTIVE.',
    body: JSON.stringify(
      {
        displayName: 'Postman mdoc VICAL domain',
        description: 'Created by the customer release gate to exercise attachments, eligibility and mdoc VICAL.',
      },
      null,
      2,
    ),
    test: [
      "pm.test('domain created', () => pm.expect(pm.response.code).to.be.oneOf([200, 201]));",
      'const d = pm.response.json();',
      "pm.collectionVariables.set('vicalDomainId', d.domainId);",
      "pm.collectionVariables.set('vicalDomainVersion', String(d.version));",
      "pm.test('new domains start as DRAFT', () => pm.expect(d.status).to.eql('DRAFT'));",
    ],
  }),

  req('08 Activate the second trust domain', {
    method: 'PUT',
    url: `${B}/domains/{{vicalDomainId}}`,
    description: 'Mutations are optimistically concurrent: the current version goes in If-Match and a stale value returns 412.',
    headers: [...JSON_HEADERS, {key: 'If-Match', value: '"{{vicalDomainVersion}}"'}],
    body: JSON.stringify(
      {
        domainId: '{{vicalDomainId}}',
        displayName: 'Postman mdoc VICAL domain',
        status: 'ACTIVE',
        version: '{{vicalDomainVersion}}',
      },
      null,
      2,
    ).replace('"version": "{{vicalDomainVersion}}"', '"version": {{vicalDomainVersion}}'),
    test: [
      "pm.test('domain activated', () => pm.response.to.have.status(200));",
      'const d = pm.response.json();',
      "pm.test('status is ACTIVE', () => pm.expect(d.status).to.eql('ACTIVE'));",
      "pm.collectionVariables.set('vicalDomainVersion', String(d.version));",
    ],
  }),

  req('09 Read the verifier issuer-trust attachment', {
    method: 'GET',
    url: `${B}/attachments/OID4VP_VERIFIER/{{tenantSlug}}/CREDENTIAL_ISSUER_TRUST`,
    description:
      'Onboarding attached the seeded issuer domain to this verifier. The next request updates that attachment, so it needs its current version and domain list.',
    test: [
      "const detail = () => pm.response.code + ' ' + pm.response.text();",
      "pm.test('verifier attachment returned', () => pm.expect(pm.response.code, detail()).to.eql(200));",
      'const current = pm.response.json();',
      "pm.collectionVariables.set('verifierAttachmentVersion', String(current.attachment.version));",
      "pm.collectionVariables.set('verifierAttachmentBody', JSON.stringify({",
      '  attachment: current.attachment,',
      "  domains: (current.domains || []).concat([{attachmentId: current.attachment.attachmentId, domainId: pm.collectionVariables.get('vicalDomainId'), ordinal: (current.domains || []).length}]),",
      '}));',
    ],
  }),

  req('09a Select a domain outside the verifier eligibility grant', {
    method: 'PUT',
    url: `${B}/attachments/OID4VP_VERIFIER/{{tenantSlug}}/CREDENTIAL_ISSUER_TRUST`,
    description:
      'Records where the governance cap actually binds. Selecting a domain the verifier grant does not list is accepted at authoring time; the cap is applied when trust is resolved, not when the attachment is written.',
    headers: [...JSON_HEADERS, {key: 'If-Match', value: '"{{verifierAttachmentVersion}}"'}],
    body: '{{verifierAttachmentBody}}',
    test: [
      "const detail = () => pm.response.code + ' ' + pm.response.text();",
      "pm.test('the selection is recorded', () => pm.expect(pm.response.code, detail()).to.eql(200));",
      "pm.test('the ineligible domain is on the attachment', () =>",
      "  pm.expect((pm.response.json().domains || []).map((d) => d.domainId)).to.include(pm.collectionVariables.get('vicalDomainId')));",
    ],
  }),

  req('10 Widen the verifier eligibility grant', {
    method: 'PUT',
    url: `${B}/eligibility/OID4VP_VERIFIER/CREDENTIAL_ISSUER_TRUST`,
    description: 'Grants must exist before delegated resource editors can select a domain. This adds the new domain to the existing grant.',
    headers: [...JSON_HEADERS, {key: 'If-Match', value: '"{{trustEligibilityVersion}}"'}],
    body: '{{trustEligibilityBody}}',
    pre: [
      "const existing = JSON.parse(pm.collectionVariables.get('trustEligibleDomainIds') || '[]');",
      "const added = pm.collectionVariables.get('vicalDomainId');",
      'const domains = existing.includes(added) ? existing : existing.concat([added]);',
      'const body = {',
      "  grantId: pm.collectionVariables.get('trustEligibilityGrantId'),",
      "  subjectConsumerKind: 'OID4VP_VERIFIER',",
      "  usage: 'CREDENTIAL_ISSUER_TRUST',",
      '  eligibleDomainIds: domains,',
      "  version: Number(pm.collectionVariables.get('trustEligibilityVersion') || 1),",
      '};',
      "pm.collectionVariables.set('trustEligibilityBody', JSON.stringify(body));",
    ],
    test: [
      "pm.test('eligibility grant widened', () => pm.response.to.have.status(200));",
      'const g = pm.response.json();',
      "pm.test('the new domain is now eligible', () =>",
      "  pm.expect(g.eligibleDomainIds).to.include(pm.collectionVariables.get('vicalDomainId')));",
      "pm.collectionVariables.set('trustEligibilityVersion', String(g.version));",
    ],
  }),

  req('11 Create a VICAL signer anchor', {
    method: 'POST',
    url: `${B}/domains/{{vicalDomainId}}/anchors`,
    description:
      'An anchor references public evidence by identity-identifier id rather than carrying raw material. This reuses the identifier the onboarding seeder already materialized.',
    body: JSON.stringify(
      {
        domainId: '{{vicalDomainId}}',
        identityIdentifierId: '{{trustIdentityIdentifierId}}',
        evidenceMechanism: 'DID',
        origin: 'IMPORTED',
        status: 'ACTIVE',
        metadata: {source: 'customer-release-gate', productRole: 'mdoc-vical-signer'},
      },
      null,
      2,
    ),
    test: [
      "pm.test('anchor created', () => pm.expect(pm.response.code).to.be.oneOf([200, 201]));",
      'const a = pm.response.json();',
      "pm.collectionVariables.set('vicalAnchorId', a.anchorId);",
      "pm.collectionVariables.set('vicalAnchorVersion', String(a.version));",
    ],
  }),

  req('12 Refuse a VICAL whose signer anchor is not admitted', {
    method: 'PUT',
    url: `${B}/domains/{{vicalDomainId}}/anchors/{{vicalAnchorId}}/mdoc-vical`,
    description:
      'Negative check on the ISO 18013-5 Annex C path. The anchor exists and is ACTIVE but holds no MDOC_VICAL_SIGNER admission, so it must not be usable to vouch for a whole certificate list.',
    body: JSON.stringify(
      {
        url: '{{vicalSourceUrl}}',
        signerAnchorIds: ['{{vicalAnchorId}}'],
        issuerAnchorIds: [],
        requiredCertificateProfiles: [],
        enabled: true,
      },
      null,
      2,
    ),
    test: [
      "pm.test('an unadmitted VICAL signer is refused', () => pm.expect(pm.response.code).to.be.within(400, 499));",
      "pm.test('the refusal names the missing admission', () =>",
      "  pm.expect(pm.response.text()).to.include('MDOC_VICAL_SIGNER'));",
    ],
  }),

  req('13 Admit the anchor as MDOC_VICAL_SIGNER', {
    method: 'PUT',
    url: `${B}/domains/{{vicalDomainId}}/anchors/{{vicalAnchorId}}/admissions/MDOC_VICAL_SIGNER`,
    description:
      'Admission is a separate decision from membership. MDOC_VICAL_SIGNER only lets the anchor verify a VICAL signature; it does not make it a credential issuer.',
    headers: [...JSON_HEADERS, {key: 'If-Match', value: '"{{vicalAnchorVersion}}"'}],
    body: JSON.stringify({anchorId: '{{vicalAnchorId}}', admissionClass: 'MDOC_VICAL_SIGNER'}, null, 2),
    test: [
      "const detail = () => pm.response.code + ' ' + pm.response.text();",
      "pm.test('admission granted', () => pm.expect(pm.response.code, detail()).to.eql(200));",
      "pm.test('admission class echoed', () => pm.expect(pm.response.json().admissionClass).to.eql('MDOC_VICAL_SIGNER'));",
    ],
  }),

  req('14 Read the unconfigured VICAL', {
    method: 'GET',
    url: `${B}/domains/{{vicalDomainId}}/anchors/{{vicalAnchorId}}/mdoc-vical`,
    description: 'An anchor with no VICAL reads as an unconfigured VICAL rather than a 404, so a client can render the empty form without a special case.',
    test: [
      "pm.test('unconfigured VICAL returned', () => pm.response.to.have.status(200));",
      'const v = pm.response.json();',
      "pm.test('no source is configured yet', () => pm.expect(v.source === null || v.source === undefined).to.be.true);",
    ],
  }),

  req('15 Configure the VICAL source', {
    method: 'PUT',
    url: `${B}/domains/{{vicalDomainId}}/anchors/{{vicalAnchorId}}/mdoc-vical`,
    description: 'The signer anchor now holds MDOC_VICAL_SIGNER, so the same body that was refused in step 12 is accepted.',
    body: JSON.stringify(
      {
        url: '{{vicalSourceUrl}}',
        signerAnchorIds: ['{{vicalAnchorId}}'],
        issuerAnchorIds: [],
        requiredCertificateProfiles: ['iso18013-5-iaca'],
        enabled: true,
      },
      null,
      2,
    ),
    test: [
      "const detail = () => pm.response.code + ' ' + pm.response.text();",
      "pm.test('VICAL configured', () => pm.expect(pm.response.code, detail()).to.eql(200));",
      'const v = pm.response.json();',
      "pm.test('the source round-trips', () => {",
      "  pm.expect(v.source.url).to.eql(pm.variables.replaceIn('{{vicalSourceUrl}}'));",
      "  pm.expect(v.source.signerAnchorIds).to.include(pm.collectionVariables.get('vicalAnchorId'));",
      "  pm.expect(v.source.enabled).to.be.true;",
      '});',
    ],
  }),

  req('16 Refuse a plain HTTP VICAL URL', {
    method: 'PUT',
    url: `${B}/domains/{{vicalDomainId}}/anchors/{{vicalAnchorId}}/mdoc-vical`,
    description: 'A VICAL is fetched over the network, so the URL must be absolute HTTPS. Userinfo and fragments are rejected for the same reason.',
    pre: [
      "const source = pm.variables.replaceIn('{{vicalSourceUrl}}');",
      "pm.collectionVariables.set('vicalHttpSourceUrl', source.replace(/^https:/i, 'http:'));",
    ],
    body: JSON.stringify(
      {url: '{{vicalHttpSourceUrl}}', signerAnchorIds: ['{{vicalAnchorId}}'], enabled: true},
      null,
      2,
    ),
    test: ["pm.test('plain HTTP is refused', () => pm.expect(pm.response.code).to.be.within(400, 499));"],
  }),

  req('17 Remove the VICAL configuration', {
    method: 'DELETE',
    url: `${B}/domains/{{vicalDomainId}}/anchors/{{vicalAnchorId}}/mdoc-vical`,
    description: 'Removing the VICAL leaves the anchor and its admission in place; only the source configuration goes away.',
    test: [
      "const detail = () => pm.response.code + ' ' + pm.response.text();",
      "pm.test('VICAL removed', () => pm.expect(pm.response.code, detail()).to.eql(200));",
      "pm.test('the anchor reads as unconfigured again', () => {",
      '  const v = pm.response.json();',
      '  pm.expect(v.source === null || v.source === undefined).to.be.true;',
      '});',
    ],
  }),

  req('18 Read the widened eligibility grant', {
    method: 'GET',
    url: `${B}/eligibility/OID4VP_VERIFIER/CREDENTIAL_ISSUER_TRUST`,
    description: 'The grant has moved on since request 05 widened it, so the narrowing below needs its current version.',
    test: [
      "const detail = () => pm.response.code + ' ' + pm.response.text();",
      "pm.test('widened grant returned', () => pm.expect(pm.response.code, detail()).to.eql(200));",
      'const g = (pm.response.json().items || [])[0];',
      "pm.expect(g, 'eligibility grant').to.be.an('object');",
      "const removed = pm.collectionVariables.get('vicalDomainId');",
      "pm.collectionVariables.set('trustEligibilityNarrowVersion', String(g.version));",
      "pm.collectionVariables.set('trustEligibilityNarrowBody', JSON.stringify({",
      '  grantId: g.grantId,',
      "  subjectConsumerKind: 'OID4VP_VERIFIER',",
      "  usage: 'CREDENTIAL_ISSUER_TRUST',",
      '  eligibleDomainIds: (g.eligibleDomainIds || []).filter((id) => id !== removed),',
      '  version: g.version,',
      '}));',
    ],
  }),

  req('18a Narrow the verifier eligibility grant back', {
    method: 'PUT',
    url: `${B}/eligibility/OID4VP_VERIFIER/CREDENTIAL_ISSUER_TRUST`,
    description:
      'A domain that a grant still lists cannot be deleted, and the gate has to leave the tenant as it found it. Removing the second domain from the grant does both.',
    headers: [...JSON_HEADERS, {key: 'If-Match', value: '"{{trustEligibilityNarrowVersion}}"'}],
    body: '{{trustEligibilityNarrowBody}}',
    test: [
      "const detail = () => pm.response.code + ' ' + pm.response.text();",
      "pm.test('eligibility grant narrowed', () => pm.expect(pm.response.code, detail()).to.eql(200));",
      "pm.test('the second domain is no longer eligible', () =>",
      "  pm.expect(pm.response.json().eligibleDomainIds || []).to.not.include(pm.collectionVariables.get('vicalDomainId')));",
    ],
  }),

  req('18b Read the verifier attachment before detaching', {
    method: 'GET',
    url: `${B}/attachments/OID4VP_VERIFIER/{{tenantSlug}}/CREDENTIAL_ISSUER_TRUST`,
    description: 'The attachment moved on when request 09a wrote to it, so the restore below needs its current version.',
    test: [
      "const detail = () => pm.response.code + ' ' + pm.response.text();",
      "pm.test('verifier attachment re-read', () => pm.expect(pm.response.code, detail()).to.eql(200));",
      'const current = pm.response.json();',
      "const removed = pm.collectionVariables.get('vicalDomainId');",
      "pm.collectionVariables.set('verifierRestoreVersion', String(current.attachment.version));",
      "const kept = (current.domains || []).filter((d) => d.domainId !== removed).map((d, i) => ({attachmentId: current.attachment.attachmentId, domainId: d.domainId, ordinal: i}));",
      "pm.collectionVariables.set('verifierRestoreBody', JSON.stringify({attachment: current.attachment, domains: kept}));",
    ],
  }),

  req('18c Detach the second domain from the verifier', {
    method: 'PUT',
    url: `${B}/attachments/OID4VP_VERIFIER/{{tenantSlug}}/CREDENTIAL_ISSUER_TRUST`,
    description:
      'Request 09a left the second domain on the verifier attachment. A referenced domain cannot be deleted, and the gate has to leave the tenant as it found it, so the attachment goes back to the seeded domain alone.',
    headers: [...JSON_HEADERS, {key: 'If-Match', value: '"{{verifierRestoreVersion}}"'}],
    body: '{{verifierRestoreBody}}',
    test: [
      "const detail = () => pm.response.code + ' ' + pm.response.text();",
      "pm.test('verifier attachment restored', () => pm.expect(pm.response.code, detail()).to.eql(200));",
      "pm.test('only the seeded domain remains', () =>",
      "  pm.expect((pm.response.json().domains || []).map((d) => d.domainId)).to.not.include(pm.collectionVariables.get('vicalDomainId')));",
    ],
  }),

  req('19 Delete the second trust domain', {
    method: 'DELETE',
    url: `${B}/domains/{{vicalDomainId}}`,
    description: 'Cleanup. Deleting the domain cascades its anchors and admissions, leaving the onboarding-seeded domain untouched.',
    headers: [...AUTH, {key: 'If-Match', value: '"{{vicalDomainVersion}}"'}],
    test: [
      "const detail = () => pm.response.code + ' ' + pm.response.text();",
      "pm.test('domain deleted', () => pm.expect(pm.response.code, detail()).to.eql(200));",
      "pm.test('delete is reported', () => pm.expect(pm.response.json().deleted).to.be.true);",
    ],
  }),

  req('20 Confirm the seeded domain survived', {
    method: 'GET',
    url: `${B}/domains/{{trustDomainId}}`,
    description: 'The gate must leave the tenant exactly as it found it apart from the eligibility grant it widened.',
    test: [
      "pm.test('seeded domain still present', () => pm.response.to.have.status(200));",
      "pm.test('seeded domain still active', () => pm.expect(pm.response.json().status).to.eql('ACTIVE'));",
    ],
  }),
]

const folder = {
  name: FOLDER_NAME,
  description:
    'Trust Domains V2: domains and anchors as evidence, admission classes as what that evidence may answer, attachments as who uses it, eligibility grants as the governance cap, and the ISO 18013-5 Annex C VICAL path. Runs after tenant onboarding because it starts from the seeded issuer trust domain.',
  item: items,
}

const collection = JSON.parse(readFileSync(collectionPath, 'utf8'))
collection.variable ??= []
if (!collection.variable.some((variable) => variable.key === 'vicalSourceUrl')) {
  collection.variable.push({
    key: 'vicalSourceUrl',
    value: 'https://vical.example.com/vical.cbor',
    type: 'string',
    description:
      "HTTPS URL of the published VICAL artifact used by the optional trust-domain example. Override it when running against a real published VICAL; it is not derived from the tenant host.",
  })
}
const existing = collection.item.findIndex((f) => f.name === FOLDER_NAME)
if (existing >= 0) collection.item.splice(existing, 1, folder)
else collection.item.push(folder)

writeFileSync(collectionPath, `${JSON.stringify(collection, null, 2)}\n`)
const total = collection.item.reduce((n, f) => n + (f.item ? f.item.length : 0), 0)
console.log(`${existing >= 0 ? 'replaced' : 'added'} "${FOLDER_NAME}" with ${items.length} requests; collection now has ${total} requests`)
