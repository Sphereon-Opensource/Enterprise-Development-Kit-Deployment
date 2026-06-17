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

## License token rejected

The non-platform services fail closed unless the platform license claims the deployment
they bind to. If a service refuses to start with a license or gate error:

- Confirm `license.deploymentId` matches across all services and matches the
  deployment the license was minted for.
- If using the setup screen, confirm the license was installed successfully
  before bootstrapping the first operator. Until install completes, the setup
  gate stays open and non-platform services may fail closed.
- If using the offline mounted-token overlay, confirm the platform can read the
  token and recipient key from its config (`platform.onboarding.license-token-path`,
  `platform.onboarding.recipient-key-path`, both relative to the config mount).
  A missing or unreadable token leaves the gate unclaimed and the non-platform
  services stay down.
- Confirm `license.recipient.key-id` matches the recipient key id the license is
  bound to. A mismatch means the platform cannot read the license and the gate is
  never claimed.

The platform is the local licensing authority and is exempt from the license
gate. If only the non-platform services fail while the platform is healthy, the cause is the
deployment id or the recipient key, not the platform itself.

## Database connectivity

Readiness fails when PostgreSQL is unreachable. Check the connection inputs and
network path:

- `database.host`, `database.port`, `database.name`.
- `database.existingSecret`, `database.usernameKey`, `database.passwordKey`. A
  wrong key name produces an empty credential and an authentication failure.
- NetworkPolicy egress. If you enabled `networkPolicy`, the database egress is
  restricted by `database.networkPolicy.podSelector`, `namespaceSelector`, or
  `ipBlock`. A managed external Postgres needs an `ipBlock` CIDR that covers the
  database host; an in-cluster Postgres needs a selector that matches its pods.

A pod that is `Running` but never becomes `Ready`, with database connection
errors in its logs, points at one of these. Both the APP and TENANT scopes use
the same connection, so a credential or host error affects both.

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

If admin REST is reachable publicly when it should not be, review the
public/internal ingress split: admin paths belong on the internal hostname behind
JWT auth or a mesh, never on public ingress. See
[TLS and gateway](tls-and-gateway.md).

## Ingress, TLS, and tenant routing

If requests to a tenant host land on the wrong tenant or none, the front door is
rewriting the Host header. Tenant resolution reads the raw inbound Host, so the
gateway or ingress must forward the original public Host unchanged. Azure
Application Gateway rewrites Host by default and needs explicit host preservation;
see [TLS and gateway](tls-and-gateway.md) for the per-platform settings.

Other ingress and TLS symptoms:

- Certificate warnings or TLS handshake failures on a tenant host. The wildcard
  certificate must cover `*.<base-domain>` and the operator host
  `platform.<base-domain>`. A certificate scoped to a single host fails for
  tenant subdomains. Let's Encrypt wildcard certificates require DNS-01
  validation.
- The apex domain works but tenant hosts do not. A wildcard certificate for
  `*.example.com` does not cover `example.com`, and a certificate for
  `example.com` does not cover `acme.example.com`. Publish and test the
  actual subdomains the platform uses.
- KMS reachable on public ingress when you did not intend it. Inspect your values
  and gateway overlays; the Kubernetes chart does not publish KMS by default.
- Public hosts not resolving. `global.platformBaseDomain` and the per-service
  `publicIngress.host` values must match the DNS names that point at your public
  ingress. In the single-port gateway model, DNS must point both
  `platform.<base-domain>` and `*.<base-domain>` at the gateway or load balancer.

## Platform and KMS connectivity between services

DID, tenant-AS, issuer, verifier, and tenant-KMS call the platform service for
platform configuration and control-plane data. DID, tenant-AS, issuer, and
verifier call the KMS service for key operations over internal service DNS. If
platform-config or signing operations fail with a connection error:

- With `grpc.enabled=false`, routes use internal HTTP where supported. With
  `grpc.enabled=true`, the chart renders gRPC ports for platform and tenant-KMS
  and switches the matching route endpoints to `grpc://`. A port or scheme
  mismatch between the caller's route and the peer service breaks the call.
- Confirm `grpc.authMode` matches how peer traffic is secured. With
  `service-jwt`, the caller presents a service token; with `mesh-mtls`, the mesh
  provides mutual TLS and the sidecar must be injected on both peers.
- NetworkPolicy must allow the caller to reach platform and tenant-KMS. If you
  enabled `networkPolicy`, confirm intra-release traffic to those peers is
  permitted.

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
- `401` or a failed sign-in. The operator token failed, or the redirect URI is
  not registered. The console's redirect URI
  `{host}/admin-console/callback` must be registered for the operator
  client in the authorization server for that host (the platform AS on
  `platform.<base-domain>`). The console resolves its AS same-origin from the host it is
  served on, so a host with no matching, correctly configured AS cannot complete
  the flow.
