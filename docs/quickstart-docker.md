# Quickstart: Docker Compose

This path brings up the EDK enterprise services on a single machine using the stack under `compose/`. It suits evaluation and single-node development. For production, use the Helm chart and follow [quickstart-kubernetes.md](quickstart-kubernetes.md).

Use the files in the public Enterprise Development Kit Deployment repository: <https://github.com/Sphereon-Opensource/Enterprise-Development-Kit-Deployment>.

There are two run modes:

- Base Compose alone. Each service is published on its own host port over plain HTTP. This is the quickest way to test the platform locally.
- Base Compose plus the gateway overlay. A Traefik reverse proxy fronts the services on a single TLS port and routes by host and path. This matches the production single-port gateway model.

## Prerequisites

- Docker with Compose v2.
- Nexus credentials for the private `nexus.sphereon.com/edk-docker` enterprise image repository.
- Docker Compose starts a local PostgreSQL 16 container for evaluation. For a real single-node deployment, replace it with a managed or operator-run PostgreSQL database and point the service configuration at that database.
- A Sphereon protected license bundle ZIP, or access to your evaluation license issuer. The setup UI creates the license recipient key in the platform `_license_` KMS when it generates the license request. Evaluation bundles can include the test root CA material when needed.
- TLS certificates for the operator and tenant hosts when you use the gateway overlay. For local gateway evaluation, use the included wildcard certificate helper. For a real domain, use a publicly trusted wildcard certificate for `*.<base-domain>` plus `platform.<base-domain>`, or individual certificates for each host.

## 1. Authenticate to Nexus

The enterprise images are private. Sign in once so Compose can pull them:

```bash
docker login nexus.sphereon.com
```

Use the username and password or token Sphereon provides for the private enterprise image repository.

## 2. Configure the stack

Copy the example environment file in `compose/` and edit it:

```bash
cd compose
cp .env.example .env
```

Set, at minimum:

- The registry and image tag for the enterprise images.
- The database password. The default Compose file starts Postgres in the stack; use an external database only when you intentionally replace that service.
- The required secrets: keystore password, internal client secret, and the issuer pipeline keys.
- The installation base domain. For the base file alone, leave the external base URLs on their loopback defaults. For the gateway overlay, tenant protocol URLs are created during onboarding from `<tenant-slug>.<base-domain>`.
- For a test license that does not chain to the embedded production root, set
  `EDK_DEPLOYMENT_MODE=dev` and `EDK_LICENSE_TRUST_EMBEDDED=false`; paste the
  supplied test root CA bundle in the setup UI.

For customer evaluation test licenses that do not use the embedded production
trust root, set `EDK_DEPLOYMENT_MODE=dev` and
`EDK_LICENSE_TRUST_EMBEDDED=false`; paste the supplied test root CA bundle in
the setup UI. Do not add `docker-compose.offline.yml`; that overlay is only for
pre-provisioning from a mounted token and recipient seed and intentionally skips
the setup screen.

For gateway runs, the default base domain `saas.localtest.me` resolves every
subdomain to `127.0.0.1` with no host-file edits and no local DNS server, so
`https://platform.saas.localtest.me` and
`https://<tenant>.saas.localtest.me` both reach your machine. For a real domain,
set `EDK_PLATFORM_BASE_DOMAIN` to the customer-controlled base domain, point DNS
for `platform.<base-domain>` and `*.<base-domain>` at the gateway host, and bind
the tenant endpoints to the tenant host during onboarding. Only set the
per-service `EDK_*_EXTERNAL_BASE_URL` values when you run the base compose file
behind your own reverse proxy instead of the bundled gateway overlay.

## 3a. Run the base stack (individual ports, plain HTTP)

```bash
docker compose -f docker-compose.yml up -d
```

Compose pulls the published images and starts them, each on its own loopback host port over plain HTTP. Check that the services are healthy:

```bash
docker compose ps
```

