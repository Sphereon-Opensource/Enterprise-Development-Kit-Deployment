# Configuration

This page covers the runtime inputs you set when deploying the enterprise
images from this deployment repository:
`nexus.sphereon.com/edk-docker/enterprise-platform`,
`nexus.sphereon.com/edk-docker/enterprise-tenant-kms`,
`nexus.sphereon.com/edk-docker/enterprise-did`,
`nexus.sphereon.com/edk-docker/enterprise-tenant-as`,
`nexus.sphereon.com/edk-docker/enterprise-issuer`,
`nexus.sphereon.com/edk-docker/enterprise-verifier`, and
`nexus.sphereon.com/edk-docker/admin-console`.

Each service reads an `application.yml` from its config mount and overlays
environment variables on top. The Helm chart in `helm/edk-enterprise` renders the
environment variables for you from `values.yaml`; the Docker Compose deployment
mounts the config templates under `compose/config/`. Both surfaces map to the
same underlying settings, so the table values below are the inputs you supply
once and apply through whichever surface you use.

## Configuration mount and file layout

Configuration files are read from the config location the images set to
`/app/config`. The loader reads `application.yml` (and profile variants such as
`application-container.yml`). The platform service config template lives at
`compose/config/platform.application.yml` and shows the full shape of every
section described here. Use it as the reference for the YAML keys; the Helm
chart binds the same keys through environment variables.

The shipped config keeps REST on port `8080` with REST auth enabled for the
native service containers. The admin console listens on port `3000`. Platform,
tenant-KMS, wallet-unit, and wallet-interaction enable the inbound gRPC command
receiver; DID, tenant-AS, issuer, and verifier use routed outbound clients for
their internal command hops. These are container/service ports only. The
customer-facing TLS connection terminates at the gateway or ingress front door,
which then routes internally by host and path.

```yaml
server:
  rest:
    port: 8080
    auth:
      enabled: true
transport:
  grpc:
    enabled: false
    port: 9090
```

Do not place database credentials, signing keys, or any other secret as a
literal value in a values file or config template. Supply secrets as references
(see [Secret backends](secret-backends.md)).

## The installation domain

`global.platformBaseDomain` is the base domain for the whole installation. It is
the domain you control in DNS and under which the platform and tenants are
published. Everything host-shaped derives from it.

![EDK base domain and subdomain model](assets/base-domain-model.svg)

For example, with `global.platformBaseDomain=example.com`:

| Host | Purpose |
| --- | --- |
| `platform.example.com` | Platform/operator host: setup, platform admin APIs, platform authorization server, and admin console. |
| `<tenant-slug>.example.com` | Tenant host: public protocol, resolver, and tenant-scoped authenticated API routes. For the default hosted issuer, the OID4VCI `credential_issuer` identifier is this tenant origin, for example `https://acme.example.com`. |
| Internal service DNS names | East-west calls between backing services. These names, ports, and probes are not customer URLs. Do not route internal gRPC or KMS command traffic through the public gateway; the authenticated KMS API remains `/api/kms/v1` on the tenant gateway. |

Tenant resolution is host-based. Tenants receive subdomains under the base
domain (`<slug>.<base-domain>`), and each service receives
`TENANT_RESOLUTION_PLATFORM_BASE_DOMAIN`. The platform config template binds the
same value as `tenant.resolution.platform.base-domain`. A gateway, ingress
controller, CDN, or load balancer must preserve the inbound public `Host` header;
rewriting it to a backend service name prevents tenant resolution from working.

The Helm default is `example.com`. Set it to the domain that resolves to
your public gateway or ingress. In Docker Compose, the matching input is
`EDK_PLATFORM_BASE_DOMAIN`.

### TLS coverage for the base domain

Terminate public TLS before traffic reaches the services. The recommended
certificate shape is one wildcard:

