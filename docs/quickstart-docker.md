# Quickstart: Docker Compose

This path brings up the EDK enterprise services on a single machine using the stack under `compose/`. It suits evaluation and single-node development. For production, use the Helm chart and follow [quickstart-kubernetes.md](quickstart-kubernetes.md).

Use the files in the public Enterprise Development Kit Deployment repository: <https://github.com/Sphereon-Opensource/Enterprise-Development-Kit-Deployment>.

There are two run modes:

- Base Compose plus the gateway overlay. A Traefik reverse proxy fronts the services on a single TLS port and routes by host and path. This is the customer walkthrough model and matches the production single-port gateway model.
- Base Compose alone. Each service is published on its own host port over plain HTTP. Use this only as a local developer diagnostic mode; it is not a customer URL model.

The platform is the configuration authority for tenant workloads. A clean
first-run installation starts the platform and all workload containers together:
tenant AS, tenant KMS, DID, issuer, and verifier must already be present when
tenant registration later provisions signing material and tenant DID state
through east-west services. Before the license is imported those workload
health endpoints can report `licenseStatus: MISSING`; Docker Compose accepts
that only while the first-run setup gate is still open.

## Prerequisites

- Docker with Compose v2.
- Nexus credentials for the published `nexus.sphereon.com/edk-docker/enterprise-*` and `nexus.sphereon.com/edk-docker/admin-console` images for the selected `EDK_TAG`.
- Docker Compose starts two local PostgreSQL 16 containers for evaluation: one platform/control-plane database and one tenant workload database. For a real single-node deployment, replace them with managed or operator-run PostgreSQL databases and keep platform and tenant state in separate logical databases. Do not put platform tables and tenant schemas in one database.
- A protected license bundle ZIP, or access to the license issuer provided through your EDK distribution channel. The setup UI creates the license recipient key in the platform `license` KMS when it generates the license request. Evaluation bundles can include the test root CA material when needed.
- TLS certificates for the operator and tenant hosts when you use the gateway
  overlay. For local gateway evaluation, use the included wildcard certificate
  helper. For a real domain, use a publicly trusted wildcard certificate for
  `*.<base-domain>`, or individual certificates for each host.

## 1. Authenticate to Nexus

Sign in once so Compose can pull the enterprise images:

```bash
docker login nexus.sphereon.com
```

The Compose file pins enterprise image pulls to `nexus.sphereon.com/edk-docker`; set
`EDK_TAG` only. Do not reintroduce `sphereon` or `docker.io/sphereon`; those
values point Compose at public Docker Hub.

Confirm Docker can pull the published images for the tag you plan to deploy:

```bash
docker pull nexus.sphereon.com/edk-docker/enterprise-platform:0.25.0-SNAPSHOT
```

## 2. Configure the stack

Copy the example environment file in `compose/` and edit it:

```bash
cd compose
cp .env.example .env
```

Set, at minimum:

- The image tag for the enterprise images. The image repository is pinned to `nexus.sphereon.com/edk-docker` in the Compose file.
- The platform and tenant database passwords. The default Compose file starts `platform-postgres` and `tenant-postgres`; use external databases only when you intentionally replace those evaluation services. Keep the two databases separate. They may share a PostgreSQL server, but not a database name, credential, or authorization boundary.
- The required secrets: keystore password, distinct per-satellite internal client secrets, and the issuer pipeline keys.
- A fresh secret-authority key window. Generate it before the first start and
  after intentionally rotating the authority keys:

  ```powershell
  ..\scripts\generate-secret-authority-keys.ps1 -OutputDirectory .\.secret-authority\current
  ```

  On Linux or macOS:

  ```bash
  ../scripts/generate-secret-authority-keys.sh ./.secret-authority/current
  ```

  Set `EDK_SECRET_AUTHORITY_ROOT=./.secret-authority/current` in `.env`, then
  copy the four `SECRET_AUTHORITY_*` assignments from
  `.secret-authority/current/window.env` into `.env`. The platform receives the
  central private key and workload public keys; each satellite container mounts
  only its own assertion private key plus the central public key. The generated
  directory is ignored by Git and must not be copied into release evidence.
