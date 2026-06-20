# Sphereon EDK Enterprise Deployment Kit

This kit deploys the Sphereon EDK enterprise platform from published container images. It contains the Helm chart, a Docker Compose stack, onboarding scripts, gateway TLS helpers, and a Postman collection that bring up the enterprise services and onboard your first tenant.

You run published images only. The kit does not build anything. Customer deployments use the public Enterprise Development Kit Deployment repository: <https://github.com/Sphereon-Opensource/Enterprise-Development-Kit-Deployment>.

## What you deploy

The service containers are:

| Image | Role | Public ingress |
| --- | --- | --- |
| `nexus.sphereon.com/edk-docker/enterprise-platform` | Central control plane: first-run setup, license activation, platform admin, platform configuration, and platform authorization server | Operator host `platform.<base-domain>`; setup/admin APIs must be protected after first run |
| `nexus.sphereon.com/edk-docker/enterprise-tenant-kms` | Key management for all services | None. KMS is never exposed publicly |
| `nexus.sphereon.com/edk-docker/enterprise-did` | DID resolver and `did:web` hosting | Resolver and `did.json` paths only; admin API is internal |
| `nexus.sphereon.com/edk-docker/enterprise-tenant-as` | Tenant OAuth2 authorization server | OAuth/OIDC protocol paths only |
| `nexus.sphereon.com/edk-docker/enterprise-issuer` | OID4VCI credential issuer | Issuer metadata and protocol paths only; admin API is internal |
| `nexus.sphereon.com/edk-docker/enterprise-verifier` | OID4VP credential verifier | Verifier protocol paths only; admin API is internal |

The platform and tenant-KMS containers also run internal gRPC receivers. DID, tenant-AS, issuer, verifier, and tenant-KMS call the platform service over internal gRPC for platform configuration and control-plane data. DID, tenant-AS, issuer, and verifier call tenant-KMS over internal gRPC for KMS operations. gRPC is east-west only and must never be routed through the public gateway.

The public surface is limited to the platform operator host, DID resolver, OAuth/OIDC endpoints, OID4VCI issuer paths, OID4VP verifier paths, and the admin console at `/admin-console` on the platform host. In Kubernetes, KMS is internal-only by default. In Docker Compose, keep KMS on the private compose network unless you intentionally expose a tenant-management route for controlled evaluation. Every administrative REST path (`/api/.../v1`) is internal or operator-authenticated and must be protected by JWT or service-mesh policy before you expose the deployment.

One optional container completes the platform:

| Image | Role | Public ingress |
| --- | --- | --- |
| `${EDK_REGISTRY:-nexus.sphereon.com/edk-docker}/admin-console` | Next.js operator admin console served under `/admin-console` | `/admin-console` on the platform host only |

The admin console is a separate Next.js app built and published by Sphereon, not from this kit. The gateway routes `https://platform.<base-domain>/admin-console` to it. After first-run setup activates the license and creates the operator account, operators sign in there with that account. The per-tenant console (`https://<tenant>.<base-domain>/admin-console`) is a future capability and is not enabled. Do not enable it until a per-tenant API authorization proxy enforces tenant isolation: the gateway only routes, it does not stop a tenant principal from reaching platform-admin APIs or another tenant's data.

## Domain and TLS model

Every EDK installation is anchored on one customer-controlled base domain. The platform is a subdomain of that base domain, and tenants are sibling subdomains:

- Base domain: `example.com`
- Platform/operator host: `platform.example.com`
- Tenant hosts: `<tenant-slug>.example.com`, for example `acme.example.com`

The platform and tenants are not separate DNS zones in the application model. They are subdomains under the same base domain, and tenant resolution depends on the inbound `Host` header. Your gateway, ingress controller, CDN, or load balancer must forward the original public Host header unchanged.

![EDK base domain and subdomain model](docs/assets/base-domain-model.svg)