| Name on certificate | Why it is needed |
| --- | --- |
| `*.<base-domain>` | Covers the operator/platform host and every first-level tenant host, for example `platform.example.com` and `acme.example.com`. |

A wildcard certificate can be issued by any public CA, including Let's Encrypt.
For Kubernetes, use cert-manager with a DNS-01 issuer, or import an existing
wildcard certificate into a Kubernetes TLS Secret. HTTP-01 issuance is usually a
poor fit for tenant wildcards because the challenge cannot validate `*.<base-domain>`.
For Docker Compose, place the certificate and key where the Traefik gateway
expects them. See [TLS and gateway](tls-and-gateway.md) for the exact steps.

When the EDK base domain is itself a subdomain, such as `edk.example.com`, the
wildcard is `*.edk.example.com` and the DNS-01 challenge record is
`_acme-challenge.edk.example.com`. The DNS operator must be able to create or
delegate that challenge record in the authoritative DNS zone. This challenge
record is separate from traffic DNS such as `*.edk.example.com` pointing to the
gateway. For manual DNS-01, the normal setup is an explicit TXT record directly
at the challenge name. Remove only an explicit non-delegation CNAME at that same
challenge name; do not remove the traffic wildcard record.

A wildcard certificate for `*.example.com` does not cover the apex
`example.com` and does not cover nested names such as
`api.acme.example.com`. Keep tenant hosts one label below the base domain.

## Public hostnames

The recommended public model publishes one platform host and one tenant
wildcard, then routes by host and path. Customers do not call individual
workload containers or per-service host ports. In Docker Compose gateway mode,
the customer's only public hostname input is the base domain. The overlay
publishes the platform/operator origin as `https://platform.<base-domain>`, and
onboarding creates tenant public-endpoint bindings, normally all on
`https://<tenant-slug>.<base-domain>`. Direct container origins and internal
service DNS names are deployment mechanics, not the customer URL contract.

Public exposure is limited to host/path routes through the gateway: public
protocol metadata and interaction paths on the tenant host, the operator admin
console on the platform host, and selected operator/admin API routes that are
authenticated before use. Backing-service health/readiness probes are not
published customer routes. Administrative REST under `/api/.../v1` must sit
behind JWT auth or a service mesh. See
[TLS and gateway](tls-and-gateway.md) for the public/internal split and how the
single-port gateway routes by host and path.

## Platform-owned service configuration

The platform is the configuration authority for tenant and service-instance
business settings. During onboarding and administration, the platform stores
issuer, verifier, tenant-AS, public-endpoint, KMS, secret-provider, and related
settings in its control-plane configuration backend. Satellite workloads read
that materialized tenant/service slice from the platform over the internal
command route.

For bootstrap and discovery, the platform also exposes a small runtime
projection:

- satellite workloads use the internal `platform.bootstrap.get` command, or the
  protected `GET /api/platform/bootstrap/v1/consumer-config/{consumerId}` REST
  endpoint, before fetching detailed platform config slices. This internal
  bootstrap response may include Kubernetes or Docker service DNS names, ports,
  namespaces, and gRPC URLs;
- browser applications read
  `GET /api/platform/bootstrap/v1/runtime-config/{applicationId}` for
  browser-safe URLs, OAuth metadata, client id/scope, service audiences, and
  feature/capability hints. The REST response is an envelope with `metadata`
  for revision/cache diagnostics and `data.services` for service objects. Each
  service object owns its browser-facing `baseUrl`, optional token `audience`,
  and named `endpoints`.

Browser runtime config derives the platform public base URL from the incoming
request origin unless an explicit platform external base URL is configured.
Platform APIs remain on the platform origin, for example
`https://platform.<base-domain>/api/platform/admin/v1`. Tenant APIs are not
platform APIs: tenant-KMS and DID resolve to tenant origins such as
`https://<tenant>.<base-domain>/api/kms/v1` and
`https://<tenant>.<base-domain>/api/did/v1`, or are omitted until a tenant
selector/public base is known. Protocol metadata is the exception: OAuth/OIDC,
OID4VCI, OID4VP, DID, and other `.well-known` documents must keep advertising
the canonical public endpoint binding for the resolved tenant/service.

