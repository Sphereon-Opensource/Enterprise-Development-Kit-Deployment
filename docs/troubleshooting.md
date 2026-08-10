# Troubleshooting

This page covers the failures you reach when running the published enterprise
images: `nexus.sphereon.com/edk-docker/enterprise-platform`,
`nexus.sphereon.com/edk-docker/enterprise-tenant-kms`,
`nexus.sphereon.com/edk-docker/enterprise-did`,
`nexus.sphereon.com/edk-docker/enterprise-tenant-as`,
`nexus.sphereon.com/edk-docker/enterprise-wallet-unit`,
`nexus.sphereon.com/edk-docker/enterprise-wallet-interaction`,
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

## Kubernetes runtime Secret failures

The Helm chart requires two references before it renders a deployment:

- `serviceIdentity.internalClientExistingSecret` when any satellite service is enabled;
- `keystore.existingSecret` when platform or tenant-KMS is enabled.

The referenced Secret normally contains `internal-client-secret` and
`keystore-password`. `edk-runtime-secrets` is an example Secret name, not a
prepackaged artifact. A missing Helm value fails `helm template` or
`helm install` before a release is created and tells you which value and key are
required.

Helm validates names, not live Secret objects. If the value is configured but
the object does not exist, pods remain in `CreateContainerConfigError` and events
contain:

```text
Error: secret "edk-runtime-secrets" not found
```

If the Secret exists but is empty or has a wrong key name, events contain one of:

```text
Error: couldn't find key internal-client-secret in Secret <namespace>/edk-runtime-secrets
Error: couldn't find key keystore-password in Secret <namespace>/edk-runtime-secrets
```

Inspect the references and key names without printing Secret data:

```bash
helm get values edk -n edk
kubectl get secret edk-runtime-secrets -n edk
kubectl get events -n edk --sort-by=.metadata.creationTimestamp
kubectl describe pod <pod-name> -n edk
```

Create or repair the Secret through the cluster's secret-management mechanism.
After changing Secret data under the same name, restart the affected deployments
because environment-variable Secret values are read only at container startup.

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
errors in its logs, points at one of these. Keep `/health` and `/ready` private
while investigating the workload. The platform connects only to the control-plane
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
the public/internal ingress split. Tenant-KMS has no public REST route; operators
manage typed KMS resources through tenant-scoped platform-config APIs. Other
administrative paths belong on the internal hostname behind JWT auth or a mesh.
See [TLS and gateway](tls-and-gateway.md).

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
`enterprise-tenant-kms` audience; tenant operators manage typed KMS resources
through tenant-scoped platform-config APIs. Issuer and verifier call
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

## Tenant creation fails on a 0.25.0-RC1 install

0.25.0-RC1 shipped Helm defaults that left `/.well-known` off the DID service's
anonymous path list. The tenant DID document at
`https://<tenant-host>/.well-known/did.json` then required a bearer token, so it
could not be resolved anonymously and tenant creation could not complete. A
direct check against the DID service returns `401` on the DID document path for
the same reason.

