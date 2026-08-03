# EDK Enterprise Deployment Kit

This kit deploys the EDK enterprise platform from published container images. It contains the Helm chart, a Docker Compose stack, gateway TLS helpers, and optional scripts/Postman assets for validating first-run setup and tenant onboarding.

You run published images only. The kit does not build anything. Customer deployments use the public Enterprise Development Kit Deployment repository: <https://github.com/Sphereon-Opensource/Enterprise-Development-Kit-Deployment>.

## What you deploy

The deployment runs these backing images. They are not customer URLs; customers
and operators enter only through the platform host and tenant gateway hosts. The
gateway maps host/path routes to the backing containers internally.

| Image | Backing responsibility |
| --- | --- |
| `nexus.sphereon.com/edk-docker/enterprise-platform` | Central control plane: first-run setup, license activation, platform admin, platform configuration, and platform authorization server |
| `nexus.sphereon.com/edk-docker/enterprise-tenant-kms` | Key management for all services |
| `nexus.sphereon.com/edk-docker/enterprise-did` | DID resolver and `did:web` hosting |
| `nexus.sphereon.com/edk-docker/enterprise-tenant-as` | Tenant OAuth2 authorization server |
| `nexus.sphereon.com/edk-docker/enterprise-wallet-unit` | Server-side wallet-unit lifecycle and policy-gated wallet-key commands |
| `nexus.sphereon.com/edk-docker/enterprise-wallet-interaction` | Headless wallet interaction runtime for issuer/verifier wallet protocol flows |
| `nexus.sphereon.com/edk-docker/enterprise-issuer` | OID4VCI credential issuer |
| `nexus.sphereon.com/edk-docker/enterprise-verifier` | OID4VP credential verifier |

The platform, tenant-KMS, wallet-unit, and wallet-interaction containers also run internal gRPC receivers. Runtime services call the platform service over internal gRPC for platform configuration and control-plane data. DID, tenant-AS, issuer, and verifier call tenant-KMS over internal gRPC for KMS operations. Issuer and verifier call wallet-interaction, and wallet-interaction calls wallet-unit, over internal gRPC for headless wallet operations. gRPC is east-west only and must never be routed through the public gateway.

The customer-visible surface is the gateway route table, not backing services or
container ports. It is limited to `platform.<base-domain>` for the
operator/admin plane and `<tenant>.<base-domain>` for tenant protocol and
authenticated management paths. Runtime probes such as `/health` and `/ready`
are orchestration concerns inside Docker Compose or Kubernetes and are not part
of the customer route contract. Every
administrative REST path (`/api/.../v1`) is internal or
operator-authenticated and must be protected by JWT or service-mesh policy.

One optional container completes the platform:

| Image | Role | Public ingress |
| --- | --- | --- |
| `nexus.sphereon.com/edk-docker/admin-console` | Next.js platform/tenant admin console and issuer/verifier testing console | `/admin-console` on the platform host and every registered tenant host |

The admin console is a separately published Next.js app, not something this kit builds. The same image runs as two isolated processes: the platform runtime at `https://platform.<base-domain>/admin-console`, and the tenant runtime at `https://<tenant>.<base-domain>/admin-console`. The tenant runtime has no platform BFF credential, resolves the tenant and its default AS from the registered host, and cannot expose the platform-management persona. Issuer/verifier testing-console routes remain on the tenant runtime and retain their endpoint-registry access checks.

## Domain and TLS model

Every EDK installation is anchored on one customer-controlled base domain. The platform is a subdomain of that base domain, and tenants are sibling subdomains:

- Base domain: `example.com`
- Platform/operator host: `platform.example.com`
- Tenant hosts: `<tenant-slug>.example.com`, for example `acme.example.com`

The platform and tenants are not separate DNS zones in the application model. They are subdomains under the same base domain, and tenant resolution depends on the inbound `Host` header. Your gateway, ingress controller, CDN, or load balancer must forward the original public Host header unchanged.