- No external secret provider is required at startup. The baseline uses the
  persisted platform software KMS. Configure Vault or a cloud provider only
  through an explicit provider setup after the platform is running.
- The installation base domain. The platform is published as
  `https://platform.<base-domain>`. Tenant protocol URLs are created during
  onboarding from `<tenant-slug>.<base-domain>`.

When upgrading an older Compose environment, remove the legacy single-database
keys `EDK_DB_NAME`, `EDK_DB_USERNAME`, `EDK_DB_PASSWORD`, and
`EDK_POSTGRES_HOST_PORT` from `.env`. Replace them with `EDK_PLATFORM_DB_*` and
`EDK_TENANT_DB_*`.

RC4 requires eight `.env` variables that RC3 did not. `docker compose config`
fails with "required variable ... is missing a value" until all eight are set:

| Variable | Read by |
| --- | --- |
| `EDK_INTERNAL_CLIENT_SECRET_TENANT_KMS` | platform, and the tenant KMS satellite through `EDK_INTERNAL_CLIENT_SECRET` |
| `EDK_INTERNAL_CLIENT_SECRET_TENANT_AS` | platform, and the tenant AS satellite through `EDK_INTERNAL_CLIENT_SECRET` |
| `EDK_INTERNAL_CLIENT_SECRET_DID` | platform, and the DID satellite through `EDK_INTERNAL_CLIENT_SECRET` |
| `EDK_INTERNAL_CLIENT_SECRET_BLOB` | platform, and the blob satellite through `EDK_INTERNAL_CLIENT_SECRET` |
| `EDK_INTERNAL_CLIENT_SECRET_ISSUER` | platform, and the issuer satellite through `EDK_INTERNAL_CLIENT_SECRET` |
| `EDK_INTERNAL_CLIENT_SECRET_VERIFIER` | platform, and the verifier satellite through `EDK_INTERNAL_CLIENT_SECRET` |
| `EDK_INTERNAL_CLIENT_SECRET_EMAIL` | platform, and the email satellite through `EDK_INTERNAL_CLIENT_SECRET` |
| `EDK_SECRET_MANAGEMENT_RUNTIME_DB_PASSWORD` | platform and every satellite, as the password of the `secret_management_runtime` database role |

The platform reads all seven `EDK_INTERNAL_CLIENT_SECRET_*` values directly;
each satellite container still reads only its own secret through the single
`EDK_INTERNAL_CLIENT_SECRET` name, and the seven values may differ. The
platform no longer reads a single `EDK_INTERNAL_CLIENT_SECRET` value. See the
required-values table in the repository README and the East-west service
identity and STS section of [configuration.md](configuration.md) for what
each value protects.

Each tenant's OID4VCI credential issuer identifier is
`https://<tenant>.<base-domain>/oid4vci/<tenant>`, not the bare tenant origin.
Existing credential configuration carries over automatically at the first
start after the upgrade. Wallets and relying parties that hold the old
identifier must be onboarded again with a new credential offer.

There is no default base domain: Compose fails before startup when
`EDK_PLATFORM_BASE_DOMAIN` is empty. For an explicitly selected localtest run,
set it to `saas.localtest.me`; that domain resolves every subdomain to
`127.0.0.1` with no host-file edits and no local DNS server, so
`https://platform.saas.localtest.me` and
`https://<tenant>.saas.localtest.me` both reach your machine. For a real domain,
set `EDK_PLATFORM_BASE_DOMAIN` to the customer-controlled base domain, point DNS
for `platform.<base-domain>` and `*.<base-domain>` at the gateway host, and bind
the tenant endpoints to the tenant host during onboarding.

### Installing and upgrading released images