Terminate TLS at the public gateway or load balancer with a certificate that covers the platform host and all first-level tenant hosts. The recommended operational model is a wildcard certificate for `*.<base-domain>` plus the platform host. A public CA such as Let's Encrypt is fine; in Kubernetes, issue it with cert-manager DNS-01 or import an existing wildcard certificate as a TLS Secret. A wildcard for `*.example.com` covers `platform.example.com` and `acme.example.com`, but it does not cover the apex `example.com` or nested names such as `api.acme.example.com`.

## Prerequisites

- A Nexus pull secret for the private `nexus.sphereon.com/edk-docker` enterprise image repository. Sphereon provides the credentials.
- A Sphereon protected license bundle ZIP, or access to your evaluation license issuer. The setup UI generates the license recipient key when it creates the license request and includes only its public key in that request. You import the protected bundle during platform setup, and setup must also create the first operator account. Evaluation bundles can include the test root CA material when needed.
- TLS material for the operator and tenant hosts. Use a wildcard certificate for `*.<base-domain>` plus `platform.<base-domain>`, or individual certificates for every tenant host and the operator host. The wildcard model is recommended because tenants are hosted as `<tenant>.<base-domain>` and can be onboarded without per-tenant certificate work.
- A PostgreSQL database. The Docker Compose stack starts a local Postgres container for evaluation. For Kubernetes or production-style deployments, use a managed, operator-managed, or separately run database and point the deployment at it with a credentials Secret or connection settings.

## Choose your path

### Docker Compose (evaluation, single node)

Use the stack under `compose/` to run the services on one machine. Run it two ways:

- The base file `compose/docker-compose.yml` alone publishes each service on its own loopback host port over plain HTTP. Its external URL defaults are `http://localhost:<port>` and are only for local evaluation.
- The base file plus the gateway overlay `compose/docker-compose.gateway.yml` puts a Traefik reverse proxy in front of the services on a single TLS port and routes by host and path. The operator plane is `https://platform.<base-domain>`; tenant protocol URLs are bound during onboarding as `https://<tenant-slug>.<base-domain>`. For local evaluation, first generate a wildcard certificate with `scripts/gen-local-wildcard-cert.ps1` (Windows) or `scripts/gen-local-wildcard-cert.sh` (Linux/macOS), then trust the local CA.

Follow [docs/quickstart-docker.md](docs/quickstart-docker.md).

### Kubernetes (production)

Use the Helm chart under `helm/edk-enterprise/` for production. The chart renders deployments, services, ingress (or a single-port Gateway API front door), NetworkPolicies, and security defaults for the platform, runtime services, and admin console. The gateway examples under `helm/edk-enterprise/examples/` cover Cilium, GKE, AWS ALB, and Azure AGIC.

Follow [docs/quickstart-kubernetes.md](docs/quickstart-kubernetes.md).

## Onboard your first tenant

Once the stack is up, complete first-run setup and onboard a tenant either with the `scripts/provision.ps1` (Windows) or `scripts/provision.sh` (Linux/macOS) helper, which calls the REST APIs directly, or by importing the Postman collection and running it request by request. Both read the same Postman customer environment file under `postman/`. After the first run activates the license and creates the operator account, sign in at `https://platform.<base-domain>/admin-console`.

Follow [docs/onboarding.md](docs/onboarding.md).

## Repository map

```
Enterprise-Development-Kit-Deployment/
  README.md                       This file
  docs/
    quickstart-docker.md          Bring the stack up with Docker Compose
    quickstart-kubernetes.md      Install the Helm chart on Kubernetes
    onboarding.md                 Onboard the first tenant (provision script and Postman)
    tls-and-gateway.md            Single-port TLS, gateway, and ingress options
    configuration.md              Configuration inputs and external base URLs
    secret-backends.md            Secret backend selection
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
    provision.ps1                 Onboard the platform and first tenant over REST (Windows)
    provision.sh                  Onboard the platform and first tenant over REST (Linux/macOS)
    gen-local-wildcard-cert.ps1   Local-evaluation wildcard TLS cert for the gateway (Windows)
    gen-local-wildcard-cert.sh    Local-evaluation wildcard TLS cert for the gateway (Linux/macOS)
  postman/
    EDK-Enterprise-Deployment.postman_collection.json
    EDK-Enterprise-Deployment.customer.postman_environment.json
```