This bootstrap projection is not a general configuration API. It must not carry
secrets, database settings, secret-backend coordinates, KMS credentials, or
business-authored artifact bodies. Service definitions and service settings stay
in platform config. Credential designs, issuer/verifier designs, DCQL query
bodies, render assets, and other operational artifacts stay in their dedicated
credential-design, issuer, verifier, and DCQL APIs, with platform config
referencing them by id/version where required.

Local `application.yml`, Helm values, and Docker Compose environment variables
remain part of the deployment, but they are bootstrap and override inputs. Use
them for process mechanics such as the platform endpoint, service identity,
tenant workload database connection, ports, probes, telemetry, trust mounts, and
emergency overrides. Do not treat satellite-local YAML as the normal place to
author tenant issuer/verifier/AS behavior.

The customer deployment defaults enforce this split:

```yaml
config:
  providers:
    platform-config-remote:
      enabled: true
    tenant-config-db:
      enabled: false
```

In Helm the same defaults are rendered as
`CONFIG_PROVIDERS_PLATFORM_CONFIG_REMOTE_ENABLED=true` and
`CONFIG_PROVIDERS_TENANT_CONFIG_DB_ENABLED=false` for every non-platform
service. The platform service still owns the control-plane configuration
repository; satellites do not connect to the platform database.

## Database

The deployment uses two PostgreSQL databases. This is a hard enterprise
boundary, not just a sizing recommendation:

- The **platform** (control-plane) database holds the tenant registry, routing and
  public-endpoint bindings, platform configuration, the platform tenant, and the
  platform authorization server. Only the platform service connects to it.
- The **tenant** (workload) database holds per-tenant runtime data. The default
  enterprise deployment uses one schema per tenant inside this tenant database.

Enterprise deployments must keep these as two separate logical databases. Do not
point `database.platform.*` and `database.tenant.*` at the same database name.
Do not emulate the split by putting platform tables and tenant schemas in one
database. Schemas are the tenant isolation mechanism inside the tenant workload
database only; they are not an acceptable boundary between platform state and
tenant workload state.
They may be hosted by the same managed PostgreSQL server or operator only when
the platform database and tenant database are separate databases with separate
credentials and network access can still be constrained by role.

For schema-per-tenant, runtime services select the tenant schema through their
tenant DB routing configuration and set `search_path` at request time. Tenant
schema lifecycle belongs to the tenant workload data plane; do not give the
platform service a tenant DB connection for workload schema or database DDL. The
system platform tenant is control-plane state and is bound to the platform
database; customer tenant workload data is never written to the platform
database.

In Helm, set these under `database`:

| Key | Purpose |
| --- | --- |
| `database.enabled` | Render database configuration. Keep `true`. |
| `database.dialect` | Database dialect. Use `postgresql`. |
| `database.platform.host` | Control-plane PostgreSQL host. |
| `database.platform.port` | Control-plane PostgreSQL port (typically `5432`). |
| `database.platform.name` | Control-plane database name. |
| `database.platform.existingSecret` | Secret holding the control-plane database credentials. |
| `database.platform.usernameKey` / `passwordKey` | Keys in the platform Secret. |
| `database.tenant.host` | Tenant workload PostgreSQL host. |
| `database.tenant.port` | Tenant workload PostgreSQL port (typically `5432`). |
| `database.tenant.name` | Tenant workload database name. |
| `database.tenant.existingSecret` | Secret holding the tenant database credentials. |
| `database.tenant.usernameKey` / `passwordKey` | Keys in the tenant Secret. |
| `database.tenant.isolation` | Tenant isolation strategy. Keep `schema` for the enterprise deployment. |
| `database.tenant.schemaPattern` | Schema name template used when `isolation=schema`, for example `tenant_{id}`. |