Use the upgrade wrapper instead of changing `EDK_TAG` and running `docker
compose up` yourself. It detects the installed platform image, pulls each
required release, and waits for the complete stack after every step. A direct
RC1-to-RC3 request therefore runs RC1-to-RC2-to-RC3 so the application database
migrations execute in release order. Repeating the command is idempotent.

Linux/macOS:

```bash
bash ../scripts/upgrade-compose.sh --image-tag 0.25.0-RC3
```

Windows PowerShell:

```powershell
..\scripts\upgrade-compose.ps1 -ImageTag 0.25.0-RC3
```

For a gateway deployment, pass both the base file and overlay:
`--file docker-compose.yml --file docker-compose.gateway.yml` (Bash) or
`-File docker-compose.yml,docker-compose.gateway.yml` (PowerShell). Supplying a
file list replaces the wrapper default, so the base file must remain explicit. The wrapper
detects the running container first, then its recorded release state, then an
unchanged `.env`. Use the explicit installed-tag option only when an older stack
was removed and its `.env` was already changed. After success, keep the target
`EDK_TAG` in `.env` for later direct Compose commands.

If the platform refuses to start with a startup failure whose message begins
`Authorization-server migration source previously failed`, set
`AUTHORIZATION_SERVER_MIGRATION_RESUME_FAILED=true` in `.env` so the platform
service receives it on the next start, then remove it again. Do not change
`oauth2.servers.*` configuration between a failed start and the retry; a changed
source is refused until it is accepted through the migration API. A migration
that fails only during planning retries on its own and does not need the flag.

## 3a. Run the base stack (developer diagnostic only)

```bash
docker compose -f docker-compose.yml up -d --remove-orphans
```

Compose pulls the published images and starts the full backing stack over plain
HTTP on local host ports. This mode is only for local diagnostics before placing
a gateway in front of the stack. Check that the containers are running:

```bash
docker compose ps
```

The stack also starts an OpenTelemetry Collector and Jaeger. The service
containers use the `otlp-all` telemetry preset by default, exporting traces and
metrics to `otel-collector`; traces are available at `http://localhost:16686`.

The base stack is for local diagnostics only. The administrative REST paths
(`/api/.../v1`) are not protected by the base stack, so keep them on host
loopback or a private network and do not use these ports in customer-facing
instructions, smoke tests, or integrations.

## 3b. Run behind the single-port gateway (single TLS port)

To run the services behind one TLS port, add the gateway overlay.

First, for local evaluation, generate a wildcard certificate for `*.saas.localtest.me` and the operator host:

```bash
../scripts/gen-local-wildcard-cert.sh --localtest
```

On Windows:

```powershell
..\scripts\gen-local-wildcard-cert.ps1 -Localtest
```

The script writes to `compose/gateway/certs/`. Trust the generated `local-ca.crt` in your operating system or browser so TLS connections succeed. If `mkcert` is installed, run `mkcert -install` once and its CA is trusted automatically. For a real base domain, supply a publicly trusted wildcard certificate or individual host certificates instead and see [tls-and-gateway.md](tls-and-gateway.md).

