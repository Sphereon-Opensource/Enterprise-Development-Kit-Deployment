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

The shipped config keeps REST on port `8080` with REST auth enabled for the JVM
services. The admin console listens on port `3000`. Platform and tenant-KMS
enable the inbound gRPC command receiver; DID, tenant-AS, issuer, and verifier
do not expose an inbound gRPC server.

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
| `<tenant-slug>.example.com` | Tenant host: issuer, verifier, tenant authorization server, DID resolver, and tenant-scoped protocol endpoints. For the default hosted issuer, the OID4VCI `credential_issuer` identifier is this tenant origin, for example `https://acme.example.com`. |
| Internal service DNS names | East-west calls between services. Do not route internal gRPC or KMS traffic through the public gateway. |

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
certificate shape is:

| Name on certificate | Why it is needed |
| --- | --- |
| `*.<base-domain>` | Covers every first-level tenant host, for example `acme.example.com`. |
| `platform.<base-domain>` | Covers the operator/platform host. This is also covered by the wildcard when it is a first-level subdomain, but list it explicitly when your CA, gateway, or audit policy expects the operator host as a named SAN. |

A wildcard certificate can be issued by any public CA, including Let's Encrypt.
For Kubernetes, use cert-manager with a DNS-01 issuer, or import an existing
wildcard certificate into a Kubernetes TLS Secret. HTTP-01 issuance is usually a
poor fit for tenant wildcards because the challenge cannot validate `*.<base-domain>`.
For Docker Compose, place the certificate and key where the Traefik gateway
expects them. See [TLS and gateway](tls-and-gateway.md) for the exact steps.

A wildcard certificate for `*.example.com` does not cover the apex
`example.com` and does not cover nested names such as
`api.acme.example.com`. Keep tenant hosts one label below the base domain.

## Public hostnames

Each service has a public hostname and, where applicable, a separate internal
hostname. In Helm these come from `services.<name>.publicIngress.host` and
`services.<name>.internalIngress.host`. The classic per-service ingress model
can publish separate service hosts. The recommended single-port gateway model
instead publishes one platform host and one tenant wildcard, then routes by host
and path. In Docker Compose gateway mode, keep the per-service
`EDK_*_EXTERNAL_BASE_URL` values on their local defaults; the overlay sets the
operator/bootstrap origins and onboarding creates the tenant public-endpoint
bindings, normally all on `https://<tenant-slug>.<base-domain>`.

Public exposure is limited to the DID resolver, the OAuth/OIDC protocol surface,
the OID4VCI issuer paths, the OID4VP verifier paths, and the operator admin
console on the platform host. Administrative REST under `/api/.../v1` is served
on the internal hostname only in Kubernetes and must sit behind JWT auth or a
service mesh. See [TLS and gateway](tls-and-gateway.md) for the public/internal
split and how the single-port gateway routes by host and path.

## Database

The deployment requires PostgreSQL. Two database scopes are rendered from the
same connection values: the TENANT scope holds per-tenant data, and the APP
scope holds control-plane tables including the tenant registry that host-based
tenant resolution reads. Both scopes are required.

In Helm, set these under `database`:

| Key | Purpose |
| --- | --- |
| `database.enabled` | Render database configuration. Keep `true`. |
| `database.dialect` | Database dialect. Use `postgresql`. |
| `database.host` | PostgreSQL host. |
| `database.port` | PostgreSQL port (typically `5432`). |
| `database.name` | Database name. |
| `database.existingSecret` | Name of a Kubernetes Secret holding the credentials. |
| `database.usernameKey` | Key in the Secret that holds the username. |
| `database.passwordKey` | Key in the Secret that holds the password. |

These render to `DATABASE_TENANTS_DEFAULT_*` and `DATABASE_APP_DEFAULT_*`
environment variables. The chart never renders a database password as a literal
value; the username and password are always read from the named Secret.
`examples/external-managed-postgres-values.yaml` shows a managed Postgres host
with an egress NetworkPolicy, and `examples/shared-postgres-values.yaml` shows an
in-cluster Postgres with selector-based policy.

Under Docker Compose the default stack starts a local `postgres` service and the
same values come from environment variables the config template references:
`EDK_DB_HOST`, `EDK_DB_NAME`, `EDK_DB_USERNAME`, `EDK_DB_PASSWORD`. Override
`EDK_DB_HOST` only when you intentionally replace the bundled evaluation
database with an external PostgreSQL instance.

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

A subset of paths is intentionally anonymous: first-run setup, the OAuth
protocol surface, discovery and JWKS, and the in-network command transport. The
platform config template lists them under
`server.rest.auth.anonymous-path-prefixes`. Everything else requires a bearer.

## KMS provider

The KMS service holds signing key material and serves signing operations to the
other services. Select the provider that backs key storage:

- Software keystore. Keys live in a PKCS#12 keystore managed by the service. This is
  the default in the platform config template
  (`kms.providers._tenant_`, `type: software`, `autoCreateCertificate: true`). Use it for
  evaluation and for deployments where a software keystore meets your key
  custody requirements.
- A managed vault or cloud KMS. The provider holds keys in an external system
  and the service references them. Select the backend through configuration and
  supply credentials as references, never as literals.

The platform setup uses `PLATFORM_SETUP_KMS_PROVIDER_ID` to name the provider
the first-run setup binds to (the default is `_license_`). See
[Secret backends](secret-backends.md) for choosing and wiring a provider and for
the secret reference syntax.

## gRPC routing between services

