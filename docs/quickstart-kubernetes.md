# Quickstart: Kubernetes

This path installs the EDK enterprise services on Kubernetes using the Helm chart under `helm/edk-enterprise/`. The chart renders deployments, services, ingress (or a single-port Gateway API front door), NetworkPolicies, and hardened security defaults.

Use the public Enterprise Development Kit Deployment repository: <https://github.com/Sphereon-Opensource/Enterprise-Development-Kit-Deployment>.

The chart reference, including every value and its default, is in [helm/edk-enterprise/README.md](../helm/edk-enterprise/README.md).

## Prerequisites

- A Kubernetes cluster and `kubectl` configured against it.
- Helm 3 or Helm 4.
- Nexus credentials for the published `nexus.sphereon.com/edk-docker/enterprise-*` and `nexus.sphereon.com/edk-docker/admin-console` images for the selected `global.imageTag`.
- Keep `global.imageRegistry=nexus.sphereon.com/edk-docker`. Do not use `sphereon` or `docker.io/sphereon`; those values point Kubernetes at public Docker Hub.
- Reachable PostgreSQL 15+ databases for the platform control plane and tenant workload data plane. The chart does not deploy Postgres. Use managed databases, operator-managed databases, or environment-owned Postgres releases, then point `database.platform.*` and `database.tenant.*` at them. These must be two separate logical databases; never put platform and tenant state in the same database, even with separate schemas.
- A protected license bundle ZIP from the license issuer provided through your EDK distribution channel, ready to import during onboarding.
- TLS material for the operator and tenant hosts. Use one wildcard certificate
  for `*.<base-domain>`, or individual certificates for every deployed host.
  For Let's Encrypt wildcard certificates, use cert-manager with DNS-01
  validation.

## Recommended one-go install or upgrade

From the repository root on Linux or macOS, use the release-independent
wrapper. Select the immutable image tag named by the release you are installing:

```bash
export TARGET_IMAGE_TAG='<approved-release-tag>'

bash ./scripts/upgrade-helm.sh \
  --release sphereon-edk-enterprise \
  --namespace edk \
  --values ./customer-values.yaml \
  --image-tag "$TARGET_IMAGE_TAG" \
  --tenant-host abc.example.com
```

`--release` and `--namespace` are yours to choose. The values shown are the
wrapper defaults; pass the release name and namespace this install actually uses.

The wrapper preserves existing cryptographic Secrets, backs up the installed
release, validates the candidate manifests, selects the supported Helm 3 or 4
rollback-on-failure flag, waits for all Deployments, and optionally verifies
the tenant DID document. Add `--migration-values <path>` only when the selected
release explicitly supplies a migration overlay.

## Upgrading from 0.25.0-RC1 to 0.25.0-RC2

0.25.0-RC1 shipped Helm defaults that left `/.well-known` off the DID service's
anonymous path list. That path serves the tenant DID document, and with it
behind bearer-token auth the document could not be fetched anonymously, so
tenant creation could not complete. 0.25.0-RC2 corrects the defaults so the DID
document and the other public discovery paths resolve without a token.

A values file exported from an RC1 install can still carry the old, empty
anonymous-path settings, and those would override the corrected RC2 defaults.
The overlay at
`helm/edk-enterprise/examples/upgrades/0.25.0-rc1-to-0.25.0-rc2-values.yaml`
re-asserts the correct public paths. Pass it after your own values file so it
takes precedence. Set `--release` and `--namespace` to the release name and
namespace of your existing RC1 install, not the placeholders below. If you did
not override them when you installed, the wrapper defaults are
`sphereon-edk-enterprise` and `edk`.

```bash
bash ./scripts/upgrade-helm.sh \
  --release <your-release> \
  --namespace <your-namespace> \
  --values ./customer-values.yaml \
  --image-tag 0.25.0-RC2 \
  --migration-values ./helm/edk-enterprise/examples/upgrades/0.25.0-rc1-to-0.25.0-rc2-values.yaml
```

The overlay sets only `serviceIdentity.anonymousPathPrefixes`. It holds no
Secret values and is specific to this one transition, so do not carry it into
later upgrades.