The platform service binds its control-plane datasource to the platform database
only. The runtime services bind both app-scope and tenant-scope datasources to
the tenant database, so the platform database is reachable only by the platform
service and the tenant database is reachable only by tenant workload services.
The chart never renders a database password as a literal value; the username and
password are always read from the named Secret.
`examples/external-managed-postgres-values.yaml` shows managed Postgres hosts with
egress NetworkPolicies, and `examples/shared-postgres-values.yaml` shows in-cluster
Postgres with selector-based policies. In that example, "shared" means the chart
targets environment-owned in-cluster Postgres endpoints; it does not mean the
platform and tenant state share one database.

Under Docker Compose the default stack starts two local PostgreSQL services:
`platform-postgres` for the control plane and `tenant-postgres` for tenant
workload state. The service configuration reads:

- `EDK_PLATFORM_DB_NAME`, `EDK_PLATFORM_DB_USERNAME`,
  `EDK_PLATFORM_DB_PASSWORD`
- `EDK_TENANT_DB_NAME`, `EDK_TENANT_DB_USERNAME`, `EDK_TENANT_DB_PASSWORD`

Override the corresponding host/name/credential values only when you
intentionally replace the bundled evaluation databases with external PostgreSQL
databases. Keep the platform database and tenant database separate in every
enterprise deployment.

Operationally, treat the two database credentials as separate trust boundaries:
platform credentials must not be mounted into satellite workloads, and tenant
workload credentials must not grant access to the platform database. The platform
service must not receive or use the tenant workload database connection; tenant
schema or database lifecycle is handled by the workload data plane. Tenant
workloads obtain platform-owned configuration through the platform service
rather than by connecting to the platform database.

## Issuer trust and REST auth

Administrative REST endpoints require a valid operator or service bearer token.
Enable JWT verification and point it at the authorization server that issues
those tokens.

In Helm, set these under `auth`:

| Key | Purpose |
| --- | --- |
| `auth.enabled` | Enable REST auth in the application server. Keep `true` for production. |
| `auth.jwt.enabled` | Enable JWT bearer verification. |
| `auth.jwt.issuer` | Expected token issuer (`iss`). |
| `auth.jwt.jwksUri` | JWKS endpoint the service fetches verification keys from. |
| `auth.jwt.audience` | Expected token audience (`aud`). |

These render to `SPHEREON_APP_SERVER_REST_JWT_*` variables. For production set
`auth.enabled=true`, `auth.jwt.enabled=true`, and non-empty issuer, JWKS, and
audience values. `examples/service-jwt-auth-values.yaml` shows the full block
together with per-service `SPHEREON_APP_SERVER_REST_ADMIN_AUTH_REQUIRED=true`
overrides that force admin REST to require a bearer on every service.

A subset of paths is intentionally anonymous: first-run setup, the browser-safe
runtime bootstrap API (`/api/platform/bootstrap/v1`), the OAuth protocol
surface, discovery and JWKS, and the in-network command transport. The platform
config template lists them under
`server.rest.auth.anonymous-path-prefixes`. Everything else requires a bearer.

## KMS provider

The KMS service holds signing key material and serves signing operations to the
other services. Select the provider that backs key storage:

- Software keystore. Keys live in a PKCS#12 keystore managed by tenant-KMS. The
  platform writes the tenant-specific provider config during tenant registration
  (`kms.providers.<tenant-slug>`, `type: software`,
  `autoCreateCertificate: true`), and tenant-KMS reads it through
  platform-config-remote. Use it for evaluation and for deployments where a
  software keystore meets your key custody requirements.
- A managed vault or cloud KMS. The provider holds keys in an external system
  and the service references them. Select the backend through configuration and
  supply credentials as references, never as literals.

