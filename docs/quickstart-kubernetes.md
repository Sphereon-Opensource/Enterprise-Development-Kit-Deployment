# Quickstart: Kubernetes

This path installs the EDK enterprise services on Kubernetes using the Helm chart under `helm/edk-enterprise/`. The chart renders deployments, services, ingress (or a single-port Gateway API front door), NetworkPolicies, and hardened security defaults.

Use the public Enterprise Development Kit Deployment repository: <https://github.com/Sphereon-Opensource/Enterprise-Development-Kit-Deployment>.

The chart reference, including every value and its default, is in [helm/edk-enterprise/README.md](../helm/edk-enterprise/README.md).

## Prerequisites

- A Kubernetes cluster and `kubectl` configured against it.
- Helm 3.
- Nexus credentials for the private `nexus.sphereon.com/edk-docker` enterprise image repository.
- A reachable PostgreSQL 15 database. The chart does not deploy Postgres. Use a managed database, an operator-managed database, or an environment-owned Postgres release, then point `database.host` and `database.existingSecret` at it.
- A Sphereon protected license bundle ZIP plus bundle key, ready to import during onboarding.
- TLS material for the operator and tenant hosts. Use a wildcard certificate for `*.<base-domain>` plus `platform.<base-domain>`, or individual certificates for every deployed host. For Let's Encrypt wildcard certificates, use cert-manager with DNS-01 validation.

## 1. Create the namespace and pull secret

```bash
kubectl create namespace edk

kubectl -n edk create secret docker-registry sphereon-nexus \
  --docker-server=nexus.sphereon.com \
  --docker-username=<username> \
  --docker-password=<password>
```

Reference the pull secret from your values with `global.imagePullSecrets`.

## 2. Create the database credentials secret

The chart reads the database username and password from an existing Secret named by `database.existingSecret`:

```bash
kubectl -n edk create secret generic edk-postgres \
  --from-literal=username=edk \
  --from-literal=password=<password>
```

Point the chart at your database host, port, and name through `database.host`, `database.port`, and `database.name`.

## 3. Pick a values overlay

The `examples/` directory holds ready-to-copy overlays. Start from one and adjust:

| File | Purpose |
| --- | --- |
| `shared-postgres-values.yaml` | In-cluster Postgres, JWT auth wired to the tenant AS |
| `external-managed-postgres-values.yaml` | Managed external Postgres with an egress NetworkPolicy |
| `public-protocol-internal-kms-values.yaml` | Public protocol ingress per service, KMS kept internal |
| `service-jwt-auth-values.yaml` | Require JWT on each service's admin REST |
| `secret-backed-credentials-values.yaml` | Pull signing and provider credentials from Secrets |
| `admin-console-values.yaml` | Enable the optional admin console and its `/admin-console` route on the platform host |
| `gateway-cilium-values.yaml` | Single-port multi-tenant front door via Cilium Gateway API |
| `gateway-aws-alb-values.yaml`, `gateway-gke-values.yaml`, `gateway-azure-agic-values.yaml` | Cloud gateway variants |
| `mesh-mtls-values.yaml` | Service-mesh mTLS for inter-service traffic |
| `opentelemetry-values.yaml` | OTLP exporter wiring |

Set `global.platformBaseDomain` to the customer-controlled base domain for the installation. The platform host is `platform.<base-domain>` and tenant hosts are `<tenant-slug>.<base-domain>`. If you use classic per-service ingress, also set the per-service ingress hosts. If you use the single-port Gateway API model, point DNS for `platform.<base-domain>` and `*.<base-domain>` at the gateway address.

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

Two front-door models are available.

**Per-service ingress (default).** Each service renders a public and an internal Ingress. Public ingress carries only protocol and resolver paths. Internal ingress carries the administrative REST paths and must be protected by JWT or mesh policy. The tenant KMS has no public ingress. The platform service exposes only the authorization server metadata and auth paths publicly; `/api/platform/*` stays internal.

**Single-port Gateway API.** Set `gateway.enabled: true` and `ingress.legacy.enabled: false` to front all traffic with one HTTPS listener. HTTPRoutes fan out by host and path to each service. The operator host is `{gateway.operatorHost}.{baseDomain}` (default `platform.<baseDomain>`), and each tenant is reached at `<slug>.<baseDomain>`. Provide wildcard TLS material with `gateway.tls.mode: secret` and an existing Secret, or `gateway.tls.mode: certManager` with a cert-manager ClusterIssuer. For Let's Encrypt wildcard certificates, configure the ClusterIssuer for DNS-01, not HTTP-01. Individual certificates per host are possible, but onboarding automation must provision them before tenant hosts go live. The cloud gateway example overlays cover AWS ALB, GKE, Azure AGIC, and Cilium.

Whichever model you choose, the public surface is limited to the DID resolver, OAuth/OIDC, the OID4VCI issuer paths, and the OID4VP verifier paths. Keep every `/api/.../v1` path internal and JWT- or mesh-protected.

**Admin console.** The optional `services.admin-console` service (image, `enabled`, `replicas`, `restPort: 3000`) renders the Next.js operator console behind the `/admin-console` route on the platform host. After first-run setup activates the license and creates the operator account, operators sign in at `https://platform.<base-domain>/admin-console`. The route is served without stripping the prefix and must take precedence over the platform catch-all. The `enableTenantConsole: false` flag gates the future per-tenant route. Enable it with `examples/admin-console-values.yaml`. See [tls-and-gateway.md](tls-and-gateway.md) for the routing details.

## 6. Security defaults

The chart runs every service as non-root UID/GID `10001` with a read-only root filesystem, dropped Linux capabilities, the runtime default seccomp profile, REST auth enabled, JWT auth wiring enabled, and NetworkPolicies enabled. For production, set non-empty `auth.jwt.issuer`, `auth.jwt.jwksUri`, and `auth.jwt.audience`. The example overlays point the JWT issuer and JWKS URI at the tenant AS.

## 7. Onboard the first tenant

With the release running, onboard a tenant either with the `scripts/provision` helper or by importing the Postman collection and running it step by step. See [onboarding.md](onboarding.md).
