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

```powershell
helm upgrade --install edk-enterprise .\helm\edk-enterprise `
  --namespace edk --create-namespace `
  -f .\helm\edk-enterprise\examples\shared-postgres-values.yaml
```

Customer deployments install this chart from the public Enterprise Development Kit
Deployment repository: <https://github.com/Sphereon-Opensource/Enterprise-Development-Kit-Deployment>.

Create a Nexus pull secret and reference it with `global.imagePullSecrets`.
Leave `global.imageRegistry` at `nexus.sphereon.com/edk-docker` unless Sphereon gives you a
private mirror. Do not set it to `sphereon` or `docker.io/sphereon`; that points
Kubernetes at public Docker Hub, not the EDK enterprise registry.

## Main Values

| Value | Default | Purpose |
| --- | --- | --- |
| `global.imageRegistry` | `nexus.sphereon.com/edk-docker` | Registry root for all service images. Must not be `sphereon` or `docker.io/sphereon`. |
| `global.imageTag` | `0.25.0-SNAPSHOT` | Image tag used for all enterprise services. |
| `global.imagePullPolicy` | `IfNotPresent` | Kubernetes image pull policy. |
| `global.imagePullSecrets` | `[]` | Pull secrets rendered into every service pod. |
| `global.platformBaseDomain` | `example.com` | Customer-controlled base domain. The platform is `platform.<baseDomain>` and tenants are `<tenant-slug>.<baseDomain>`. |
| `database.enabled` | `true` | Enables database environment wiring. |
| `database.platform.existingSecret` | `edk-platform-postgres` | Secret with credentials for the control-plane (platform) database. |
| `database.tenant.existingSecret` | `edk-tenant-postgres` | Secret with credentials for the tenant workload database. |
| `auth.enabled` | `true` | Enables REST auth. |
| `auth.jwt.enabled` | `true` | Enables JWT auth environment wiring. |
| `grpc.enabled` | `true` | Renders inbound gRPC only for platform and tenant-KMS, and renders gRPC peer endpoints for routed calls to those receivers. |
| `config.providers.platformConfigRemote.enabled` | `true` | Enables platform-owned remote config reads for every satellite/workload service. |
| `config.providers.tenantConfigDb.enabled` | `false` | Disables direct tenant-config DB reads on satellites so platform remains the config authority. |
| `license.installationId` | `""` | Optional explicit runtime pin to a known installation id. Leave empty for first-run setup; the protected bundle supplies the installation id. If set, it must match the installed license claims. |
| `networkPolicy.enabled` | `true` | Renders service ingress/egress NetworkPolicies. |
| `gateway.enabled` | `true` | Renders the single-port customer Gateway and HTTPRoutes. |
| `ingress.legacy.enabled` | `false` | Keeps legacy per-service Ingress off by default. |
| `serviceMonitor.enabled` | `false` | Renders Prometheus Operator ServiceMonitors. |
| `opentelemetry.enabled` | `false` | Renders OTLP exporter environment variables. |

## Service Values

Each service is configured under `services.<name>` where `<name>` is `platform`, `tenant-kms`, `did`, `tenant-as`, `issuer`, `verifier`, or `admin-console`.

| Value | Purpose |
| --- | --- |
| `enabled` | Enable or disable the service. |
| `image` | Image repository name under `global.imageRegistry`. |
| `replicas` | Deployment replica count. |
| `restPort` | Internal container and Kubernetes Service REST port. Leave the default unless Sphereon supplies an override; it is not a customer endpoint. |
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
| `issuer` | `true` | `enterprise-issuer` | OID4VCI issuer routes behind the tenant gateway |
| `verifier` | `true` | `enterprise-verifier` | OID4VP verifier routes behind the tenant gateway |
| `admin-console` | `true` | `admin-console` | Operator UI behind `platform.<baseDomain>/admin-console` |

