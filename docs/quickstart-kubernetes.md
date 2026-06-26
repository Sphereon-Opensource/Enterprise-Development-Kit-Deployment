# Quickstart: Kubernetes

This path installs the EDK enterprise services on Kubernetes using the Helm chart under `helm/edk-enterprise/`. The chart renders deployments, services, ingress (or a single-port Gateway API front door), NetworkPolicies, and hardened security defaults.

Use the public Enterprise Development Kit Deployment repository: <https://github.com/Sphereon-Opensource/Enterprise-Development-Kit-Deployment>.

The chart reference, including every value and its default, is in [helm/edk-enterprise/README.md](../helm/edk-enterprise/README.md).

## Prerequisites

- A Kubernetes cluster and `kubectl` configured against it.
- Helm 3.
- Nexus credentials for the published `nexus.sphereon.com/edk-docker/enterprise-*` and `nexus.sphereon.com/edk-docker/admin-console` images for the selected `global.imageTag`.
- Keep `global.imageRegistry=nexus.sphereon.com/edk-docker`. Do not use `sphereon` or `docker.io/sphereon`; those values point Kubernetes at public Docker Hub.
- Reachable PostgreSQL 15+ databases for the platform control plane and tenant workload data plane. The chart does not deploy Postgres. Use managed databases, operator-managed databases, or environment-owned Postgres releases, then point `database.platform.*` and `database.tenant.*` at them. These must be two separate logical databases; never put platform and tenant state in the same database, even with separate schemas.
- A Sphereon protected license bundle ZIP, ready to import during onboarding.
- TLS material for the operator and tenant hosts. Use one wildcard certificate
  for `*.<base-domain>`, or individual certificates for every deployed host.
  For Let's Encrypt wildcard certificates, use cert-manager with DNS-01
  validation.

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

## 3. Pick a values overlay

The `examples/` directory holds ready-to-copy overlays. Start from one and adjust:

| File | Purpose |
| --- | --- |
| `shared-postgres-values.yaml` | Environment-owned in-cluster Postgres endpoints for separate platform and tenant databases, JWT auth wired to the tenant AS |
| `external-managed-postgres-values.yaml` | Managed external Postgres with an egress NetworkPolicy |
| `service-jwt-auth-values.yaml` | Require JWT on each service's admin REST |
| `secret-backed-credentials-values.yaml` | Pull signing and provider credentials from Secrets |
| `admin-console-values.yaml` | Enable the optional admin console and its `/admin-console` route on the platform host |
| `gateway-cilium-values.yaml` | Single-port multi-tenant front door via Cilium Gateway API |
| `gateway-aws-alb-values.yaml`, `gateway-gke-values.yaml`, `gateway-azure-agic-values.yaml` | Cloud gateway variants |
| `mesh-mtls-values.yaml` | Service-mesh mTLS for inter-service traffic |
| `opentelemetry-values.yaml` | OTLP exporter wiring |

Set `global.platformBaseDomain` to the customer-controlled base domain for the installation. The platform host is `platform.<base-domain>` and tenant hosts are `<tenant-slug>.<base-domain>`. Point DNS for `platform.<base-domain>` and `*.<base-domain>` at the gateway address. Do not publish runtime probes or backing service hosts as customer endpoints.

## 4. Render and install

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

## 5. Ingress and gateway

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

**Admin console.** The optional `services.admin-console` service (image, `enabled`, `replicas`, `restPort: 3000`) renders the Next.js operator console behind the `/admin-console` route on the platform host. After first-run setup activates the license and creates the operator account, operators sign in at `https://platform.<base-domain>/admin-console`. The route is served without stripping the prefix and must take precedence over the platform catch-all. The `enableTenantConsole: false` flag gates the future per-tenant route. Enable it with `examples/admin-console-values.yaml`. See [tls-and-gateway.md](tls-and-gateway.md) for the routing details.

## 6. Security defaults

The chart runs every service as non-root UID/GID `10001` with a read-only root filesystem, dropped Linux capabilities, the runtime default seccomp profile, REST auth enabled, JWT auth wiring enabled, and NetworkPolicies enabled. For production, set non-empty `auth.jwt.issuer`, `auth.jwt.jwksUri`, and `auth.jwt.audience`. The example overlays point the JWT issuer and JWKS URI at the tenant AS.

## 7. First-run setup and tenant onboarding

With the release running, open `https://platform.<base-domain>/setup-license`
or `https://platform.<base-domain>/admin-console` and complete first-run setup.
Setup generates the license request, imports the protected license bundle, and
bootstraps the first platform operator account. After setup closes the anonymous
setup gate, sign in at `https://platform.<base-domain>/admin-console` and create
tenants from the admin console or platform admin API.

The `scripts/provision` helper and Postman collection are optional validation
and automation tools that call the same APIs against the running platform. See
[onboarding.md](onboarding.md).