For a public Let's Encrypt wildcard such as `*.edk.example.com`, use the
Let's Encrypt renderer instead of this local-certificate overlay. Set the EDK
base domain to `edk.example.com` and use DNS-01 validation. Provide DNS API
credentials when Traefik should automate issuance and renewal, or use the
manual DNS-01 path when you create the TXT record yourself. See
[Subdomain wildcard with Let's Encrypt](tls-and-gateway.md#subdomain-wildcard-with-lets-encrypt).

Then start the full enterprise stack behind the gateway.

With the local certificate overlay:

```bash
docker compose -f docker-compose.yml -f docker-compose.gateway.yml up -d --remove-orphans
```

With the Let's Encrypt overlay:

```bash
docker compose -f docker-compose.yml -f docker-compose.letsencrypt.yml up -d --wait --remove-orphans
```

All public traffic now goes through `443`. Traefik terminates TLS, preserves the inbound Host header, and routes by host and path: the operator plane at `https://platform.<base-domain>` and each tenant at `https://<tenant>.<base-domain>`. Customers and operators call the gateway URLs, not the individual containers.

On a pristine deployment the setup gate is still open and non-platform
workloads have not received an activated license yet. They should nevertheless
be running. Direct workload `/health` probes may show `503` with
`licenseStatus: MISSING` until first-run setup imports the protected license
bundle and bootstraps the operator account.

## 4. Gateway Public Routes

The public surface is the gateway route table, not direct container ports. It is
limited to the platform host and tenant hosts; Traefik maps paths on those hosts
to the backing containers internally:

| Gateway host | Routed paths |
| --- | --- |
| `platform.<base-domain>` | Operator OAuth/OIDC metadata, `/authorize`, `/token`, `/userinfo`, `/admin-console` |
| `<tenant>.<base-domain>` | Public protocol/resolver paths such as `/.well-known/did.json`, tenant OAuth/OIDC metadata and auth paths, OID4VCI issuer paths, OID4VP verifier paths, plus authenticated operator/admin API paths if your gateway policy exposes them |

Keep workload health endpoints private. They are not tenant public URLs.

The administrative REST paths (`/api/.../v1`) are controlled operator/admin
traffic, not public protocol endpoints. Keep them off the open public network
and reach them only through an authenticated gateway path or a private network
path protected by JWT and network policy.

## 5. First-run setup and admin console

The gateway starts separate platform and tenant admin-console runtimes from the same image. Operators use `https://platform.<base-domain>/admin-console`; tenant administrators use `https://<tenant>.<base-domain>/admin-console`. Both own the `/admin-console` prefix without stripping it, while only the platform runtime receives the platform BFF credential.

On a new installation, open `https://platform.<base-domain>/setup-license`,
or open `https://platform.<base-domain>/admin-console` and follow the setup
redirect. First-run setup generates the license request, imports the protected
license bundle, and creates the first platform operator account. Do not set the
operator email, license installation id, deployment id, or tenant slug in
`.env` just to start the stack; setup and tenant creation collect those values
when they are needed.

After setup closes the anonymous setup gate, open
`https://platform.<base-domain>/admin-console` and sign in with the operator
account. The console authenticates against the platform authorization server for
this host, then uses token exchange to act on tenant KMS and DID APIs. The
issuer/verifier testing console is available to external testers at
`https://<instance-host>/testing-console/{kind}/{instanceId}` when enabled for
that instance. Those hosts expose only the canonical page and narrowly scoped
protocol-BFF/static support paths;
the full admin console and platform admin APIs remain platform-host-only. For
details see [configuration.md](configuration.md) and
[tls-and-gateway.md](tls-and-gateway.md).

## 6. Onboard the first tenant

With first-run setup complete, create a tenant from the admin console or the
platform admin REST API. Tenant registration requires tenant AS, tenant KMS,
DID, issuer, and verifier to be running, because the platform seeds tenant
signing material and tenant DID state through those east-west services.

The tenant workload services fetch their effective configuration from the
platform and serve the tenant endpoints registered during onboarding. If a
workload was not running when tenant registration starts, re-run the same
`up -d` command before registering the tenant.

The `scripts/provision` helper and Postman collection are optional validation
and automation tools. They call the same setup and tenant admin APIs against the
running platform, but they are not required for the normal customer setup path.
See [onboarding.md](onboarding.md).

## Stop the stack

```bash
docker compose -f docker-compose.yml down -v
```

Use the same overlay file you used when starting the stack:

```bash
docker compose -f docker-compose.yml -f docker-compose.gateway.yml down -v
docker compose -f docker-compose.yml -f docker-compose.letsencrypt.yml down -v
```

The `-v` flag removes the stack volumes. Omit it to keep data between runs.