Customer deployments use one public Gateway. Tenant KMS, DID, tenant-AS, issuer,
and verifier remain backing workloads behind `platform.<baseDomain>` and
`<tenant>.<baseDomain>` host/path routes. Runtime probes are Kubernetes
orchestration concerns and must not be published as customer routes.

## East-West Service Identity

The chart renders internal service identity from one `serviceIdentity` contract:

| Value | Purpose |
| --- | --- |
| `serviceIdentity.internalClientExistingSecret` | Secret containing the shared confidential-client secret used by internal service clients. |
| `serviceIdentity.clientIds.<service>` | OAuth client id each satellite presents to the platform AS for client-credentials service tokens. |
| `serviceIdentity.serviceIds.<service>` | Workload id the caller asserts as `X-Service-Id` on internal command transport. |
| `serviceIdentity.audiences.<service>` | JWT audience expected by the receiving service. |

These values drive platform internal OAuth clients, platform and tenant-KMS
header trust bindings, satellite service-token env, receiver audience env,
admin-console token-exchange audiences, and STS allowed audiences. Do not change
one without changing the others.

Internal identity headers are not credentials. A receiver may honor
`X-Tenant-Id` or `X-Principal-Id` only after a bearer JWT validates, the token is
a workload token, its client id or subject is bound to the asserted
`X-Service-Id`, the token audience matches the receiver, and the receiver trust
policy permits that override.

DID, tenant-AS, issuer, and verifier use this contract for routed KMS commands.
Their inbound bearer is addressed to the route-only service, so the KMS route
asks the platform STS for a fresh workload JWT addressed to the tenant-KMS
receiver audience instead of forwarding that inbound bearer. During tenant-AS
signing-key provisioning, the inbound platform JWT is addressed to the tenant-AS
provisioning endpoint and is terminated there; the AS-to-KMS hop uses the
`tenant-as-service` confidential client to mint the tenant-KMS audience token.

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

The single-port Gateway API model is enabled by default with
`gateway.enabled=true` and `ingress.legacy.enabled=false`. Customer-visible
ingress is limited to platform and tenant host/path routes; admin REST and
runtime probes must stay internal or protected.

### Admin console

The `admin-console` service is a Next.js standalone web UI served under the
`/admin-console` basePath (the root `/` returns 404). It is a single
host-agnostic build: the OIDC authorization-server origin resolves from the
request host behind the gateway, while platform-admin, platform-config, tenant-KMS,
and DID API calls default to `/admin-console/api/*`. The chart injects
internal platform, tenant KMS, and DID upstreams for that server-side proxy. It is
fronted on the operator/platform host
(`platform.<baseDomain>/admin-console`) alongside the platform authorization
server, and authenticates operators against the platform AS via the OAuth
callback `/admin-console/callback`. The `/admin-console` prefix must NEVER be
stripped at the proxy - Next emits absolute `/admin-console/_next/...` asset
URLs. The pod sets `NEXT_PUBLIC_BASE_PATH=/admin-console`, `PORT=3000`, the
internal proxy target variables, and the `NEXT_PUBLIC_PLATFORM_AUDIENCE`,
`NEXT_PUBLIC_TENANT_KMS_AUDIENCE`, and `NEXT_PUBLIC_TENANT_DID_AUDIENCE` values
from `serviceIdentity.audiences`.

On the Gateway API path the explicit `/admin-console` PathPrefix route is more
specific than the platform service's `/` catch-all, so `/admin-console/*` routes
to the console while everything else falls through to the platform. Root `/api/*`
routes may still be enabled for authenticated automation and diagnostics through
the gateway, but the console does not depend on them.

| Value | Default | Purpose |
| --- | --- | --- |
| `enableTenantConsole` | `false` | FUTURE: render the wildcard tenant-host console route (`*.<baseDomain>/admin-console`). Do NOT enable until a per-tenant API authorization proxy enforces tenant isolation - routing alone does not stop a tenant principal from reaching platform-admin APIs or another tenant's data. Only the operator-host console route is rendered by default. |

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