After the upgrade completes, create a tenant from the admin console. This now
succeeds because the DID document resolves without a token. Confirm it by
fetching `https://<tenant-host>/.well-known/did.json` along with the tenant
metadata paths listed in [onboarding.md](onboarding.md). Once a tenant exists,
you can also re-run the wrapper with `--tenant-host <tenant-host>` so it checks
the DID document for you.

## 1. Create the namespace and pull secret

```bash
kubectl create namespace edk

kubectl -n edk create secret docker-registry sphereon-nexus \
  --docker-server=nexus.sphereon.com \
  --docker-username=<username> \
  --docker-password=<password>
```

Reference the pull secret from your values with `global.imagePullSecrets`.

## 2. Create the database credentials secrets

The chart reads database usernames and passwords from existing Secrets named by
`database.platform.existingSecret` and `database.tenant.existingSecret`. Create
separate Secrets for the platform database and tenant workload database:

```bash
kubectl -n edk create secret generic edk-platform-postgres \
  --from-literal=username=edk_platform \
  --from-literal=password=<platform-db-password>

kubectl -n edk create secret generic edk-tenant-postgres \
  --from-literal=username=edk_tenant \
  --from-literal=password=<tenant-db-password>
```

Point the chart at the control-plane database through
`database.platform.host`, `database.platform.port`, and
`database.platform.name`, and at the tenant workload database through
`database.tenant.host`, `database.tenant.port`, and `database.tenant.name`.
The two databases may live on the same PostgreSQL server only if they are
separate database names with separate credentials. Do not reuse one database or
one shared credential for both endpoints in an enterprise deployment.
Tenant schemas are created inside the tenant workload database; they are not a
replacement for the platform/tenant database split.

## 3. Create the runtime Secret

The chart does not generate the confidential client secret used for east-west
service tokens or the password protecting the software PKCS#12 keystores. Create
both values in the release namespace before installing. `edk-runtime-secrets`
is an example Kubernetes Secret name, not an image or prepackaged file:

The corresponding Helm parameters are `serviceIdentity.internalClientExistingSecret`
and `keystore.existingSecret`.

```bash
kubectl -n edk create secret generic edk-runtime-secrets \
  --from-literal=internal-client-secret='<long-random-confidential-client-secret>' \
  --from-literal=admin-console-portal-bff-secret='<independent-long-random-portal-bff-secret>' \
  --from-literal=keystore-password='<long-random-pkcs12-password>'
```

Generate the two values independently with at least 32 random bytes each. For
production, have the cluster's secret-management mechanism create this Secret;
do not commit Secret manifests containing plaintext values.

Reference the Secret name and keys from the values overlay:

```yaml
serviceIdentity:
  internalClientExistingSecret: edk-runtime-secrets
  internalClientSecretKey: internal-client-secret
keystore:
  existingSecret: edk-runtime-secrets
  passwordKey: keystore-password
portalBff:
  existingSecret: edk-runtime-secrets
  clientSecretKey: admin-console-portal-bff-secret
```

`internal-client-secret` is shared by the platform authorization server and the
registered satellite confidential clients so they can obtain short-lived
east-west tokens. `admin-console-portal-bff-secret` belongs only to the dedicated
portal BFF confidential client. `keystore-password` protects the platform and tenant-KMS
software keystores. Changing Secret data under the same name requires restarting
the affected Deployments because these values are read when containers start.

## 4. Pick a values overlay

The `examples/` directory holds ready-to-copy overlays. Start from one and adjust:

| File | Purpose |
| --- | --- |
| `shared-postgres-values.yaml` | Environment-owned in-cluster Postgres endpoints for separate platform and tenant databases, JWT auth wired to the tenant AS |
| `external-managed-postgres-values.yaml` | Managed external Postgres with an egress NetworkPolicy |
| `local-docker-desktop-values.yaml` | Port-forwarded Docker Desktop evaluation without Gateway API or Ingress resources |
| `service-jwt-auth-values.yaml` | Require JWT on each service's admin REST |
| `secret-backed-credentials-values.yaml` | Pull signing and provider credentials from Secrets |
| `admin-console-values.yaml` | Configure the platform console and isolated issuer/verifier testing-console routes |
| `gateway-cilium-values.yaml` | Single-port multi-tenant front door via Cilium Gateway API |
| `gateway-aws-alb-values.yaml`, `gateway-gke-values.yaml`, `gateway-azure-agic-values.yaml` | Cloud gateway variants |
| `mesh-mtls-values.yaml` | Service-mesh mTLS for inter-service traffic |
| `opentelemetry-values.yaml` | OTLP exporter wiring |