DID, tenant-AS, issuer, verifier, and tenant-KMS call the platform service for
platform configuration and control-plane data. DID, tenant-AS, issuer, and
verifier call the KMS service for key generation, signing, verification, and
public-key lookup. Platform and tenant-KMS run the inbound gRPC command
receiver; the other runtime services use a routing-aware command client for
outbound calls and do not listen on an inbound gRPC port.

Set the transport globally in Helm under `grpc`:

| Key | Purpose |
| --- | --- |
| `grpc.enabled` | Whether KMS routing uses gRPC. `true` renders gRPC ports and a `grpc://` KMS endpoint; `false` routes KMS over internal HTTP. |
| `grpc.port` | gRPC port (default `9090`). |
| `grpc.authMode` | Auth mode for peer gRPC traffic. Use `service-jwt` for token-based service identity, or `mesh-mtls` when a service mesh provides mutual TLS. |

With `grpc.enabled=true` the chart renders platform and tenant-KMS gRPC receivers
and points internal routes at those services. With `grpc.enabled=false`, routes
fall back to internal HTTP where supported.

The underlying routing settings follow the pattern below, which you can set as
per-service environment overrides when a deployment must route an additional
module or narrow a route:

```text
TRANSPORT_ROUTING_MODULES_<MODULE>_TARGET=SERVER
TRANSPORT_ROUTING_MODULES_<MODULE>_TRANSPORT=HTTP|GRPC
TRANSPORT_ROUTING_MODULES_<MODULE>_ENDPOINT=<scheme>://<service-host>:<port>
```

The intended peer call graph:

| Calling service | Peer | Module key | Endpoint |
| --- | --- | --- | --- |
| tenant-KMS | platform | `PLATFORM` / platform config | Platform service over HTTP or gRPC |
| DID | KMS | `KMS` | KMS service over HTTP or gRPC |
| DID | platform | `PLATFORM` / platform config | Platform service over HTTP or gRPC |
| tenant-AS | KMS | `KMS` | KMS service over HTTP or gRPC |
| tenant-AS | platform | `PLATFORM` / platform config | Platform service over HTTP or gRPC |
| issuer | KMS | `KMS` | KMS service over HTTP or gRPC |
| issuer | platform | `PLATFORM` / platform config | Platform service over HTTP or gRPC |
| issuer | tenant-AS | `OAUTH2` | tenant-AS service over HTTP |
| verifier | KMS | `KMS` | KMS service over HTTP or gRPC |
| verifier | platform | `PLATFORM` / platform config | Platform service over HTTP or gRPC |
| verifier | DID | `DID` | DID service over HTTP |

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

The non-platform services bind to an installation and a service role and fail
closed unless the platform license claims that installation. The platform itself
is the local licensing authority and is exempt.

In Helm these are under `license`:

| Key | Purpose |
| --- | --- |
| `license.installationId` | Runtime service binding to the activated platform installation id. Must match across non-platform services and the installed license claims. It is not supplied in license requests. |
| `license.serviceRoles.<service>` | Per-service gate role advertised by each service. |

By default the platform starts with the setup gate open. The operator imports a
protected license bundle through `/setup-license`. When the operator generates a
license request, the setup service creates the license recipient key in the
platform system KMS (`license.recipient.kms.*`, provider `_license_`) and copies
only the public JWK into the request artifact. The setup UI also creates the
platform CSR key and CSR at that point; the recipient key is separate and is used
only by the platform licensing authority to decrypt the issued license material
inside the protected bundle.

The license portal may also create the full setup bundle without a customer
request. In both flows the customer receives only the protected bundle; the
platform derives the bundle security material internally from the protected
installation binding embedded in the bundle. Non-platform services do not mount
recipient private keys or license material; they fetch the platform-evaluated
license status and entitlement projection over the internal command route and
fail closed when that projection is missing, expired, or unreachable.

For non-production/evaluation test-license roots, set
`EDK_DEPLOYMENT_MODE=dev` and `EDK_LICENSE_TRUST_EMBEDDED=false`. Test trust
material is delivered inside the protected setup bundle and remains rejected in
production/on-prem mode.

## Observability

Set `opentelemetry.enabled=true` and supply `opentelemetry.endpoint` (and
optionally `opentelemetry.protocol`, `opentelemetry.headers`,
`opentelemetry.resourceAttributes`) to export OTLP traces and metrics. A
`serviceMonitor` block enables Prometheus scraping of `/metrics`. See
`examples/opentelemetry-values.yaml`.

## Admin Console

The optional admin console is a separate Next.js app, image
`${EDK_REGISTRY:-nexus.sphereon.com/edk-docker}/admin-console`, built and published by Sphereon. It is
not built by this kit. The console is served under the `/admin-console` path prefix and
listens on port `3000`.

The container takes two inputs:

| Variable | Value | Purpose |
| --- | --- | --- |
| `NEXT_PUBLIC_BASE_PATH` | `/admin-console` | The path prefix the app is served under. The app owns the prefix and emits assets at `/admin-console/_next/...`. |
| `PORT` | `3000` | The port the app listens on. |

In Helm this is the `services.admin-console` block (`enabled`, `image`,
`replicas`, `restPort: 3000`), with an `enableTenantConsole: false` flag that
gates the future per-tenant route. In Docker Compose it is the `admin-console`
service, reached through the gateway overlay. The gateway routes
`https://platform.<base-domain>/admin-console` to the container without stripping the prefix;
see [TLS and gateway](tls-and-gateway.md).

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
