# Troubleshooting

This page covers the failures you reach when running the published enterprise
images: `nexus.sphereon.com/edk-docker/enterprise-platform`,
`nexus.sphereon.com/edk-docker/enterprise-tenant-kms`,
`nexus.sphereon.com/edk-docker/enterprise-did`,
`nexus.sphereon.com/edk-docker/enterprise-tenant-as`,
`nexus.sphereon.com/edk-docker/enterprise-issuer`, and
`nexus.sphereon.com/edk-docker/enterprise-verifier`.

## Image pull and registry auth

If pods stay in `ImagePullBackOff` or `ErrImagePull`, the cluster cannot pull the
images. Check:

- `global.imagePullSecrets` names a pull secret that exists in the release
  namespace.
- The registry account behind that secret has access to the enterprise service
  repositories listed above, and to `nexus.sphereon.com/edk-docker/admin-console` if you enable the
  admin console.
- `global.imageRegistry` and `global.imageTag` point at the registry and tag you
  were given.

Confirm the pull secret is valid by describing a failing pod and reading the
events. A `401`/`403` from the registry or an `unauthorized` message means the
pull secret is missing, misnamed, or lacks access to one of the repositories.

## License bundle rejected

The non-platform services fail closed unless they can validate the protected
license bundle and their service role. If a service refuses to start with a
license or gate error:

- If you explicitly set `license.installationId`, confirm it matches the
  installed license claims. For normal first-run setup, leave it unset; the
  protected bundle supplies the installation id.
- If using the setup screen, confirm the protected license bundle was imported
  successfully before bootstrapping the first operator. Until import completes,
  the setup gate stays open and non-platform services may fail closed.
- If using the setup screen after generating a license request, confirm the
  platform `license` KMS contains the `license.recipient.kms.alias` key created
  during license-request generation. A missing key means the platform cannot
  decrypt the issued license material and the non-platform services will mirror
  that failed state.
- If the license operator returned a complete setup bundle, confirm the import
  preview shows the expected bundle entries before Apply.
- Confirm `license.recipient.key-id` matches the recipient key id the license is
  bound to. A mismatch means the platform cannot read the license and the gate is
  never claimed.

The platform is the local licensing authority and is exempt from the license
gate. If only the non-platform services fail while the platform setup/status
route is reachable through the gateway, check the service role, any optional
installation-id pin, and the internal route from the service to the platform
command endpoint.

## Database connectivity

Kubernetes readiness or Docker Compose health can fail when PostgreSQL is
unreachable. Check the connection inputs and network path from inside the
deployment:

- `database.platform.host`, `database.platform.port`, `database.platform.name`.
- `database.tenant.host`, `database.tenant.port`, `database.tenant.name`.
- `database.platform.existingSecret` and `database.tenant.existingSecret`,
  plus their `usernameKey` and `passwordKey` values. A
  wrong key name produces an empty credential and an authentication failure.
- NetworkPolicy egress. If you enabled `networkPolicy`, the database egress is
  restricted by `database.platform.networkPolicy.*` and
  `database.tenant.networkPolicy.*`. A managed external Postgres needs an
  `ipBlock` CIDR that covers the database host; an in-cluster Postgres needs a
  selector that matches its pods.

A pod that is `Running` but never becomes `Ready`, with database connection
errors in its logs, points at one of these. Do not diagnose this by publishing
`/health` or `/ready` through the customer gateway; those probes are internal
orchestration signals. The platform connects only to the control-plane
database. Satellite services connect only to the tenant workload database and
fetch platform-owned configuration from the platform over the internal command
route.

## Issuer-trust and admin REST 401s

Administrative REST under `/api/.../v1` requires a valid bearer token. A `401` on
an admin call usually means the token failed verification:

- `auth.enabled` and `auth.jwt.enabled` are true, and `auth.jwt.issuer`,
  `auth.jwt.jwksUri`, and `auth.jwt.audience` are set to the authorization server
  that issued the token. A blank issuer or JWKS leaves verification unable to
  validate any token.
- The token's `iss` and `aud` match the configured issuer and audience.
- The service can reach `auth.jwt.jwksUri` to fetch verification keys. If the
  JWKS host is only reachable over TLS with a private CA, the service must trust
  that CA.
- The protocol and discovery paths are intentionally anonymous; a `401` there
  means the request hit an admin path, not a protocol path. Check that you are
  calling the right host and path for the operation.

If a control-plane REST route is reachable publicly when it should not be, review
the public/internal ingress split. Selected tenant APIs such as authenticated KMS
REST at `/api/kms/v1` are intentionally exposed through the tenant gateway, while
other administrative paths belong on the internal hostname behind JWT auth or a
mesh. See [TLS and gateway](tls-and-gateway.md).

