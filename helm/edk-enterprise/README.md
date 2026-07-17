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

Supply `--migration-values <path>` only when the release you are installing ships
an overlay. The one current case is the upgrade from 0.25.0-RC1 to 0.25.0-RC2.
The overlay `examples/upgrades/0.25.0-rc1-to-0.25.0-rc2-values.yaml` re-asserts
the public `serviceIdentity.anonymousPathPrefixes` that RC1 left empty, which is
what blocked tenant creation on RC1. It is applied after the site values so a
values file exported from RC1 cannot restore the broken list. It holds no Secret
values and must not be reused for later releases. Without an overlay, the
selected chart and maintained site values are authoritative. The full upgrade is
in [quickstart-kubernetes.md](../../docs/quickstart-kubernetes.md#upgrading-from-0250-rc1-to-0250-rc2).

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
| `database.tenant.existingSecret` | `edk-tenant-postgres` | Secret with credentials for the tenant workload database. |
| `auth.enabled` | `true` | Enables REST auth. |
| `auth.jwt.enabled` | `true` | Enables JWT auth environment wiring. |
| `grpc.enabled` | `true` | Renders inbound gRPC for platform, tenant-KMS, wallet-unit, and wallet-interaction, and renders gRPC peer endpoints for routed calls to those receivers. |
| `config.providers.platformConfigRemote.enabled` | `true` | Enables platform-owned remote config reads for every satellite/workload service. |
| `config.providers.tenantConfigDb.enabled` | `false` | Disables direct tenant-config DB reads on satellites so platform remains the config authority. |
| `issuerPipeline.existingSecret` | `""` | Required Secret name for issuer pipeline encryption and blind-index keys. |
| `platform.secretBackend.type` | `config-system-dev-only` | Application-admin secret backend. The development backend is rejected in production mode. |
| `license.installationId` | `""` | Optional explicit runtime pin to a known installation id. Leave empty for first-run setup; the protected bundle supplies the installation id. If set, it must match the installed license claims. |
| `networkPolicy.enabled` | `true` | Renders service ingress/egress NetworkPolicies. |
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
| `admin-console` | `true` | `admin-console` | Full operator UI on the platform host and isolated testing-console paths on instance hosts |

Customer deployments use one public Gateway. Tenant KMS, DID, tenant-AS,
wallet-unit, wallet-interaction, issuer, and verifier remain backing workloads
behind `platform.<baseDomain>` and `<tenant>.<baseDomain>` host/path routes.
Runtime probes are Kubernetes orchestration concerns and must not be published
as customer routes.

## East-West Service Identity

The chart renders internal service identity from one `serviceIdentity` contract:

| Value | Purpose |
| --- | --- |
| `serviceIdentity.internalClientExistingSecret` | Secret containing the shared confidential-client secret used by internal service clients. |
| `serviceIdentity.internalClientSecretKey` | Key in that Secret; defaults to `internal-client-secret`. |
| `serviceIdentity.clientIds.<service>` | OAuth client id each satellite presents to the platform AS for client-credentials service tokens. |
| `serviceIdentity.serviceIds.<service>` | Workload id the caller asserts as `X-Service-Id` on internal command transport. |
| `serviceIdentity.audiences.<service>` | JWT audience expected by the receiving service. |

These values drive platform internal OAuth clients, platform and receiver
header trust bindings, satellite service-token env, receiver audience env,
admin-console token-exchange audiences, and STS allowed audiences. Do not change
one without changing the others.

The receiver expected audience, route-requested audience, client default, and
additional allowlist are different controls. The receiver validates
`serviceIdentity.audiences.<receiver>`. A caller route requests that value with
`serviceTokenAudience`. The platform AS uses the internal registration key
`default-access-token-audience` when a `client_credentials` request omits an
audience and permits a non-default explicit target only through
`allowed-access-token-audiences`. The client id is also bound to the asserted
service id; `X-Service-Id` does not establish identity by itself.

The chart derives this strict registration matrix from the
`serviceIdentity.audiences` map:

| Caller | Client/service binding | Default | Allowed additional audiences |
| --- | --- | --- | --- |
| tenant-KMS | `clientIds.tenant-kms` / `serviceIds.tenant-kms` | `audiences.platform` | none |
| wallet-unit | `clientIds.wallet-unit` / `serviceIds.wallet-unit` | `audiences.platform` | none |
| tenant-AS | `clientIds.tenant-as` / `serviceIds.tenant-as` | `audiences.platform` | `audiences.tenant-kms` |
| DID | `clientIds.did` / `serviceIds.did` | `audiences.platform` | `audiences.tenant-kms` |
| issuer | `clientIds.issuer` / `serviceIds.issuer` | `audiences.platform` | `audiences.tenant-kms`, `audiences.wallet-interaction` |
| verifier | `clientIds.verifier` / `serviceIds.verifier` | `audiences.platform` | `audiences.tenant-kms`, `audiences.wallet-interaction` |
| wallet-interaction | `clientIds.wallet-interaction` / `serviceIds.wallet-interaction` | `audiences.platform` | `audiences.wallet-unit` |

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

Internal identity headers are not credentials. A receiver may honor
`X-Tenant-Id` or `X-Principal-Id` only after a bearer JWT validates, the token is
a workload token, its client id or subject is bound to the asserted
`X-Service-Id`, the token audience matches the receiver, and the receiver trust
policy permits that override.

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
runtime probes must stay internal or protected.

The Gateway has an exact `https-platform` listener for the operator host and a
separate wildcard `https` listener for tenant/satellite hosts. Platform routes
attach only to the exact listener; instance testing-console routes attach only
to the wildcard listener. The listener names are a stable contract across all
TLS modes (with `external` they carry HTTP), so HTTPRoutes attached by
`sectionName` keep working regardless of where TLS terminates.

### Admin console

The `admin-console` service is a Next.js standalone app under `/admin-console`.
The platform host receives the complete operator console. Wildcard instance
hosts receive the canonical public page
`/testing-console/{kind}/{instanceId}`. A page-only `URLRewrite` maps
`/testing-console` to `/admin-console/testing-console`; a separate rule forwards
only `/admin-console/api/oid4vci/v1/testing`,
`/admin-console/api/oid4vp/v1/testing`, `/admin-console/api/portal-oauth`,
required Next/public assets, and health. Both the Gateway route and
the application host guard enforce the allowlist; the backend endpoint registry
then validates the exact instance origin and disabled/public/AS-protected mode.
Normal platform admin UI, auth endpoints, callbacks, previews, tools, and generic
admin APIs are not routed or served on instance hosts.

The server obtains a dedicated `admin-console-portal-bff` client_credentials
token with the single `bff.oauth` scope and
`application-bff-oauth-client` audience. Its client secret comes from
`portalBff.existingSecret`; it is never included in browser configuration. The
platform backend provisions and startup-validates distinct A256GCM and HMAC key
aliases under `portalBff.kms`. The exact internal platform HTTP origin is passed
through the server-only allowlist; arbitrary insecure HTTP destinations remain
rejected.

On the Gateway API path the explicit `/admin-console` PathPrefix route is more
specific than the platform service's `/` catch-all, so `/admin-console/*` routes
to the console while everything else falls through to the platform. Instance
HTTPRoutes keep the public-page rewrite in its own rule so it cannot alter the
direct testing-console support paths described above. They provide no
`/admin-console/testing` compatibility alias.

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
