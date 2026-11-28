# Upgrading a Docker Compose installation from 0.25.0 to 0.26.0-beta1

This guide covers an existing Docker Compose installation of 0.25.0 that keeps
its databases, keystores and secret-authority keys. 0.26.0-beta1 is a beta:
use it on a test installation, not in production.

An installation that still runs a 0.25.0 release candidate first upgrades to
0.25.0 with [the 0.25.0 guide](upgrade-0.25.0.md). The upgrade wrapper refuses
to go from a release candidate straight to 0.26.0, and it refuses a downgrade
from 0.26.0 to 0.25.0.

Helm installations use `scripts/upgrade-helm.sh`; see the
[Kubernetes quickstart](quickstart-kubernetes.md).

## Before you start: the license

0.26.0 accepts only licenses that chain to the production license root. A
license issued under the earlier test license authority, which some 0.25.0
evaluation installations use, is refused by 0.26.0-beta1 with the message
`this build does not accept test (TEST_CA) licences`. Ask your Sphereon contact
for a 0.26.0 license bundle for your base domain before you upgrade, and import
it after the upgrade as described in [After the upgrade](#after-the-upgrade).

## What stays the same

- The Compose project name (`edk-enterprise`), the service names and the named
  volumes: `platform-postgres-data`, `tenant-postgres-data`,
  `platform-keystore`, `tenant-kms-keystore` and `blob-store-data`. Keep all of
  them. The keystores hold key material that is not in the databases.
- The service set and the eight images, all from
  `nexus.sphereon.com/edk-docker` with one tag: `enterprise-platform`,
  `enterprise-tenant-as`, `enterprise-tenant-kms`, `enterprise-did`,
  `service-data` (the `enterprise-blob` service), `enterprise-issuer`,
  `enterprise-verifier` and `admin-console` (started twice).
- Networks, published ports and health checks.
- Your `.env`. No variable of the default stack was added, removed or renamed.
- The secret-authority key set in `EDK_SECRET_AUTHORITY_ROOT` and the four
  `SECRET_AUTHORITY_*` values. Do not generate a new key set.
- The secret-management environment manifests.

## What changes

### Compose files

- `docker-compose.yml`: the `enterprise-tenant-as`, `enterprise-blob`,
  `enterprise-issuer` and `enterprise-verifier` services now run their
  internal gRPC server (`GRPC_ENABLED: "true"`, `GRPC_PORT: "9090"`). The
  tenant authorization server reads tenant branding from the blob service,
  and the tenant authorization server, issuer and verifier call each other
  for invitations and interactive authorization. The ports are not
  published. Without these settings tenant sign-in and credential offers
  fail.
- `docker-compose.yml`: newer supporting images. PostgreSQL moves from
  `postgres:16-alpine` to the pinned `postgres:16.16-alpine` (same major
  version, the data directory is reused as is), the OpenTelemetry collector
  to `0.165.0` and Jaeger to `jaegertracing/jaeger:2.23.0`. Jaeger 2 no
  longer needs `COLLECTOR_OTLP_ENABLED`.
- `docker-compose.gateway.yml` (local certificate gateway): `enterprise-blob`
  gets the public URL settings, the local truststore and the certificate
  mount that the other services already had.
- The bundled Traefik gateways move from `v3.3` to `v3.7.20`. This includes
  the public certificate, Let's Encrypt and behind-edge Compose templates.
  If you use an external TLS edge, this updates the customer kit's gateway
  behind it. Keep your existing external edge configuration.

Take the 0.26.0-beta1 files. If you changed a Compose file, reapply your
change to the new file.

### Service configuration files

All seven files under `compose/config/` changed. Take the 0.26.0-beta1 files
and reapply your own changes to them. Do not keep the 0.25.0 files: services
call each other in ways the 0.25.0 files do not allow, for example the tenant
authorization server reading branding from the blob service and the verifier
starting invitation jobs at the issuer.

| File | Main changes |
| --- | --- |
| `platform.application.yml` | Wider token audiences for the internal clients (blob, verifier, tenant authorization server, tenant KMS). New internal routes for branding, DID assertion keys and federation signing. New connector vault store. New authorization policy block. |
| `tenant-as.application.yml` | Routes to the blob service for assets and to the platform for connectors and case approval. New design, schema and asset stores, each named explicitly. |
| `tenant-kms.application.yml` | Trusts the blob service and the federation signing service. New signing-authority routes. |
| `blob.application.yml` | Accepts calls from the platform and the tenant authorization server. Vault-managed key operations go to the tenant KMS. New theme administration rules and explicit store names. |
| `issuer.application.yml` | Trusts the tenant authorization server for invitation jobs. New invitation job rules and scheduler. Explicit store names. The issuer no longer waits for the `credential-design` and `statuslists` keyspaces at start-up. |
| `verifier.application.yml` | May call the issuer for invitation jobs. New connector and invitation job routes. |
| `did.application.yml` | One added service binding for the platform. |

### Gateway routes

The route table changed in `compose/gateway/traefik/dynamic.yml` and in the
public certificate, Let's Encrypt and behind-edge templates. Render the
route file again from the
0.26.0-beta1 template with the same command and base domain as at install. If
you operate your own reverse proxy, apply the same changes there.

| Path on a tenant host | Change | Service |
| --- | --- | --- |
| `/api/connector/v1` | Moved | Blob service to platform |
| `/api/claimmapping/v1` | Replaces `/api/v1/tabular-mapping-templates` | Blob service |
| `/api/modeling/v1`, `/api/organization/v1`, `/api/semanticmapping/v1`, `/api/tenants/` | Added | Platform |
| `/api/invitation` | Moved from the platform (`/api/invitation/v1/invitations`) | Tenant authorization server |
| `/api/invitation/v1/jobs`, `/api/invitation/v1/recipientsources` | Added | Issuer |
| `/public/trust-domain/v1` | Added, anonymous | Platform |
| OpenID Federation paths ending in `.well-known/openid-federation` or starting with `federation_` | Added | Platform |
| `/api/workflow/v1`, `/api/lifecycle/v1` | Removed | Platform |

0.25.0 routed `/api/workflow/v1` and `/api/lifecycle/v1` to the platform, but
this kit runs no workflow runtime, so nothing answered them. The workflow and
lifecycle execution APIs belong to VDX deployments. The forms API
(`/api/forms/v1`) stays on the platform. In the Helm chart both paths are
routed only when `integrations.workflow.enabled` is `true`.

On the platform host, `/api/party/v1` is new and goes to the tenant
authorization server, and `/api/connector/v1` is removed.

The tenant Developer Console rewrite is corrected in all three route files.
The manual correction from the
[0.25.0 troubleshooting procedure](troubleshooting-0.25.0.md) is no longer
needed after you render the 0.26.0-beta1 files.

### Database schema

You do not run migrations by hand. On its first start the 0.26.0-beta1 platform
migrates the platform database, the secret-management tables and every tenant
schema in the tenant database. The other services wait for the platform to
report healthy and only validate the schema; they never receive DDL
credentials. Take backups of both databases first: a schema that 0.26.0 has
migrated cannot be opened by 0.25.0 images.

The enterprise kit stops provisioning tables used exclusively by wallet
services. On upgrade, the platform removes these table groups only when
they are empty and no objects outside the group depend on them. It keeps
groups that hold data or have external dependencies and logs the reason.

### Credential designs have versions that you publish

In 0.26.0 a credential design has versions, and the issuer uses the
published version. This changes two things:

- **Existing designs keep working.** The upgrade publishes the current
  version of every design that 0.25.0 stored. Credential configurations,
  issuance templates and offers that use those designs issue as before, from
  the same design. You do not have to do anything.
- **A new design starts as a draft.** After
  `POST /api/credential-design/v1/designs/credentials`, publish it with
  `POST /api/credential-design/v1/designs/credentials/{designId}/versions/1/publish`
  before you issue from it. Until then a credential offer for its
  configuration is refused with `409` and the hosted type metadata
  (`/public/schema/vct/{vct}`) answers `404`. The Postman collection has the
  publish request in **Define your own credential**.

### Credential format identifier for W3C VCDM 2.0 JWT credentials

W3C VC credential formats were not part of a supported 0.25.0 deployment,
which issues SD-JWT VC and ISO mdoc credentials. This section only concerns
you if you configured a W3C VC credential on a test installation. SD-JWT VC
(`dc+sd-jwt`) and mdoc (`mso_mdoc`) are unchanged.

0.26.0 uses the W3C format identifiers this way:

| Credential | 0.25.0 | 0.26.0 |
| --- | --- | --- |
| W3C VCDM 2.0 as a JWT | `jwt_vc_json-ld` | `vc+jwt` |
| W3C VCDM 1.1 JSON-LD as a JWT | not available | `jwt_vc_json-ld`, with the VCDM 1.1 context in `credential_definition.@context` |
| W3C VCDM 1.1 as a JWT | `jwt_vc_json` | `jwt_vc_json` (unchanged) |

On its first start the 0.26.0-beta1 platform rewrites every credential
configuration that 0.25.0 stored with `jwt_vc_json-ld` to `vc+jwt`, once. The
credential that is issued does not change, and the credential configuration
identifiers (for example `Membership`) stay the same. What does change is
what clients see:

- Credential issuer metadata lists these configurations with
  `"format": "vc+jwt"`.
- A wallet or test client that selects a configuration by identifier keeps
  working. A client that filters or requests by the format string
  `jwt_vc_json-ld` must use `vc+jwt` for these credentials.
- A request that creates or updates a VCDM 2.0 JWT configuration with
  `jwt_vc_json-ld` is refused with
  `credential_definition.@context is required for jwt_vc_json-ld`. Send
  `vc+jwt`.

Credentials issued before the upgrade are not touched and stay valid: the
format identifier is not part of a credential.

### Breaking API changes

Check your integration against this list before you upgrade. The Postman
collection in this kit already uses the 0.26.0 calls. The list has three
parts:

1. **Must read:** calls that the 0.25.0 kit showed in its Postman collection
   or documentation. An integration built from the kit uses these.
2. **Check if you use them:** other issuer, verifier, design, organization
   unit and blob store calls.
3. **Everything else:** the forms, connector and lifecycle APIs were
   reachable through the 0.25.0 gateway but were not part of the kit's
   collection or documentation. Their changes are in
   [the full list](api-changes-0.26.0-beta1.md), which also repeats parts 1
   and 2 call by call. The 0.26.0-beta1 gateway no longer routes the
   lifecycle API (see [Gateway routes](#gateway-routes)).

#### Must read

**Credential offers use instance-scoped routes in beta1.** The 0.25.0 paths
return HTTP 404. Read the credential issuer ID with
`GET /api/oid4vci/v1/instances` and include it in every offer request.

| 0.25.0 | 0.26.0-beta1 |
| --- | --- |
| `POST /api/oid4vci/v1/backend/credential/offers` | `POST /api/oid4vci/v1/instances/{instanceId}/backend/credential/offers` |
| `GET /api/oid4vci/v1/backend/credential/offers/{correlation_id}` | `GET /api/oid4vci/v1/instances/{instanceId}/backend/credential/offers/{correlation_id}` |
| `DELETE /api/oid4vci/v1/backend/credential/offers/{correlation_id}` | `DELETE /api/oid4vci/v1/instances/{instanceId}/backend/credential/offers/{correlation_id}` |

The request and response bodies retain the same shape. The returned `status_uri` uses the instance-scoped status route.

**Issuer configuration writes require an instance ID.** Use `PUT`, `PATCH`
or `DELETE` on
`/api/platform/config/v1/tenants/{tenantId}/oid4vci/issuer/instances/{instanceId}/credential-config-settings/{credentialConfigurationId}`.
The corresponding writes without an issuer instance return HTTP 404.

**Update Trust Mark issuers through the operated federation.** Read the
operated federation and use its current version as `If-Match` when calling
`PUT /api/platform/config/v1/tenants/{tenantId}/openid-federation/federations/{federationId}/trustmarkissuers`.
Send the entire issuer map, including the entries you want to retain. The
per-issuer authorization and withdrawal POST paths have been removed. Create
an operated-federation record for a standalone Trust Anchor before using the
new operation.

**Use the beta1 action paths.** Update clients before sending requests to
beta1. The old KMS and blob action paths return HTTP 404.

| 0.25.0 `POST` path | 0.26.0-beta1 `POST` path |
| --- | --- |
| `/api/platform/config/v1/tenants/{tenantId}/kms/shared-providers/{providerId}:enable` | `/api/platform/config/v1/tenants/{tenantId}/kms/shared-providers/{providerId}/enable` |
| `/api/platform/config/v1/tenants/{tenantId}/kms/shared-providers/{providerId}:disable` | `/api/platform/config/v1/tenants/{tenantId}/kms/shared-providers/{providerId}/disable` |
| `/api/platform/config/v1/tenants/{tenantId}/kms/resources:attach` | `/api/platform/config/v1/tenants/{tenantId}/kms/resources/actions/attach` |
| `/api/blob-store/v1/blobs:search` | `/api/blob-store/v1/blobs/search?storeId={storeId}` |
| `/api/blob-store/v1/stores/{storeId}/blobs:verify` | `/api/blob-store/v1/stores/{storeId}/blobs/verify` |
| `/api/blob-store/v1/blobs:copy` | `/api/blob-store/v1/blobs/copy` |
| `/api/blob-store/v1/blobs:move` | `/api/blob-store/v1/blobs/move` |

The Enterprise Compose kit enables the four blob actions for tenant
administrators acting in their own tenant.

#### Check if you use them

**W3C VC format identifier.** A W3C VCDM 2.0 JWT credential uses `vc+jwt`
instead of `jwt_vc_json-ld`. See the section above.

**Removed.**

- `/api/v1/tabular-mapping-templates` returns HTTP 404. Migrate clients to
  `/api/claimmapping/v1/mappings` and convert template payloads to versioned
  claim mappings.
- `/api/platform/config/v1/tenants/{tenantId}/audiences` answers `404`.
  Audiences are not part of the enterprise installation.

**Mandatory claims are enforced.** When a credential design marks a claim as
mandatory, the issuer refuses a credential request whose offer did not supply
that claim, with `invalid_credential_request` and the list of missing claims.
0.25.0 issued the credential without the claim. Send every mandatory claim in
`credential_subject_data` when you create the offer.

**Changed fields.**

- Verification result,
  `GET /oid4vp/backend/auth/requests/{correlation_id}`: a value in
  `verified_data.credential_claims[].claims` can be any JSON value (object,
  array, number, boolean, null), not only a string.
- Issuance and verification templates: `spec.recipient_lookup_sources` is no
  longer accepted or returned.
- Credential designs: `bindings[].@context` can be a string or an array.
- DCQL preview: entries of `provenance[].generatedClaimPaths` are objects.
- Organization units: `parentOuId` is required when you create a unit other
  than the first of a tenant, and `PUT /api/party/v1/ou/{id}` no longer moves
  a unit. Use `POST /api/party/v1/ou/{id}/move`.
- Blob listing, `GET /api/blob-store/v1/stores/{storeId}/blobs`: the `prefix`
  query parameter is required.
- Issuer sessions, `POST /api/oid4vci/v1/backend/sessions`: the stage values
  `FORM_LIFECYCLE`, `FORM_ACTION_START`, `FORM_ACTION_COMPLETE` and
  `PORTAL_FLOW` are no longer accepted in
  `pipeline_configuration.invocationBindings[].stage`.

#### Everything else

The forms API (`/api/forms/v1`) and the connector API (`/api/connector/v1`)
changed many request and response field types, and a number of text fields
now accept only listed values. Generate your client again from the 0.26.0
OpenAPI documents if you use these APIs. Every change is in
[the full list](api-changes-0.26.0-beta1.md).

The DID API, the tenant KMS API and the verifier paths did not change in a
breaking way. Authentication, scopes, status codes and content types are
unchanged for every API.

### New optional overlays

The kit now also contains overlays for OpenID Federation
(`docker-compose.federation.yml`, `docker-compose.federation-publication-pdp.yml`)
and for the tenant Inbox (`docker-compose.inbox.yml`). They are not part of the
default stack and this upgrade does not need them. The secret generator adds
two `EDK_OIDFED_*` passwords to `.env`; the default stack does not read them.

The Inbox overlay adds the `vdx-inbox` service and the platform settings it
needs. Its image comes from the VDX image build, so set `VDX_REGISTRY` and
`VDX_TAG`, and set `EDK_INTERNAL_CLIENT_SECRET_INBOX` and
`EDK_INBOX_OPA_ENDPOINT`. Generate a secret-authority key for `service-inbox`
together with the base workloads. Then render the gateway table with the
Inbox route and start the stack with three Compose files:

```bash
node scripts/render-inbox-gateway.mjs --base-domain <domain> \
  --input compose/gateway/traefik/<rendered table> \
  --output compose/gateway/traefik/dynamic.inbox.generated.yml
cd compose
EDK_INBOX_GATEWAY_CONFIG=./gateway/traefik/dynamic.inbox.generated.yml docker compose \
  -f docker-compose.yml -f docker-compose.gateway.yml -f docker-compose.inbox.yml up -d
```

Workflows are not an overlay of this kit. The workflow worker, its Temporal
store and the tenant Portal are part of VDX deployments.

### Postman collection

The customer collection gained five requests: four under **Status lists**
(list credential issuers, read the issuer signing selection, create and fetch
a hosted bitstring status list) and one under **Trust domains** (fetch a
hosted mdoc VICAL). No request was removed and the environment file is
unchanged.

## Upgrade steps

1. Back up both PostgreSQL databases and the `platform-keystore`,
   `tenant-kms-keystore` and `blob-store-data` volumes. Keep a copy of `.env`
   and of the secret-authority directory.
2. Check out the 0.26.0-beta1 kit next to your current installation, or
   replace the kit files in place. Keep your `compose/.env` and your
   secret-authority directory.
3. Compare your `compose/config/*.yml` files with the 0.25.0 versions of the
   kit. Move any change you made into the 0.26.0-beta1 files.
4. Run `node scripts/generate-compose-secrets.mjs`. It keeps every existing
   value and adds only the two unused federation passwords.
5. If you use the public certificate or Let's Encrypt gateway, or the
   behind-edge overlay, render the route file again from the 0.26.0-beta1
   template.
6. Run the upgrade wrapper with the target tag and the same Compose file list
   you use for the installation:

   ```bash
   bash ./scripts/upgrade-compose.sh \
     --image-tag 0.26.0-beta1 \
     --compose-dir ./compose \
     --file ./compose/docker-compose.yml \
     --file ./compose/docker-compose.gateway.yml
   ```

   On Windows use `.\scripts\upgrade-compose.ps1 -ImageTag 0.26.0-beta1` with
   the same `-ComposeDir` and `-File` values. The wrapper detects 0.25.0,
   pulls the 0.26.0-beta1 images, starts the stack and waits for every
   service.
7. Set `EDK_TAG=0.26.0-beta1` in `.env` so later Compose commands use the same
   images.

## After the upgrade

- Import the 0.26.0 license bundle if your installation ran on a test license.
- Existing tenants keep their hosts, keys, DIDs, authorization servers,
  credential configurations and status lists.
- Remove `edk-compose-upgrade-backup` only after you have verified the
  installation and kept your database backups.

## Rolling back

There is no in-place downgrade. Stop the stack, restore both database backups
and the three volumes from step 1, put the 0.25.0 kit files back and start the
0.25.0 images with `--installed-image-tag 0.25.0`.