![EDK base domain and subdomain model](docs/assets/base-domain-model.svg)

Terminate TLS at the public gateway or load balancer with a certificate that
covers the platform host and all first-level tenant hosts. The recommended
operational model is one wildcard certificate for `*.<base-domain>`. A public
CA such as Let's Encrypt is fine; in Kubernetes, issue it with cert-manager
DNS-01 or import an existing wildcard certificate as a TLS Secret. A wildcard
for `*.example.com` covers `platform.example.com` and `acme.example.com`, but it
does not cover the apex `example.com` or nested names such as
`api.acme.example.com`. The apex/base domain is not exposed by the standard EDK
gateway model.

## Prerequisites

- Nexus credentials for the published `nexus.sphereon.com/edk-docker/enterprise-*` and `nexus.sphereon.com/edk-docker/admin-console` images for the selected `EDK_TAG`.
- Docker Compose pins the enterprise image repository to `nexus.sphereon.com/edk-docker`; only the tag is configurable. Do not reintroduce `sphereon` or `docker.io/sphereon`, because those names resolve to public Docker Hub and are not EDK enterprise image locations.
- A protected license bundle ZIP, or access to the license issuer provided through your EDK distribution channel. The setup UI generates the license recipient key when it creates the license request and includes only its public key in that request. You import the protected bundle during platform setup, and setup must also create the first operator account. Evaluation bundles can include the test root CA material when needed.
- TLS material for the operator and tenant hosts. Use one wildcard certificate
  for `*.<base-domain>`, or individual certificates for every tenant host and
  the operator host. The wildcard model is recommended because tenants are
  hosted as `<tenant>.<base-domain>` and can be onboarded without per-tenant
  certificate work.
- Two PostgreSQL databases: one platform/control-plane database and one tenant workload database. The Docker Compose stack starts separate local Postgres containers for evaluation. For Kubernetes or production-style deployments, use managed, operator-managed, or separately run databases and point the deployment at them with separate credentials Secrets or connection settings. Never put platform and tenant state in the same database in an enterprise deployment.
- For Kubernetes, a runtime Secret containing independently generated `internal-client-secret` and `keystore-password` values. The Secret name is referenced by `serviceIdentity.internalClientExistingSecret` and `keystore.existingSecret`; the chart never generates these credentials.

## Required Database Boundary

Every enterprise deployment needs two logical databases:

- `platform` database: platform/control-plane state, including tenant registry,
  routing, tenant gateway endpoint bindings, platform configuration, license/setup state, and
  the platform authorization server.
- `tenant` database: tenant workload state. The default deployment stores each
  tenant in its own schema inside this tenant database.

Do not collapse these into one PostgreSQL database, even with separate schemas.
The platform database and tenant database may run on the same PostgreSQL server
only when they remain separate database names with separate credentials and
network access rules. Satellite services never receive platform database
credentials; they read platform-owned configuration from the platform service
and use only the tenant workload database for runtime tenant data.

## Choose your path

### Docker Compose (evaluation, single node)

Use the stack under `compose/` to run the services on one machine. Run it two ways:

- The base file `compose/docker-compose.yml` alone publishes each service on its own loopback host port over plain HTTP for low-level local debugging only. The customer walkthroughs assume the gateway model below.
- The base file plus the gateway overlay `compose/docker-compose.gateway.yml` starts the platform, tenant AS, tenant KMS, DID, issuer, verifier, admin console, and Traefik gateway. The gateway routes by host and path on a single TLS port. The operator plane is `https://platform.<base-domain>`; tenant protocol URLs are bound during onboarding as `https://<tenant-slug>.<base-domain>`. `EDK_PLATFORM_BASE_DOMAIN` is mandatory. For explicit localtest evaluation, generate the wildcard certificate with `scripts/gen-local-wildcard-cert.ps1 -Localtest` (Windows) or `scripts/gen-local-wildcard-cert.sh --localtest` (Linux/macOS), then trust the local CA.