## Ingress, TLS, and tenant routing

If requests to a tenant host land on the wrong tenant or none, the front door is
rewriting the Host header. Tenant resolution reads the raw inbound Host, so the
gateway or ingress must forward the original public Host unchanged. Azure
Application Gateway rewrites Host by default and needs explicit host preservation;
see [TLS and gateway](tls-and-gateway.md) for the per-platform settings.

Other ingress and TLS symptoms:

- Certificate warnings or TLS handshake failures on a tenant host. The wildcard
  certificate must cover `*.<base-domain>`, which includes
  `platform.<base-domain>` and first-level tenant hosts. A certificate scoped to
  a single host fails for tenant subdomains. Let's Encrypt wildcard certificates
  require DNS-01 validation and DNS control over
  `_acme-challenge.<base-domain>`.
- The apex domain works but tenant hosts do not. A wildcard certificate for
  `*.example.com` does not cover `example.com`, and a certificate for
  `example.com` does not cover `acme.example.com`. Publish and test the
  actual subdomains the platform uses.
- A tenant administrative API route is reachable more broadly than intended.
  Inspect your values and gateway overlays; customer traffic should enter only
  through the platform host or tenant gateway host, and administrative routes
  must remain authenticated or internal.
- Public hosts not resolving. `global.platformBaseDomain` must match the DNS
  zone routed to the public gateway. DNS must point both
  `platform.<base-domain>` and `*.<base-domain>` at the gateway or load
  balancer.

## Platform, KMS, and wallet connectivity between services

The backing workloads call the platform service for platform configuration and
control-plane data. Workloads that need key operations route KMS service
commands to tenant-KMS over internal gRPC with a workload token for the
`enterprise-tenant-kms` audience; tenant operators use `/api/kms/v1` only for
the protected tenant REST administration surface. Issuer and verifier call
wallet-interaction, and wallet-interaction calls wallet-unit, over internal
service DNS for wallet protocol work. If platform-config, signing, or wallet
operations fail with a connection error:

- With the shipped `grpc.enabled=true` default, the chart renders gRPC ports for
  platform, tenant-KMS, wallet-unit, and wallet-interaction and switches the
  matching route endpoints to `grpc://`. A port or scheme mismatch between the
  caller's route and the peer service breaks the call.
- Confirm `grpc.authMode` matches how peer traffic is secured. With
  `service-jwt`, the caller presents a service token; with `mesh-mtls`, the mesh
  provides mutual TLS and the sidecar must be injected on both peers.
- NetworkPolicy must allow the caller to reach platform, tenant-KMS,
  wallet-interaction, and wallet-unit as appropriate. If you enabled
  `networkPolicy`, confirm intra-release traffic to those peers is permitted.

## Admin console routing and sign-in

The optional admin console is served under `/admin-console` on the platform host and
listens on port `3000`. If it does not load or you cannot sign in:

- `404` on `https://platform.<base-domain>/admin-console`. The `admin-console` service is not
  enabled, or the gateway has no `/admin-console` route. In Helm set
  `services.admin-console.enabled: true`; in Compose bring the stack up with the
  gateway overlay. Confirm the `/admin-console` route exists and takes precedence over
  the platform catch-all.
- Page loads but assets `404` (for example `/admin-console/_next/...`). The base path or
  the gateway prefix handling is wrong. The container must run with
  `NEXT_PUBLIC_BASE_PATH=/admin-console`, and the route must forward the full path
  **without** a StripPrefix. See [TLS and gateway](tls-and-gateway.md).
- Runtime config request `404` or `401` on
  `/api/platform/bootstrap/v1/runtime-config/admin-console`. The platform
  bootstrap route is missing from the gateway or from
  `server.rest.auth.anonymous-path-prefixes`. This route is browser-safe and
  intentionally anonymous; it does not expose secrets or business artifact
  bodies. A successful response is shaped as `{ metadata, data }`, with
  service base URLs, audiences, and named endpoints under `data.services`.
- Tenant KMS or DID requests are sent to `platform.<base-domain>` or
  `/admin-console/api/*`. Runtime bootstrap is not returning a tenant service
  base URL, or the deployment has intentionally enabled the optional Next.js BFF
  proxy. Canonical tenant service calls use
  `https://<tenant>.<base-domain>/api/kms/v1` and
  `https://<tenant>.<base-domain>/api/did/v1` with tenant-scoped service tokens.
- `401` or a failed sign-in. The operator token failed, or the redirect URI is
  not registered. The console's redirect URI
  `{host}/admin-console/callback` must be registered for the operator
  client in the authorization server for that host (the platform AS on
  `platform.<base-domain>`). The console resolves its AS same-origin from the host it is
  served on, so a host with no matching, correctly configured AS cannot complete
  the flow.
