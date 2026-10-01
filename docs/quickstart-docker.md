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
docker pull nexus.sphereon.com/edk-docker/enterprise-platform:<approved-release-tag>
```

## 2. Configure the stack

Copy the example environment file in `compose/`:

```bash
cd compose
cp .env.example .env
```

Set `EDK_TAG` to the approved image tag and `EDK_PLATFORM_BASE_DOMAIN` to the
installation base domain. Everything else is generated or has a working
default:

1. Generate the secret-authority key set:

   ```powershell
   ..\scripts\generate-secret-authority-keys.ps1 -OutputDirectory .\.secret-authority\current
   ```

   On Linux or macOS:

   ```bash
   ../scripts/generate-secret-authority-keys.sh ./.secret-authority/current
   ```

   The platform receives the central private key and the workload public keys;
   each service container mounts only its own assertion private key plus the
   central public key. The generated directory is ignored by Git.

2. Fill the remaining secrets and copy the secret-authority coordinates into
   `.env`:

   ```bash
   node ../scripts/generate-compose-secrets.mjs
   ```

   The script only fills empty values. Rerunning it never rotates a credential.

No external secret provider is required at startup. The baseline uses the
persisted platform software KMS. Cloud key providers are optional and are
configured after the platform is running, or declared in the optional block at
the end of `.env.example`.

The two bundled PostgreSQL containers are for evaluation. To use external
databases instead, keep the platform and tenant databases separate. They may
share a PostgreSQL server, but not a database name, credential, or
authorization boundary.

When upgrading an older Compose environment, remove the legacy single-database
keys `EDK_DB_NAME`, `EDK_DB_USERNAME`, `EDK_DB_PASSWORD`, and
`EDK_POSTGRES_HOST_PORT` from `.env`, keep your existing `EDK_PLATFORM_DB_*`
and `EDK_TENANT_DB_*` values, and run `generate-compose-secrets.mjs` once. It
adds the secrets that newer releases require, for example the per-service
`EDK_INTERNAL_CLIENT_SECRET_*` values introduced in RC4 and
`EDK_FEDERATION_SESSION_ENCRYPTION_KEY`, without changing existing values. It
also lists values that still come from an earlier published template; rotate
those in a planned maintenance window.

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
required release, and waits for the complete stack after every step. From any
0.25.0 release candidate it upgrades directly to 0.25.0; an RC1 installation
passes through RC2 first. It refuses a downgrade, and repeating the command is
idempotent.

Before upgrading, back up both databases and run
`node ../scripts/generate-compose-secrets.mjs` once. It adds the secrets 0.25.0
requires without changing existing values. For the complete list of changes and
manual steps from RC4 or RC5, see
[Upgrading a Docker Compose installation to 0.25.0](upgrade-0.25.0.md).

An RC4 `config/platform.application.yml` configures the platform
authorization server under `oauth2.servers.default` and reads its WebAuthn
`rp-id` and `allowed-origins` from `EDK_PLATFORM_BASE_DOMAIN` and
`EXTERNAL_BASE_URL`. The 0.25.0 platform accepts these environment
references, so the RC4 file needs no edits to upgrade. The 0.25.0-RC5 platform
image rejects them and stops during authority bootstrap with
`VDX_CONFIGURATION_INTERPOLATION_DENIED` for
`oauth2.servers.default.webauthn.rp.id`; upgrade such an installation
directly from RC4 to 0.25.0 instead of through RC5.

The configuration shipped with this kit names the same server `platform` and
selects it with `oauth2.servers.default-server: platform`. To move to that
layout, take the kit's `platform.application.yml` and reapply your own changes
to it. Replace the `oauth2.servers.default` block rather than keeping it next
to the new `platform` block.

An RC5 `config/platform.application.yml` declares the optional shared Azure
and AWS KMS providers under unquoted ids such as `azure-shared-signing`.
0.25.0 reads provider ids only in bracket-quoted form (`"[azure-shared-signing]"`).
While `EDK_PLATFORM_KMS_AZURE_KIND` and `EDK_PLATFORM_KMS_AWS_KIND` are unset,
the RC5 file starts unchanged and declares no provider, exactly as in RC5. To
activate one of these providers, take the kit's `platform.application.yml`
first; with an unquoted id and a kind set, startup stops with
`INVALID_CONFIGURATION`.

When startup refuses a configuration placeholder, the error names the
property, the property source that supplied it (`yaml.app` for the mounted
YAML files, `db.postgresql` or `tenant-config-db` for stored configuration),
and the reason. It never prints the configured value.

Linux/macOS:

```bash
bash ../scripts/upgrade-compose.sh --image-tag 0.25.0
```

Windows PowerShell:

```powershell
..\scripts\upgrade-compose.ps1 -ImageTag 0.25.0
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

Use the same files you used when starting the stack. This keeps all data:

```bash
docker compose -f docker-compose.yml -f docker-compose.gateway.yml down
```

Adding `--volumes` deletes the databases, keystores and blob store. Use it only
when you intend to destroy the installation.