Follow [docs/quickstart-docker.md](docs/quickstart-docker.md).

For installs and upgrades, use `scripts/upgrade-compose.sh` or
`scripts/upgrade-compose.ps1`. The wrappers detect the installed release and
automatically execute RC1-to-RC2-to-RC3 when RC3 is requested from RC1, waiting
for health checks at each release. Repeating the same target is safe and does
not recreate database volumes.

### Kubernetes (production)

Use the Helm chart under `helm/edk-enterprise/` for production. The chart renders deployments, services, ingress (or a single-port Gateway API front door), NetworkPolicies, and security defaults for the platform, runtime services, and admin console. The gateway examples under `helm/edk-enterprise/examples/` cover Cilium, GKE, AWS ALB, and Azure AGIC.

For a platform-first Linux/macOS install or upgrade, run the reusable
wrapper from the repository root. The command is release-independent: select
the immutable image tag named by the release you are installing:

```bash
export TARGET_IMAGE_TAG='<approved-release-tag>'

bash ./scripts/upgrade-helm.sh \
  --values ./customer-values.yaml \
  --image-tag "$TARGET_IMAGE_TAG" \
  --tenant-host abc.example.com
```

The wrapper reads the installed `global.imageTag` and automatically applies the
known transition overlays cumulatively and in order. RC1 to RC3 is executed as
two Helm revisions, RC1 to RC2 and then RC2 to RC3. Repeating the target release
reapplies the same cumulative compatibility set, so the original customer values
file cannot undo an earlier transition. `--migration-values` remains available only for
an additional site- or release-specific overlay not known to the wrapper. The
[Kubernetes quickstart](docs/quickstart-kubernetes.md#upgrading-directly-from-0250-rc1-to-0250-rc3)
shows the direct upgrade and migration checks.

The wrapper preserves existing cryptographic Secrets, creates missing Secrets
only when safe, backs up the installed release, lints and renders the target
chart, quiesces the complete release, performs a Helm upgrade without automatic
rollback, waits for the rollout, and optionally checks the tenant DID document.

Before every upgrade, take `pg_dump` snapshots of both databases: the platform
database and the tenant workload database. Database schema and data migrations
run in the platform service while every other workload is stopped. If an
upgrade fails, the wrapper scales the release to zero and leaves Helm at the
failed revision. Restore both database snapshots first and only then run an
explicit `helm rollback` or retry. Restoring the pre-upgrade database snapshots
is the only supported binary rollback.

The 0.25.0-RC2 to 0.25.0-RC3 upgrade migrates the default environment-based
secret setup automatically. Any other stored secret-provider state fails the
upgrade closed with a diagnostic that names the offending configuration rows
by tenant and key; secret values are never printed. Secret management does not
import, adopt, or dual-read prior provider or migration state.

The 0.25.0-RC2 to 0.25.0-RC3 upgrade path is supported on PostgreSQL only.
MySQL deployments start at 0.25.0-RC3 as fresh installs; there is no MySQL
upgrade lineage.

### Upgrading without the wrapper

From 0.25.0-RC3 the backend Deployments use the `Recreate` strategy, so the old
pod always stops before the new one starts and only one schema generation ever
reaches the database. A release installed with an earlier version carries the
`RollingUpdate` default, and Kubernetes rejects an update that leaves
`spec.strategy.rollingUpdate` set while the type changes to `Recreate`. The
whole upgrade then fails with:

```
Deployment.apps "<release>-edk-enterprise-platform" is invalid:
spec.strategy.rollingUpdate: Forbidden: may not be specified when strategy
`type` is 'Recreate'
```

`scripts/upgrade-helm.sh` converts the strategy for you. When you drive
`helm upgrade` directly, stop the release and convert each backend Deployment
once, before the upgrade:

```bash
kubectl -n "$NAMESPACE" scale deployment \
  -l "app.kubernetes.io/instance=$RELEASE" --replicas=0
kubectl -n "$NAMESPACE" wait --for=delete pod \
  -l "app.kubernetes.io/instance=$RELEASE" --timeout=5m

for deployment in $(kubectl -n "$NAMESPACE" get deployment \
  -l "app.kubernetes.io/instance=$RELEASE" -o name); do
  kubectl -n "$NAMESPACE" patch "$deployment" --type=merge \
    -p '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null}}}'
done
```

The patch is idempotent and applies to the admin console as well, which keeps
its own strategy from the chart on the next render. Releases created at
0.25.0-RC3 or later need no conversion.

Follow [docs/quickstart-kubernetes.md](docs/quickstart-kubernetes.md).

## First-run setup and tenant onboarding

Once the full stack is up, complete first-run setup at
`https://platform.<base-domain>/setup-license` or through the setup API. Setup
generates the license request, imports the protected license bundle, and creates
the first platform operator account. After that, sign in at
`https://platform.<base-domain>/admin-console` and create tenants from the admin
console or platform admin API.

Tenant registration creates the default AS, KMS, DID, issuer, verifier, and
gateway route metadata through the already-running workload services. The
`scripts/provision` helper and Postman collection call the same APIs and are
provided as optional validation and automation tools.

Follow [docs/onboarding.md](docs/onboarding.md).

For a non-interactive release gate against the literal customer Compose
topology, use
[docs/compose-postman-release-gate.md](docs/compose-postman-release-gate.md).
That gate requires one immutable seven-image tag whose OCI version matches the
tag, inventories project containers/networks/volumes before mutation, and
retains sanitized Compose, Newman, database-schema, runtime image-ID, setup
identity, teardown, and plaintext-canary evidence under a terminal hashed
manifest.

## Repository map

```
Enterprise-Development-Kit-Deployment/
  README.md                       This file
  docs/
    quickstart-docker.md          Bring the stack up with Docker Compose
    quickstart-kubernetes.md      Install the Helm chart on Kubernetes
    onboarding.md                 First-run setup, tenant creation, and optional validation helpers
    compose-postman-release-gate.md  Non-interactive customer Compose plus Postman release gate
    tls-and-gateway.md            Single-port TLS, gateway, and ingress options
    configuration.md              Configuration inputs and public hostnames
    secret-management.md          Secret-management trust tiers and deployment prerequisites
    troubleshooting.md            Common problems and checks
  compose/
    docker-compose.yml            Base stack: enterprise services on individual host ports
    docker-compose.gateway.yml    Overlay: single TLS port behind a Traefik gateway
    .env.example                  Environment template (copy to .env)
    config/                       Per-service configuration templates
    gateway/
      traefik/                    Traefik static and dynamic gateway configuration
      certs/                      Local wildcard certificate output (generated)
  helm/
    edk-enterprise/               Helm chart for the enterprise services and admin console
      values.yaml                 Default values
      values.schema.json          Values schema
      README.md                   Chart reference (values, security, ingress)
      examples/                   Ready-to-copy values overlays (incl. gateway and admin-console examples)
      templates/                  Chart templates
  scripts/
    upgrade-helm.sh                Safe Helm install/upgrade wrapper (Linux/macOS)
    upgrade-compose.sh             Ordered Compose install/upgrade wrapper
    upgrade-compose.ps1            Ordered Compose install/upgrade wrapper (Windows)
    provision.ps1                 Optional setup and tenant onboarding validation over REST (Windows)
    provision.sh                  Optional setup and tenant onboarding validation over REST (Linux/macOS)
    gen-local-wildcard-cert.ps1   Local-evaluation wildcard TLS cert for the gateway (Windows)
    gen-local-wildcard-cert.sh    Local-evaluation wildcard TLS cert for the gateway (Linux/macOS)
  postman/
    EDK-Enterprise-Deployment.postman_collection.json
    EDK-Enterprise-Deployment.customer.postman_environment.json
```