The platform setup uses `PLATFORM_SETUP_KMS_PROVIDER_ID` to name the provider
the first-run setup binds to (the default is `license`). See
[Secret backends](secret-backends.md) for choosing and wiring a provider and for
the secret reference syntax.

## East-west service identity and STS

Internal service-to-service calls use platform-issued JWTs, not public gateway
routes and not trusted headers alone. The platform authorization server is the
STS for these workload tokens. Each satellite has a confidential client id, a
shared internal client secret, an asserted workload service id, and a receiver
audience. These values must move as one contract:

| Service | STS client id | Asserted service id | Receiver audience |
| --- | --- | --- | --- |
| platform | n/a | n/a | `enterprise-platform` |
| tenant-KMS | `kms-service` | `service-crypto` | `enterprise-tenant-kms` |
| DID | `did-service` | `service-data` | `enterprise-tenant-did` |
| issuer | `issuer-service` | `service-oid4vci` | `enterprise-issuer` |
| verifier | `verifier-service` | `service-oid4vp` | `enterprise-verifier` |
| wallet-unit | `wallet-unit-service` | `service-wallet-unit` | `enterprise-wallet-unit` |
| wallet-interaction | `wallet-interaction-service` | `service-wallet-interaction` | `enterprise-wallet-interaction` |
| tenant-AS | `tenant-as-service` | `service-tenant-as` | outbound workload caller only |

In Helm the contract lives under `serviceIdentity.clientIds`,
`serviceIdentity.serviceIds`, and `serviceIdentity.audiences`. The chart renders
the platform internal OAuth clients, platform and receiver header trust
bindings, service token endpoints, receiver audiences, admin-console token
exchange audiences, and NetworkPolicy peer edges from those values. In Docker
Compose the same contract is represented by the mounted `compose/config/*.yml`
files and the admin-console environment variables.

The binary/gRPC path is security-sensitive because trusted workload tokens may
carry tenant context through internal headers. A receiver may honor
`X-Tenant-Id` or `X-Principal-Id` only after all of these checks succeed:

- the bearer JWT validates cryptographically;
- the token is a workload token, not a human/operator token;
- the JWT client id or subject is bound to the asserted `X-Service-Id`;
- the JWT `aud` contains the receiving service audience;
- the receiver's header trust policy explicitly allows the internal override.

If any check fails, the request fails closed or the header is ignored. Do not use
`X-Tenant-Id`, `X-Principal-Id`, or `X-Service-Id` as credentials. They are
context hints after JWT validation and service binding, never proof of identity
by themselves.

KMS and wallet routing are intentionally two-token trust flows whenever the
inbound bearer is addressed to a route-only service. DID, tenant-AS, issuer, and
verifier validate and terminate the inbound JWT addressed to their own receiver
audience, then call tenant-KMS with their own workload JWT for the
`enterprise-tenant-kms` audience. Issuer and verifier use the same pattern for
wallet operations by calling wallet-interaction with an
`enterprise-wallet-interaction` token; wallet-interaction calls wallet-unit with
an `enterprise-wallet-unit` token. Tenant-AS signing-key provisioning is the
strictest example: the platform calls tenant-AS with a short-lived provisioning
JWT whose audience is the tenant provisioning endpoint, and that provisioning
JWT must not be forwarded to tenant-KMS.

## gRPC routing between services

DID, tenant-AS, issuer, verifier, tenant-KMS, wallet-unit, and
wallet-interaction call the platform service for platform configuration and
control-plane data. DID, tenant-AS, issuer, and verifier call the KMS service
for key generation, signing, verification, and public-key lookup. Issuer and
verifier call wallet-interaction for headless wallet protocol operations, and
wallet-interaction calls wallet-unit for policy-gated wallet-key commands.
Platform, tenant-KMS, wallet-unit, and wallet-interaction run the inbound gRPC
command receiver; the other runtime services use a routing-aware command client
for outbound calls and do not listen on an inbound gRPC port.

