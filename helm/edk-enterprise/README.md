# EDK Enterprise Helm Chart

This chart deploys the EDK enterprise backing workloads:

- Platform setup/admin/config and platform authorization server
- Tenant KMS backing workload
- DID resolver and `did:web` hosting backing workload
- Tenant OAuth2 authorization-server backing workload
- OID4VCI issuer backing workload
- OID4VP verifier backing workload
- Admin console (operator web UI served at `platform.<baseDomain>/admin-console`)

These workload names are deployment components, not public service hosts. The
customer-facing contract is the Gateway route table: `platform.<baseDomain>`
for the operator/platform plane and `<tenant>.<baseDomain>` for tenant protocol
and authenticated API routes.

The chart does not deploy Postgres. Provide two existing PostgreSQL databases:
one platform/control-plane database and one tenant workload database, each with
its own credentials Secret. Never point the platform and tenant database values
at the same database in an enterprise deployment. Separate schemas inside one
database are not sufficient; tenant schemas belong inside the tenant workload
database, while platform state must live in its own logical database.

## Install

### One-shot install or upgrade

The deployment repository includes a Bash wrapper for Linux and macOS that
creates only missing Secret prerequisites, preserves existing keystore and
pipeline keys, backs up an installed release, lints and renders the chart,
rolls back a failed upgrade, waits for every Deployment, and can verify the
tenant DID document. It is not tied to a particular version transition:

```bash
export TARGET_IMAGE_TAG='<approved-release-tag>'

bash ./scripts/upgrade-helm.sh \
  --release sphereon-edk-enterprise \
  --namespace edk \
  --values ./customer-values.yaml \
  --image-tag "$TARGET_IMAGE_TAG" \
  --tenant-host abc.example.com
```

`--release` and `--namespace` are operator choices. `sphereon-edk-enterprise`
and `edk` are only the wrapper defaults; pass the release name and namespace this
install uses. For an upgrade, they must match the existing release.