The stack also starts an OpenTelemetry Collector and Jaeger. The JVM services
use the `otlp-all` telemetry preset by default, exporting traces and metrics to
`otel-collector`; traces are available at `http://localhost:16686`.

The base stack is for quick local testing. The administrative REST paths (`/api/.../v1`) are not protected by the base stack, so keep them on the host loopback or a private network.

## 3b. Run behind the single-port gateway (single TLS port)

To run the services behind one TLS port, add the gateway overlay.

First, for local evaluation, generate a wildcard certificate for `*.saas.localtest.me` and the operator host:

```bash
../scripts/gen-local-wildcard-cert.sh
```

On Windows:

```powershell
..\scripts\gen-local-wildcard-cert.ps1
```

The script writes to `compose/gateway/certs/`. Trust the generated `local-ca.crt` in your operating system or browser so TLS connections succeed. If `mkcert` is installed, run `mkcert -install` once and its CA is trusted automatically. For a real base domain, supply a publicly trusted wildcard certificate or individual host certificates instead and see [tls-and-gateway.md](tls-and-gateway.md).

Then bring up the base stack and the gateway overlay together:

```bash
docker compose -f docker-compose.yml -f docker-compose.gateway.yml up -d
```

All public traffic now goes through `443`. Traefik terminates TLS, preserves the inbound Host header, and routes by host and path: the operator plane at `https://platform.<base-domain>` and each tenant at `https://<tenant>.<base-domain>`.

## 4. Where the services listen

The public surface is limited to protocol and resolver endpoints:

| Service | Public endpoints |
| --- | --- |
| Platform | OAuth/OIDC authorization server metadata, `/authorize`, `/token`, `/userinfo` |
| Tenant KMS | None. The KMS has no public listener |
| DID | `/.well-known/did.json`, `/1.0/identifiers`, resolver paths |
| Tenant AS | OAuth/OIDC metadata, `/authorize`, `/token`, `/userinfo`, `/login` |
| Issuer | `/.well-known/openid-credential-issuer`, `/oid4vci`, `/credential`, status list paths |
| Verifier | `/oid4vp`, `/request_uri`, `/direct_post` |
| Admin console | `/admin-console` on the platform host (gateway overlay only) |

The administrative REST paths (`/api/.../v1`) are for controlled administrative
use. Keep them off the open public network and reach them only over the host
loopback, your private network, or a gateway route protected by JWT and network
policy.

## 5. Admin console

The optional `admin-console` service is the Next.js operator admin UI. It comes up with the gateway overlay and is reachable at `https://platform.<base-domain>/admin-console`. The console listens on port `3000` and owns the `/admin-console` path prefix; the gateway routes `/admin-console` to it without stripping the prefix.

First-run setup must activate the license and create the operator account. After that, open `https://platform.<base-domain>/admin-console` and sign in with that operator account. The console authenticates against the platform authorization server for this host, then uses token exchange to act on tenant KMS and DID APIs. The per-tenant console (`https://<tenant>.<base-domain>/admin-console`) is a future capability and is not enabled. For details see [configuration.md](configuration.md) and [tls-and-gateway.md](tls-and-gateway.md).

## 6. Onboard the first tenant

With the stack up, onboard a tenant in one of two ways:

- Run the provision script. It calls the REST APIs against the running deployment: it waits for health, runs platform setup if the gate is still open, signs the operator in, registers the tenant, and binds the tenant's public endpoints. See [onboarding.md](onboarding.md).
- Import the Postman collection and run it step by step. This is the explicit, request-by-request path through platform setup, operator sign-in, and tenant creation. See [onboarding.md](onboarding.md).

## Stop the stack

```bash
docker compose -f docker-compose.yml down -v
```

Add `-f docker-compose.gateway.yml` if you brought the stack up with the gateway overlay. The `-v` flag removes the stack volumes. Omit it to keep data between runs.