Set the transport globally in Helm under `grpc`:

| Key | Purpose |
| --- | --- |
| `grpc.enabled` | Whether internal command routing uses gRPC. The shipped default is `true`: platform, tenant-KMS, wallet-unit, and wallet-interaction expose internal gRPC receivers and the chart renders `grpc://` peer endpoints for routes to those services. |
| `grpc.port` | gRPC port (default `9090`). |
| `grpc.authMode` | Auth mode for peer gRPC traffic. Use `service-jwt` for token-based service identity, or `mesh-mtls` when a service mesh provides mutual TLS. |

With `grpc.enabled=true` the chart renders platform, tenant-KMS, wallet-unit,
and wallet-interaction gRPC receivers and points internal routes at those
services. Tenant operators and automation use the protected tenant REST API at
`https://<tenant>.<base-domain>/api/kms/v1` for provider and key
administration. Runtime DID, tenant-AS, issuer, and verifier services do not use
that REST/admin surface for signing or key operations; they route KMS service
commands over the internal east-west gRPC route to tenant-KMS with a workload
token for the `enterprise-tenant-kms` audience.

The underlying routing settings follow the pattern below, which you can set as
per-service environment overrides when a deployment must route an additional
module or narrow a route:

```text
TRANSPORT_ROUTING_MODULES_<MODULE>_TARGET=SERVER
TRANSPORT_ROUTING_MODULES_<MODULE>_TRANSPORT=<transport>
TRANSPORT_ROUTING_MODULES_<MODULE>_ENDPOINT=<scheme>://<service-host>:<port>
TRANSPORT_ROUTING_MODULES_<MODULE>_SERVICE_TOKEN_AUDIENCE=<receiver-audience>
TRANSPORT_ROUTING_MODULES_<MODULE>_PREFER_SERVICE_TOKEN_OVER_SESSION_BEARER=true|false
```

For the KMS module on DID, tenant-AS, issuer, and verifier, the deployment sets
`TRANSPORT_ROUTING_MODULES_KMS_SERVICE_TOKEN_AUDIENCE=enterprise-tenant-kms`
and `TRANSPORT_ROUTING_MODULES_KMS_PREFER_SERVICE_TOKEN_OVER_SESSION_BEARER=true`.
That keeps user/provisioning tokens scoped to their original receiver while the
KMS hop receives a token addressed to tenant-KMS.

For the wallet module on issuer and verifier, the deployment sets
`TRANSPORT_ROUTING_MODULES_WALLET_SERVICE_TOKEN_AUDIENCE=enterprise-wallet-interaction`
and routes `WALLET_INTERACTION_GRPC_ENDPOINT` to wallet-interaction. The
wallet-interaction service sets the same wallet module audience to
`enterprise-wallet-unit` for its wallet-unit hop.

The intended peer call graph:

| Calling service | Peer | Module key | Endpoint |
| --- | --- | --- | --- |
| tenant-KMS | platform | `PLATFORM` / platform config | Platform service over internal gRPC |
| DID | KMS | `KMS` | Tenant-KMS service over internal gRPC |
| DID | platform | `PLATFORM` / platform config | Platform service over internal gRPC |
| tenant-AS | KMS | `KMS` | Tenant-KMS service over internal gRPC |
| tenant-AS | platform | `PLATFORM` / platform config | Platform service over internal gRPC |
| issuer | KMS | `KMS` | Tenant-KMS service over internal gRPC |
| issuer | platform | `PLATFORM` / platform config | Platform service over internal gRPC |
| issuer | tenant-AS | `OAUTH2` | tenant-AS service over HTTP |
| issuer | wallet-interaction | `WALLET` | Wallet interaction service over gRPC |
| verifier | KMS | `KMS` | Tenant-KMS service over internal gRPC |
| verifier | platform | `PLATFORM` / platform config | Platform service over internal gRPC |
| verifier | DID | `DID` | DID service over HTTP |
| verifier | wallet-interaction | `WALLET` | Wallet interaction service over gRPC |
| wallet-interaction | wallet-unit | `WALLET` | Wallet unit service over gRPC |
| wallet-unit | platform | `PLATFORM` / platform config | Platform service over internal gRPC |
| wallet-interaction | platform | `PLATFORM` / platform config | Platform service over internal gRPC |