This is fixed in 0.25.0-RC2. Upgrade with the bundled overlay so the corrected
public paths apply even when the maintained values file was exported from RC1.
See [Upgrading from 0.25.0-RC1 to 0.25.0-RC2](quickstart-kubernetes.md#upgrading-from-0250-rc1-to-0250-rc2).

## Tenant registration fails during signing-key provisioning

A failed tenant registration can surface as `503 SERVICE_UNAVAILABLE` when the
platform asks tenant-AS to provision its signing key and tenant-AS cannot fetch
the tenant's remote platform configuration. The actionable platform and tenant-AS
logs mention `REMOTE_PLATFORM_CONFIG_UNAVAILABLE`, `platform.config.get`, or
`Missing Authorization header`.

Check, in order:

1. `serviceIdentity.internalClientExistingSecret` names the intended Secret in
   the Helm release namespace.
2. The Secret contains the key configured by
   `serviceIdentity.internalClientSecretKey` (default
   `internal-client-secret`).
3. Platform and tenant-AS were restarted after the Secret was created or
   rotated, so both use the same confidential-client credential.
4. The platform-issued tenant-AS provisioning token and the tenant-AS service
   client configuration use the chart-rendered client ids, service ids, and
   audiences as one contract.
5. NetworkPolicy and service DNS allow tenant-AS to call the platform gRPC
   endpoint and tenant-KMS.

This diagnostic indicates an east-west authentication/configuration problem.
An operator token can be valid while this internal hop fails. Do not recreate
the database or retry tenant compensation repeatedly until the runtime Secret
and service identities are consistent.

## `invalid_target` or a routed service-token failure

The platform AS returns HTTP 400 with `error: "invalid_target"` when a
`client_credentials` request cannot resolve one registered target. The exact
descriptions are:

- `Invalid target: No audience was requested and this client has no default access-token audience`
- `Invalid target: Client credentials access tokens are restricted to one audience per request`
- `Invalid target: Requested audience is not registered for this client`

The second message also covers duplicate targets: two copies of the same
audience are still multiple requested values. Diagnose these failures in this
order:

1. **Caller client ID.** Identify the actual
   `serviceIdentity.clientIds.<caller>` used in the token request and its bound
   `serviceIdentity.serviceIds.<caller>`. Do not start from the receiver name.
2. **Route audience.** Read the effective route `serviceTokenAudience`, such as
   `transport.routing.modules.kms.serviceTokenAudience`, and confirm the caller
   sent zero or one audience value, never a comma-separated or duplicated set.
3. **Default and allowlist.** Inspect that caller's internal-client registration.
   `default-access-token-audience` must be nonblank for an omitted audience; an
   explicit non-default target must appear once in
   `allowed-access-token-audiences`.
4. **Receiver audience.** Confirm the route target equals the receiver's
   fixed protocol audience (`enterprise-platform`, `enterprise-tenant-kms`,
   `enterprise-tenant-as`, `enterprise-tenant-did`, `enterprise-issuer`, or
   `enterprise-verifier`) and the receiver's effective expected audience. A
   token can be validly issued yet rejected by the receiver when these differ.

A partial caller identity fails before token acquisition with
`Incomplete service identity configuration; missing required keys: <keys>`;
the reported keys are from `server.service-identity.token-endpoint`,
`server.service-identity.client-id`, and
`server.service-identity.client-secret`. Explicit workload routes also fail
closed with one of these exact forms:

- `Service token required by serviceTokenAudience='<audience>', but no ServiceTokenProvider is configured`
- `Service token required by serviceTokenAudience='<audience>', but ServiceTokenProvider returned no token`

When `preferServiceTokenOverSessionBearer=true` is also effective, that phrase
is included in the requirement list. These errors cannot fall back to a session
bearer, delegation token, or anonymous request. Fix the caller identity and
route registration; do not weaken the receiver audience check.

## Admin console routing and sign-in

The admin console is served under `/admin-console` by separate platform and
tenant runtime instances. If it does not load or you cannot sign in:

- `404` on `https://platform.<base-domain>/admin-console`. The `admin-console` service is not
  enabled, or the gateway has no `/admin-console` route. In Helm set
  `services.admin-console.enabled: true`; in Compose bring the stack up with the
  gateway overlay. Confirm the `/admin-console` route exists and takes precedence over
  the platform catch-all.
- `404` on `https://<tenant>.<base-domain>/admin-console`. Confirm
  `admin-console-tenant` is healthy and the wildcard `/admin-console` route
  points to it, not to the platform console. If routing is correct, an
  unregistered or disabled tenant host still returns 404 by design.
- Page loads but assets `404` (for example `/admin-console/_next/...`). The base path or
  the gateway prefix handling is wrong. The container must run with
  `NEXT_PUBLIC_BASE_PATH=/admin-console`, and the route must forward the full path
  **without** a StripPrefix. See [TLS and gateway](tls-and-gateway.md).
- `404` on `https://<instance-host>/testing-console/{kind}/{instanceId}`. Confirm
  the public-page router matches `/testing-console`, is bound to wildcard
  instance hosts, and rewrites to `/admin-console/testing-console`. For Traefik
  the middleware must be `AddPrefix /admin-console`; for Gateway API it must be
  a page-only `ReplacePrefixMatch`. If routing is correct, a disabled,
  unregistered, or origin-mismatched instance still returns 404 by design.
- A testing page loads but its API, OAuth, asset, or health requests return
  `404`. Confirm the separate direct-support route includes only the two testing
  API prefixes, the exact portal OAuth login/callback/grant/revoke endpoints,
  `_next`, public assets, and health under
  `/admin-console`. These requests must reach `admin-console-tenant`; do not add
  a compatibility route for `/admin-console/testing`.
- Runtime config request `404` or `401` on
  `/api/platform/bootstrap/v1/runtime-config/admin-console`. The platform
  bootstrap route is missing from the gateway or from
  `server.rest.auth.anonymous-path-prefixes`. This route is browser-safe and
  intentionally anonymous; it does not expose secrets or business artifact
  bodies. A successful response is shaped as `{ metadata, data }`, with
  service base URLs, audiences, and named endpoints under `data.services`.
- Browser tenant resource requests fail under `/admin-console/api/*`. The
  admin-console BFF cannot resolve runtime-config services or exchange a tenant
  service token. Confirm the container has `ADMIN_CONSOLE_PLATFORM_BASE_URL`
  pointing at the internal platform service, and has the server-side tenant
  upstreams (`ADMIN_CONSOLE_TENANT_DID_BASE_URL`, `ADMIN_CONSOLE_ISSUER_BASE_URL`,
  `ADMIN_CONSOLE_VERIFIER_BASE_URL`) pointing at the internal REST services.
  The runtime-config response must still include the expected `data.services`
  entries and matching service audiences for STS exchange, and must not expose a
  tenant-KMS browser service. KMS authoring uses the typed platform-config BFF
  surface; other browser console calls stay same-origin through
  `/admin-console/api/*`.
- `401` or a failed sign-in. The platform or tenant token failed, or the redirect URI is
  not registered. The console's redirect URI
  `{host}/admin-console/callback` must be registered for the operator
  client in the authorization server for that host (the platform AS on
  `platform.<base-domain>`, otherwise that tenant's default AS). The console resolves its AS from the host it is
  served on, so a host with no matching, correctly configured AS cannot complete
  the flow.