The wrapper reads the installed `global.imageTag` and selects known migration
overlays automatically. RC1 to RC3 is performed as two ordered Helm revisions:
first RC2 with the RC1-to-RC2 overlay, then RC3 with both cumulative overlays.
The overlays are applied after site values so an old values export cannot restore
obsolete public path lists. The same cumulative set is reapplied on an RC2 or RC3
rerun, making the wrapper idempotent even when the original values file is reused.
`--migration-values` is only needed for an additional
overlay not already known to the wrapper. The direct procedure is in
[quickstart-kubernetes.md](../../docs/quickstart-kubernetes.md#upgrading-directly-from-0250-rc1-to-0250-rc3).

Secret management is a greenfield cutover. It does not import, adopt, backfill,
or dual-read provider state from an earlier release. Take a database snapshot
and remove obsolete secret-provider and secret-migration state before upgrading.
If live legacy state is detected, platform startup stops with a reset diagnostic.
The wrapper leaves the release stopped and never rolls application pods back
automatically. Restore the pre-upgrade database snapshots before an explicit
binary rollback.

Existing `internal-client-secret`, `keystore-password`, BFF credentials, and
issuer-pipeline keys are preserved. If an existing Secret is missing a key that
cannot be regenerated safely, the wrapper stops instead of rotating it.

### Direct Helm command

Create the registry credential and runtime Secrets described below before
running the example installation:

```bash
helm upgrade --install edk-enterprise ./helm/edk-enterprise \
  --namespace edk --create-namespace \
  -f ./helm/edk-enterprise/examples/shared-postgres-values.yaml
```

Customer deployments install this chart from the public Enterprise Development Kit
Deployment repository: <https://github.com/Sphereon-Opensource/Enterprise-Development-Kit-Deployment>.

Create a registry pull Secret (the examples use `edk-registry-credentials`) and
reference its name with `global.imagePullSecrets`.
Leave `global.imageRegistry` at `nexus.sphereon.com/edk-docker` unless your OEM,
MSP, or EDK distributor provides a private mirror. Do not set it to `sphereon`
or `docker.io/sphereon`; that points
Kubernetes at public Docker Hub, not the EDK enterprise registry.

Before installing, create the runtime Secret in the same namespace as the Helm
release. `edk-runtime-secrets` is an example Secret **name**, not an image or a
prepackaged file. It holds three independently generated values:

```powershell
kubectl --namespace edk create secret generic edk-runtime-secrets `
  --from-literal=internal-client-secret='<long-random-confidential-client-secret>' `
  --from-literal=admin-console-portal-bff-secret='<independent-long-random-portal-bff-secret>' `
  --from-literal=keystore-password='<long-random-pkcs12-password>'
```

The command is suitable for an evaluation namespace. For production, have the
cluster's secret-management mechanism create the same Kubernetes Secret and
keys; do not commit a rendered Secret or plaintext values to Git. Use at least
32 random bytes for each value.

Create the issuer-pipeline Secret separately. Its master KEK and blind-index
key must be distinct, independently generated 32-byte base64url values:

```powershell
kubectl --namespace edk create secret generic edk-issuer-pipeline-secrets `
  --from-literal=master-kek='<independent-32-byte-base64url-value>' `
  --from-literal=blind-index-key='<independent-32-byte-base64url-value>'
```

Then configure all Secret references:

```yaml
serviceIdentity:
  internalClientExistingSecret: edk-runtime-secrets
  internalClientSecretKey: internal-client-secret
keystore:
  existingSecret: edk-runtime-secrets
  passwordKey: keystore-password

issuerPipeline:
  existingSecret: edk-issuer-pipeline-secrets
  masterKekKey: master-kek
  blindIndexKey: blind-index-key
portalBff:
  existingSecret: edk-runtime-secrets
  clientSecretKey: admin-console-portal-bff-secret
```

`internal-client-secret` is shared by the platform authorization server and its
registered internal confidential clients. Satellites use it at the platform
token endpoint to obtain short-lived east-west bearer tokens; it is what causes
`SERVER_SERVICE_IDENTITY_CLIENT_SECRET` to be rendered. `keystore-password`
protects the platform and tenant-KMS software PKCS#12 stores and is rendered as
`EDK_KEYSTORE_PASSWORD`. `admin-console-portal-bff-secret` is a separate
credential used only by the dedicated `admin-console-portal-bff` client and the
admin-console server. Generate all three independently, keep them out of values
files and Git, and rotate them as credentials. The Secret name and key names may
be changed, but the referenced Secret and keys must already exist in the release
namespace. A Helm value change rolls the affected Deployments; when only Secret
data changes under the same name, restart the platform and satellite pods because
environment-variable Secret values are read only when a container starts.

## Main Values

| Value | Default | Purpose |
| --- | --- | --- |
| `global.imageRegistry` | `nexus.sphereon.com/edk-docker` | Registry root for all service images. Must not be `sphereon` or `docker.io/sphereon`. |
| `global.imageTag` | `0.25.0-SNAPSHOT` | Image tag used for all enterprise services. Production rejects `latest`; pin the approved tag supplied through your EDK distribution channel. |
| `global.imagePullPolicy` | `IfNotPresent` | Kubernetes image pull policy. Non-production `latest` requires `Always` to avoid silently reusing a stale node-local image. |
| `global.imagePullSecrets` | `[]` | Pull secrets rendered into every service pod. |
| `global.platformBaseDomain` | `example.com` | Customer-controlled base domain. The platform is `platform.<baseDomain>` and tenants are `<tenant-slug>.<baseDomain>`. |
| `database.enabled` | `true` | Enables database environment wiring. |
| `database.platform.existingSecret` | `edk-platform-postgres` | Secret with credentials for the control-plane (platform) database. |
| `database.secretManagement.existingSecret` | `edk-secret-management-database` | Secret with distinct passwords for the fixed non-superuser secret-management admin and tenant-serving runtime roles. Schema migration uses the platform database owner from `database.platform.existingSecret` only during startup. |
| `database.tenant.existingSecret` | `edk-tenant-postgres` | Secret with credentials for the tenant workload database. |
| `database.trustDomain.isolation` | `schema` | Isolation strategy for the trust-domain router registry (`database-trust-domain`). |
| `database.trustDomain.host` | `""` | Trust-domain database host override. Empty co-locates it on `database.platform.host`. |
| `database.trustDomain.existingSecret` | `""` | Trust-domain database Secret override. Empty co-locates it on `database.platform.existingSecret`. |
| `secretManagement.bootstrap.kek.mode` | `SOFTWARE_KMS` | Self-contained baseline backed by the persisted platform software KMS. External providers are configured explicitly and are not startup dependencies. |
| `secretManagement.bootstrap.kek.identity` | `secret-management-bootstrap-kek` | Server-owned software-KMS binding name; it is not a physical path or public API field. |
| `secretManagement.bootstrap.kek.kmsProviderId` | `software` | Persisted platform software KMS provider that owns the bootstrap key. |
| `secretManagement.authority.platformStorageKmsProviderId` | `software` | Persisted software KMS provider used by the active platform secret store. |
| `secretManagement.authority.platformStorageKmsBindingKey` | `platform-secret-storage` | Server-owned KMS capability binding for the active platform secret store. |
| `secretManagement.authority.allowPlatformOfferings` | `true` | Publishes the isolated per-tenant software-KMS offering. Vault and cloud offerings require explicit platform setup. |
| `secretManagement.egress.allowedHttpsPorts` | `[443]` | Platform-owned HTTPS ports permitted for provider traffic. |
| `secretManagement.egress.privateEndpointAllowlist` | `{}` | Reviewed hostname-pattern to CIDR-list map. Both DNS name and resolved address must match before private Vault or PrivateLink traffic is permitted. |
| `secretManagement.authority.defaultTenantOfferingKmsBindingTemplate` | `isolated-tenant-secret-storage` | Server-owned provisioner template; onboarding derives a distinct capability-bound KEK for every tenant binding. |
| `secretManagement.authority.allowTenantManagedProviders` | `false` | Cloud-provider offerings are absent by default. Enable only for an explicitly configured integration; tenant APIs cannot change the deployment bootstrap itself. |
| `secretManagement.authority.retentionDays` | `30` | Global migration retention period before an explicitly fenced purge. |
| `auth.enabled` | `true` | Enables REST auth. |
| `auth.jwt.enabled` | `true` | Enables JWT auth environment wiring. |
| `grpc.enabled` | `true` | Renders inbound gRPC for platform, tenant-KMS, wallet-unit, and wallet-interaction, and renders gRPC peer endpoints for routed calls to those receivers. |
| `config.providers.platformConfigRemote.enabled` | `true` | Enables platform-owned remote config reads for every satellite/workload service. |
| `config.providers.tenantConfigDb.enabled` | `false` | Disables direct tenant-config DB reads on satellites so platform remains the config authority. |
| `issuerPipeline.existingSecret` | `""` | Required Secret name for issuer pipeline encryption and blind-index keys. |
| `license.installationId` | `""` | Optional explicit runtime pin to a known installation id. Leave empty for first-run setup; the protected bundle supplies the installation id. If set, it must match the installed license claims. |
| `networkPolicy.enabled` | `true` | Renders service ingress/egress NetworkPolicies. |
| `networkPolicy.secretProviderEgress.enabled` | `true` | Enables platform-only egress to the mandatory Tier-0 KMS and provider endpoints. Pin in-cluster providers with selectors or external services with CIDRs where possible; an empty peer set permits only the configured ports and still relies on the runtime HTTPS/DNS/IP policy. |
| `networkPolicy.secretProviderEgress.ports` | `[443]` | TCP ports available to provider clients when provider egress is enabled. |
| `gateway.enabled` | `true` | Renders the single-port customer Gateway and HTTPRoutes. |
| `ingress.legacy.enabled` | `false` | Keeps legacy per-service Ingress off by default. |
| `serviceMonitor.enabled` | `false` | Renders Prometheus Operator ServiceMonitors. |
| `opentelemetry.enabled` | `false` | Renders OTLP exporter environment variables. |

## Service Values

Each service is configured under `services.<name>` where `<name>` is `platform`, `tenant-kms`, `did`, `tenant-as`, `wallet-unit`, `wallet-interaction`, `issuer`, `verifier`, or `admin-console`.

| Value | Purpose |
| --- | --- |
| `enabled` | Enable or disable the service. |
| `image` | Image repository name under `global.imageRegistry`. |
| `replicas` | Deployment replica count. |
| `restPort` | Internal container and Kubernetes Service REST port. Leave the default unless your OEM, MSP, or EDK distributor supplies an override; it is not a customer endpoint. |
| `publicIngress` | Legacy per-service ingress settings. Disabled by default; customer deployments use the Gateway. |
| `internalIngress` | Legacy internal ingress settings for private administrative/API endpoints. Disabled by default. |
| `resources` | Container requests and limits. |
| `env` | Extra container environment variables. |

Default backing components:

| Component | enabled | image | Backing responsibility |
| --- | --- | --- | --- |
| `platform` | `true` | `enterprise-platform` | Setup, license activation, platform admin/config, and platform authorization server |
| `tenant-kms` | `true` | `enterprise-tenant-kms` | Tenant key material and KMS command handling |
| `did` | `true` | `enterprise-did` | DID resolver and `did:web` hosting behind the tenant gateway |
| `tenant-as` | `true` | `enterprise-tenant-as` | Tenant OAuth2 authorization server behind the tenant gateway |
| `wallet-unit` | `true` | `enterprise-wallet-unit` | Server-side wallet-unit lifecycle and policy-gated wallet-key commands |
| `wallet-interaction` | `true` | `enterprise-wallet-interaction` | Headless wallet interaction runtime for issuer/verifier wallet protocol flows |
| `issuer` | `true` | `enterprise-issuer` | OID4VCI issuer routes behind the tenant gateway |
| `verifier` | `true` | `enterprise-verifier` | OID4VP verifier routes behind the tenant gateway |
| `admin-console` | `true` | `admin-console` | Platform operator UI on the platform host |
| `admin-console-tenant` | `true` | `admin-console` | Tenant-only UI and testing console on registered tenant hosts |

Customer deployments use one public Gateway. Tenant KMS, DID, tenant-AS,
wallet-unit, wallet-interaction, issuer, and verifier remain backing workloads
behind `platform.<baseDomain>` and `<tenant>.<baseDomain>` host/path routes.
Kubernetes uses the workload health endpoints inside the cluster. Do not
publish those endpoints as customer routes.

## East-West Service Identity

The chart renders internal service identity from one `serviceIdentity` contract:

| Value | Purpose |
| --- | --- |
| `serviceIdentity.internalClientExistingSecret` | Secret containing the shared confidential-client secret used by internal service clients. |
| `serviceIdentity.internalClientSecretKey` | Key in that Secret; defaults to `internal-client-secret`. |
| `serviceIdentity.clientIds.<service>` | OAuth client id each satellite presents to the platform AS for client-credentials service tokens. |
| `serviceIdentity.serviceIds.<service>` | Local workload label used to select and configure the service credential. It is not transmitted as identity metadata. |

These values drive platform internal OAuth clients, platform and receiver
validated-workload bindings, and satellite service-token credentials. Receiver
audiences are fixed protocol identifiers shared with source-level STS and
tenant-registration contracts; the chart does not expose audience overrides.

The receiver expected audience, route-requested audience, client default, and
additional allowlist are different controls. The receiver validates its
canonical `enterprise-<role>` audience. A caller route requests that value with
`serviceTokenAudience`. The platform AS uses the internal registration key
`default-access-token-audience` when a `client_credentials` request omits an
audience and permits a non-default explicit target only through
`allowed-access-token-audiences`. The validated JWT client id is also bound to
the configured local workload label.

The chart renders this fixed registration matrix:

| Caller | Client/service binding | Default | Allowed additional audiences |
| --- | --- | --- | --- |
| tenant-KMS | `clientIds.tenant-kms` / `serviceIds.tenant-kms` | `enterprise-platform` | none |
| wallet-unit | `clientIds.wallet-unit` / `serviceIds.wallet-unit` | `enterprise-platform` | none |
| tenant-AS | `clientIds.tenant-as` / `serviceIds.tenant-as` | `enterprise-platform` | `enterprise-tenant-kms` |
| DID | `clientIds.did` / `serviceIds.did` | `enterprise-platform` | `enterprise-tenant-kms` |
| issuer | `clientIds.issuer` / `serviceIds.issuer` | `enterprise-platform` | `enterprise-tenant-kms`, `enterprise-tenant-as` |
| verifier | `clientIds.verifier` / `serviceIds.verifier` | `enterprise-platform` | `enterprise-tenant-kms`, `enterprise-wallet-interaction` |
| wallet-interaction | `clientIds.wallet-interaction` / `serviceIds.wallet-interaction` | `enterprise-platform` | `enterprise-wallet-unit` |

An audience-free client-credentials request is valid only when its default is
nonblank. Exactly one requested audience is valid only when it equals the
default or is in the explicit additional allowlist. Missing defaults, multiple
or duplicate targets, and unregistered targets return HTTP 400
`invalid_target`. Do not repeat the default in the additional allowlist.

The chart now rejects a deployment with enabled satellite services when
`serviceIdentity.internalClientExistingSecret` is empty. It also rejects
platform/tenant-KMS deployments without `keystore.existingSecret`, and rejects
KMS-consuming services when `services.tenant-kms.enabled=false`. These are
render-time errors so an incomplete release cannot reach the tenant-registration
path with missing service Authorization headers.

Render-time validation cannot query the target namespace. When a configured
Secret name does not exist, Kubernetes leaves affected pods in
`CreateContainerConfigError` with `secret "<name>" not found`. When the Secret
exists without the configured key, events report `couldn't find key
internal-client-secret` or `couldn't find key keystore-password`. Inspect events
with `kubectl get events --namespace <namespace>
--sort-by=.metadata.creationTimestamp`; do not print Secret values into
diagnostic logs. Correct the Secret through the cluster's secret-management
mechanism and restart affected Deployments after changing data under an existing
Secret name.

Internal identity headers are never authority. A receiver derives tenant,
principal, and workload identity exclusively from a cryptographically validated
JWT. Legacy `X-Tenant-Id`, `X-Principal-Id`, and `X-Service-Id` metadata is
discarded and cannot override or supplement token claims.

DID, tenant-AS, issuer, and verifier use this contract for routed KMS commands.
Issuer and verifier use it for wallet-interaction calls, and wallet-interaction
uses it for wallet-unit calls. Their inbound bearer is addressed to the
route-only service, so the route asks the platform STS for a fresh workload JWT
addressed to the peer receiver audience instead of forwarding that inbound
bearer. During tenant-AS signing-key provisioning, the inbound platform JWT is
addressed to the tenant-AS provisioning endpoint and is terminated there; the
AS-to-KMS hop uses the `tenant-as-service` confidential client to mint the
tenant-KMS audience token.

A route-level `serviceTokenAudience` or
`preferServiceTokenOverSessionBearer=true` is an explicit workload-auth
requirement. A missing provider or token fails closed; the caller cannot fall
back to a session bearer, delegation, or anonymous transport. Likewise, setting
only some of `server.service-identity.token-endpoint`,
`server.service-identity.client-id`, and
`server.service-identity.client-secret` is an invalid partial identity, not a
disabled identity.

`platform.externalBaseUrl` is the canonical platform public origin and token
issuer. The chart renders platform `EXTERNAL_BASE_URL` and
`EDK_PLATFORM_PUBLIC_URL` from that value and fails rendering if
`platform.bootstrap.issuer` differs.

## Database Boundary

The platform database and tenant workload database are separate trust
boundaries. The platform database contains tenant registry, routing, public
endpoint, license/setup, platform configuration, and platform-AS state. The
tenant database contains runtime tenant workload state, with the default chart
using one schema per tenant inside that tenant database.

It is acceptable for both databases to run on the same managed PostgreSQL server
or database operator, but only as two database names with separate Secrets and
separately constrained access. Do not configure `database.platform.name` and
`database.tenant.name` to the same value. Do not mount platform database
credentials into tenant-KMS, DID, tenant-AS, issuer, or verifier pods. Do not
mount tenant database credentials into the platform pod.

The trust-domain router registry (`database-trust-domain`) is co-located on
the platform database by default: same host/name/Secret as `database.platform`,
only `isolation: schema` differs, so the connecting Postgres user needs CREATE
SCHEMA privilege. Set `database.trustDomain.host`/`name`/`existingSecret` to
split it onto a dedicated instance instead.

## Domain, Gateway, and TLS

The chart assumes one base domain for the installation. Set
`global.platformBaseDomain` to that base domain, then publish:

- `platform.<baseDomain>` for the platform/operator host.
- `*.<baseDomain>` for tenant hosts.

Tenant resolution is based on the inbound Host header. Gateway controllers,
Ingress controllers, ALBs, CDNs, and service meshes in front of the chart must
preserve the public Host header when forwarding to the services.

For TLS, use a wildcard certificate for `*.<baseDomain>` plus the platform host,
or individual certificates for every host. Wildcard TLS is the recommended
production model because onboarding a tenant only requires DNS and tenant
registration, not per-tenant certificate issuance. Public CAs such as Let's
Encrypt can be used; for cert-manager and Let's Encrypt wildcard certificates,
configure DNS-01 validation.

`gateway.tls.mode` selects where the certificate lives: `secret` references an
existing wildcard TLS Secret, `certManager` delegates issuance to a
cert-manager ClusterIssuer, and `external` is for installations where TLS
terminates outside the cluster (a corporate load balancer or edge proxy that
owns the wildcard certificate). With `external` the Gateway serves plain HTTP
on port 80, needs no in-cluster certificate, and `httpRedirect` is ignored
because the external front owns the redirect; that front must preserve the
Host header and set `X-Forwarded-Proto: https`. See
`examples/gateway-external-tls-values.yaml`.

The single-port Gateway API model is enabled by default with
`gateway.enabled=true` and `ingress.legacy.enabled=false`. Customer-visible
ingress is limited to platform and tenant host/path routes; admin REST and
workload health endpoints must stay private or protected.

The Gateway has an exact `https-platform` listener for the operator host and a
separate wildcard `https` listener for tenant/satellite hosts. Platform routes
attach only to the exact listener; instance testing-console routes attach only
to the wildcard listener. The listener names are a stable contract across all
TLS modes (with `external` they carry HTTP), so HTTPRoutes attached by
`sectionName` keep working regardless of where TLS terminates.

### Admin console

The chart runs the same Next.js image twice under `/admin-console`.
`admin-console` is the platform persona and receives the platform BFF
credential; `admin-console-tenant` is the tenant persona and deliberately
receives no platform client id or secret. Exact platform-host and wildcard
tenant-host HTTPRoutes always target different Services.

Tenant hosts also retain the canonical public page
`/testing-console/{kind}/{instanceId}`. A page-only `URLRewrite` maps
`/testing-console` to `/admin-console/testing-console`; a separate rule forwards
only `/admin-console/api/oid4vci/v1/testing`,
`/admin-console/api/oid4vp/v1/testing`, `/admin-console/api/portal-oauth`,
required Next/public assets, and health. Both the Gateway route and
the application host guard enforce the allowlist; the backend endpoint registry
then validates the exact instance origin and disabled/public/AS-protected mode.
The tenant runtime validates the exact registered host before OAuth and rejects
platform-management routes even though the complete tenant UI now uses the
same `/admin-console` path.

The server obtains a dedicated `admin-console-portal-bff` client_credentials
token with the single `bff.oauth` scope and
`application-bff-oauth-client` audience. Its client secret comes from
`portalBff.existingSecret`; it is never included in browser configuration. The
platform backend provisions and startup-validates distinct A256GCM and HMAC key
aliases under `portalBff.kms`. The exact internal platform HTTP origin is passed
through the server-only allowlist; arbitrary insecure HTTP destinations remain
rejected.

On the Gateway API path the platform `/admin-console` PathPrefix route is more
specific than the platform service's `/` catch-all, so `/admin-console/*` routes
to the operator console while everything else falls through to the platform.
The wildcard listener sends the same prefix to `admin-console-tenant`. Its
HTTPRoute keeps the public-page rewrite in its own rule so it cannot alter the
direct support paths described above. There is no
`/admin-console/testing` compatibility alias.

Use `gateway.platformAccess.routeAnnotations` to attach a controller-specific
IP-allowlist/WAF policy to every exact-platform HTTPRoute without affecting the
public wildcard tenant listener.

See `examples/admin-console-values.yaml`.

## Security Defaults

The chart defaults to:

- non-root UID/GID `10001`
- `readOnlyRootFilesystem: true`
- dropped Linux capabilities
- runtime default seccomp profile
- `/tmp` backed by an `emptyDir`
- REST auth enabled
- JWT auth environment wiring enabled
- NetworkPolicies enabled

Production values should set non-empty JWT issuer, JWKS URI, and audience values.

## Render Tests

Run from the deployment repository:

```powershell
helm template edk-enterprise .\helm\edk-enterprise `
  -f .\helm\edk-enterprise\examples\shared-postgres-values.yaml
```

The render suite covers default REST deployment, pull secrets, single-port
Gateway/HTTPRoute rendering, no legacy public service hosts, KMS internal-only
behavior, platform/KMS-only gRPC receiver rendering, external Postgres secret
wiring, resource/security defaults, NetworkPolicies, ServiceMonitor, and
OpenTelemetry values.