Set `global.platformBaseDomain` to the customer-controlled base domain for the installation. The platform host is `platform.<base-domain>` and tenant hosts are `<tenant-slug>.<base-domain>`. Point DNS for `platform.<base-domain>` and `*.<base-domain>` at the gateway address. Do not publish runtime probes or backing service hosts as customer endpoints.

## 5. Render and install

Render first so you can review the manifests:

```bash
helm template edk ./helm/edk-enterprise \
  -n edk \
  -f ./helm/edk-enterprise/examples/shared-postgres-values.yaml
```

Then install or upgrade:

```bash
helm upgrade --install edk ./helm/edk-enterprise \
  -n edk \
  -f ./helm/edk-enterprise/examples/shared-postgres-values.yaml
```

Rendering validates that both runtime Secret references are configured. Helm
cannot verify Secret objects or keys at render time; use the checks in
[troubleshooting.md](troubleshooting.md) if pods enter
`CreateContainerConfigError` after installation.

## 6. Ingress and gateway

Use the single-port Gateway API front door. The chart defaults to
`gateway.enabled: true` and `ingress.legacy.enabled: false`, so one HTTPS
listener fronts the platform host and all tenant hosts. HTTPRoutes fan out by
host and path to each backing service. The operator host is
`{gateway.operatorHost}.{baseDomain}` (default `platform.<baseDomain>`), and
each tenant is reached at `<slug>.<baseDomain>`. Provide wildcard TLS material
with `gateway.tls.mode: secret` and an existing Secret, or
`gateway.tls.mode: certManager` with a cert-manager ClusterIssuer. For Let's
Encrypt wildcard certificates, configure the ClusterIssuer for DNS-01, not
HTTP-01. Individual certificates per host are possible, but each tenant host
certificate must exist before that tenant host goes live. The cloud gateway
example overlays cover AWS, GKE, Azure, and Cilium.

Whichever model you choose, the customer-visible contract is the platform host
and tenant gateway hosts. DID resolver, OAuth/OIDC, OID4VCI, OID4VP, and any
selected operator/admin API paths are host/path routes through that front door.
Customers do not call pods or containers directly. Keep every `/api/.../v1`
path internal or protected by operator/tenant authentication, and never publish
runtime probes as customer-facing routes.

**Admin console and testing console.** `services.admin-console` serves the complete operator console behind `/admin-console` on the platform host. On wildcard instance hosts the canonical public page is `/testing-console/{kind}/{instanceId}`. A page-only Gateway API rewrite maps that prefix to Next's internal `/admin-console/testing-console` path; a separate rule forwards only the testing APIs, portal OAuth, required Next/public assets, and health beneath `/admin-console`. The application repeats this host/path allowlist, while the backend public-endpoint registry enforces disabled/public/AS-protected instance modes. Routing alone never enables an instance. The testing console is intended for external issuer/verifier testers and other conformance participants. See `examples/admin-console-values.yaml` and [tls-and-gateway.md](tls-and-gateway.md).

## 7. Security defaults

The chart runs every service as non-root UID/GID `10001` with a read-only root filesystem, dropped Linux capabilities, the runtime default seccomp profile, REST auth enabled, JWT auth wiring enabled, and NetworkPolicies enabled. For production, set non-empty `auth.jwt.issuer`, `auth.jwt.jwksUri`, and `auth.jwt.audience`. The example overlays point the JWT issuer and JWKS URI at the tenant AS.

## 8. First-run setup and tenant onboarding

With the release running, open `https://platform.<base-domain>/setup-license`
or `https://platform.<base-domain>/admin-console` and complete first-run setup.
Setup generates the license request, imports the protected license bundle, and
bootstraps the first platform operator account. After setup closes the anonymous
setup gate, sign in at `https://platform.<base-domain>/admin-console` and create
tenants from the admin console or platform admin API.

The `scripts/provision` helper and Postman collection are optional validation
and automation tools that call the same APIs against the running platform. See
[onboarding.md](onboarding.md).