For mTLS between peers, set `grpc.authMode=mesh-mtls` and inject your mesh
sidecar through `podAnnotations`; `examples/mesh-mtls-values.yaml` shows the
Istio form.

## Per-service overrides

Each service accepts `services.<name>.env`, rendered verbatim into the
container. Use it for deployment-specific settings, extra routes, or secret
references:

```yaml
services:
  issuer:
    env:
      - name: EXAMPLE_SETTING
        valueFrom:
          secretKeyRef:
            name: issuer-settings
            key: example-setting
```

## License binding

The non-platform services declare a service role and validate the protected
license bundle imported during first-run setup. The installation id comes from
the signed license claims in that bundle; customers do not need to know it before
starting the platform. The platform itself is the local licensing authority and
is exempt.

In Helm these are under `license`:

| Key | Purpose |
| --- | --- |
| `license.installationId` | Optional explicit runtime pin to a known installation id. Leave empty for first-run setup. If set, it must match the installed license claims or the non-platform services fail closed. |
| `license.serviceRoles.<service>` | Per-service gate role advertised by each service. |

By default the platform starts with the setup gate open. The operator imports a
protected license bundle through `/setup-license`. When the operator generates a
license request, the setup service creates the license recipient key in the
platform system KMS (`license.recipient.kms.*`, provider `license`) and copies
only the public JWK into the request artifact. The setup UI also creates the
platform CSR key and CSR at that point; the recipient key is separate and is used
only by the platform licensing authority to decrypt the issued license material
inside the protected bundle.

Submit the generated license request to your Sphereon license operator. The
operator generates the license with Sphereon's internal license tooling and
returns a protected bundle. The customer deployment imports only that protected
bundle. Non-platform services do not mount
recipient private keys or license material; they fetch the platform-evaluated
license status and entitlement projection over the internal command route and
fail closed when that projection is missing, expired, or unreachable. If an
operator explicitly pins `license.installationId`, a pin mismatch also fails
closed. Do not set that value during normal first-run setup; the protected
bundle supplies the installation id.

Evaluation bundles that carry non-production trust material are accepted only in
dev/test-license mode. Production and on-prem deployments reject file-based test
trust material.

## Observability

Set `opentelemetry.enabled=true` and supply `opentelemetry.endpoint` (and
optionally `opentelemetry.protocol`, `opentelemetry.headers`,
`opentelemetry.resourceAttributes`) to export OTLP traces and metrics. A
`serviceMonitor` block enables Prometheus scraping of `/metrics`. See
`examples/opentelemetry-values.yaml`.

## Admin Console

The optional admin console is a separate Next.js app, image
`nexus.sphereon.com/edk-docker/admin-console`, built and published by Sphereon. It is
not built by this kit. The console is served under the `/admin-console` path prefix and
listens on port `3000`.

The admin console loads most browser runtime values from
`/api/platform/bootstrap/v1/runtime-config/admin-console` at startup. The
response body is shaped as `{ metadata, data }`; the console reads API wiring
from `data.services.<service>.baseUrl` and `data.services.<service>.endpoints`.
The container still takes these inputs for explicit server-side proxying and for
bootstrap fallbacks. The proxy variables are not the canonical API topology; use
them only when the deployment intentionally runs the admin console as a BFF for
browser calls:

| Variable | Value | Purpose |
| --- | --- | --- |
| `NEXT_PUBLIC_BASE_PATH` | `/admin-console` | The path prefix the app is served under. The app owns the prefix and emits assets at `/admin-console/_next/...`. |
| `PLATFORM_PROXY_TARGET` | Internal platform upstream URL | Optional internal platform target for an explicit `/admin-console/api/platform/*` BFF proxy mode. |
| `TENANT_KMS_PROXY_TARGET` | Internal tenant KMS upstream URL | Optional internal tenant KMS target for an explicit `/admin-console/api/kms/*` BFF proxy mode. |
| `TENANT_DID_PROXY_TARGET` | Internal DID upstream URL | Optional internal DID target for an explicit `/admin-console/api/did/*` BFF proxy mode. |
| `NEXT_PUBLIC_PLATFORM_AUDIENCE` | `enterprise-platform` | Fallback STS audience if runtime bootstrap is unavailable. |
| `NEXT_PUBLIC_TENANT_KMS_AUDIENCE` | `enterprise-tenant-kms` | Fallback tenant-KMS audience if runtime bootstrap is unavailable. |
| `NEXT_PUBLIC_TENANT_DID_AUDIENCE` | `enterprise-tenant-did` | Fallback DID audience if runtime bootstrap is unavailable. |
| `PORT` | `3000` | The port the app listens on. |

The license portal and first-run onboarding UI use the same runtime bootstrap
surface with application ids `license-portal` and `platform-onboarding`. In a
normal deployment, public OAuth URLs, browser API base paths, service audiences,
and license-portal API URLs should come from the platform projection rather than
from build-time `NEXT_PUBLIC_*` values.

The platform service also has internal east-west upstreams under
`east-west.tenant-as.base-url`, `east-west.tenant-kms.base-url`, and
`east-west.tenant-did.base-url`. Tenant activation uses these service URLs with
the public tenant host in the HTTP `Host` header. The DID upstream is required
for platform-driven tenant DID provisioning and hosted verification at
`https://<tenant>.<base-domain>/.well-known/did.json`; the platform does not
connect to the tenant database or write DID rows directly.

In Helm this is the `services.admin-console` block (`enabled`, `image`,
`replicas`, `restPort: 3000`), with an `enableTenantConsole: false` flag that
gates the future per-tenant route. In Docker Compose it is the `admin-console`
service, reached through the gateway overlay. The gateway routes
`https://platform.<base-domain>/admin-console` to the container without stripping the prefix;
see [TLS and gateway](tls-and-gateway.md).

The console's canonical browser API calls come from runtime bootstrap. Platform
admin/config calls use the platform host at `/api/platform/admin/v1` and
`/api/platform/config/v1`. Tenant-KMS and DID calls use tenant gateway roots such
as `https://<tenant>.<base-domain>/api/kms/v1` and
`https://<tenant>.<base-domain>/api/did/v1` when a tenant public base is known,
or same-origin `/api/kms/v1` and `/api/did/v1` when the frontend is served on
the tenant host. `/admin-console/api/*` remains an optional Next.js proxy mode
only; do not treat it as the service base URL returned by platform bootstrap.

Platform-admin and platform-config calls use the operator bearer. Tenant-KMS and
DID calls use RFC 8693 token exchange against the platform AS with the configured
tenant service audience; the console must not send tenant identity through
`X-Tenant-Id` headers.

### Per-host authorization server

A single build authenticates against whichever authorization server matches the
host it is served on, resolved same-origin at runtime. On `platform.<base-domain>` it
uses the platform authorization server. On a tenant host (a future capability,
not yet enabled) it would use the multi-tenant tenant-AS, which derives the
tenant from the inbound Host. On the platform host the operator signs in and the
console then uses RFC 8693 token exchange to act on tenant KMS and DID APIs.

The console's OAuth redirect URI is
`{host}/admin-console/callback`. Register it for the operator client in
**each** authorization server the console is served against, the platform AS
and, when the tenant console is enabled, the tenant-AS.
