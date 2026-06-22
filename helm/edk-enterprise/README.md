# EDK Enterprise Helm Chart

This chart deploys the EDK enterprise services:

- Platform setup/admin/config and platform authorization server
- KMS
- DID
- Tenant OAuth2 Authorization Server
- OID4VCI Issuer
- OID4VP Verifier
- Admin console (operator web UI served at `platform.<baseDomain>/admin-console`)

The chart does not deploy Postgres. Provide an existing database and credentials Secret.

## Install

```powershell
helm upgrade --install edk-enterprise .\helm\edk-enterprise `
  --namespace edk --create-namespace `
  -f .\helm\edk-enterprise\examples\shared-postgres-values.yaml
```

Customer deployments install this chart from the public Enterprise Development Kit
Deployment repository: <https://github.com/Sphereon-Opensource/Enterprise-Development-Kit-Deployment>.

For the private Nexus Docker repository, create a pull secret and reference it with `global.imagePullSecrets`.

## Main Values

| Value | Default | Purpose |
| --- | --- | --- |
| `global.imageRegistry` | `nexus.sphereon.com/edk-docker` | Registry and namespace for all service images. |
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
| `license.installationId` | `11111111-1111-4111-8111-111111111111` | Runtime service binding to the activated installation id. Must match across non-platform services and installed license claims; not supplied in license requests. |
| `networkPolicy.enabled` | `true` | Renders service ingress/egress NetworkPolicies. |
| `serviceMonitor.enabled` | `false` | Renders Prometheus Operator ServiceMonitors. |
| `opentelemetry.enabled` | `false` | Renders OTLP exporter environment variables. |

## Service Values

Each service is configured under `services.<name>` where `<name>` is `platform`, `tenant-kms`, `did`, `tenant-as`, `issuer`, `verifier`, or `admin-console`.

| Value | Purpose |
| --- | --- |
| `enabled` | Enable or disable the service. |
| `image` | Image repository name under `global.imageRegistry`. |
| `replicas` | Deployment replica count. |
| `restPort` | Container and service REST port. |
| `publicIngress` | Public ingress settings for wallet/protocol/resolver endpoints. |
| `internalIngress` | Internal ingress settings for administrative/API endpoints. |
| `resources` | Container requests and limits. |
| `env` | Extra container environment variables. |

Default per-service values:

| Service | enabled | image | replicas | restPort |
| --- | --- | --- | --- | --- |
| `platform` | `true` | `enterprise-platform` | `1` | `8080` |
| `tenant-kms` | `true` | `enterprise-tenant-kms` | `1` | `8080` |
| `did` | `true` | `enterprise-did` | `1` | `8080` |
| `tenant-as` | `true` | `enterprise-tenant-as` | `1` | `8080` |
| `issuer` | `true` | `enterprise-issuer` | `1` | `8080` |
| `verifier` | `true` | `enterprise-verifier` | `1` | `8080` |
| `admin-console` | `true` | `admin-console` | `1` | `3000` |

Tenant KMS public ingress is disabled by default. The platform service exposes only AS protocol metadata/auth paths publicly; `/api/platform/*` is internal. Other services expose only public protocol/resolver paths on public ingress; API paths are internal.

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

The single-port Gateway API model is enabled with `gateway.enabled=true` and
`ingress.legacy.enabled=false`. The classic per-service Ingress model remains
available, but public ingress must remain limited to protocol/resolver paths and
admin REST must stay internal or protected.

### Admin console

The `admin-console` service is a Next.js standalone web UI served under the
`/admin-console` basePath (the root `/` returns 404). It is a single
host-agnostic build: it resolves the API and OIDC authorization-server origin
from the request host at runtime, so there is no per-host pod config. It is
fronted on the operator/platform host
(`platform.<baseDomain>/admin-console`) alongside the platform authorization
server, and authenticates operators against the platform AS via the OAuth
callback `/admin-console/callback`. The `/admin-console` prefix must NEVER be
stripped at the proxy - Next emits absolute `/admin-console/_next/...` asset
URLs. The pod sets `NEXT_PUBLIC_BASE_PATH=/admin-console` and `PORT=3000`.

On the Gateway API path the explicit `/admin-console` PathPrefix route is more
specific than the platform service's `/` catch-all, so `/admin-console/*` routes
to the console while everything else falls through to the platform.

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

The render suite covers default REST deployment, pull secrets, ingress split, KMS internal-only behavior, platform/KMS-only gRPC receiver rendering, external Postgres secret wiring, resource/security defaults, NetworkPolicies, ServiceMonitor, and OpenTelemetry values.
