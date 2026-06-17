# TLS and the single-port gateway

The deployment is multi-tenant by subdomain. Every installation has one base
domain, the platform lives at `platform.<base-domain>`, and each tenant lives at
`<tenant-slug>.<base-domain>`. For example, with `example.com` as the base
domain, the platform is `platform.example.com` and tenant `acme` is
`acme.example.com`.

The front door terminates TLS for the platform host and every tenant host on a
single port, then routes by host and path to each service. Tenant resolution
reads the inbound Host header, so that header is part of the application
contract.

![EDK single-port gateway routing](assets/gateway-routing.svg)

Use a wildcard certificate for `*.<base-domain>` plus
`platform.<base-domain>`, or individual certificates for the operator host and
every tenant host. The wildcard model is recommended because new tenants are
hosted as `<tenant-slug>.<base-domain>` and otherwise require certificate
automation before they can go live.

This page covers the single-port front door in both Docker and Kubernetes, and
the public versus internal split. For the configuration inputs (base domain and
per-service hosts), see [configuration.md](configuration.md).

## Host preservation

Tenant resolution reads the raw inbound Host header. The front door must forward
the original public Host unchanged to the backend. A gateway, ingress
controller, CDN, or load balancer that rewrites Host to the backend pool or
service name makes every request resolve to the wrong tenant or to none, and
tenant routing breaks. Verify with a request to a tenant host that the backend
sees the original Host, not a pod or service name.

## Public versus internal split

Public exposure is limited to the protocol and resolver surfaces:

- DID resolver paths on the DID service.
- OAuth/OIDC discovery and protocol paths on the platform and tenant-AS.
- OID4VCI issuer paths on the issuer service.
- OID4VP verifier paths on the verifier service.
- The optional admin console at `/admin-console` on the platform host only.

Administrative REST under `/api/.../v1` is not anonymous public traffic. In
Kubernetes the chart enforces a public/internal split: internal administrative
paths are rendered on internal ingress and KMS is not published publicly by
default. `helm/edk-enterprise/examples/public-protocol-internal-kms-values.yaml`
shows the split with separate public and internal hosts per service and KMS
ingress disabled. In Docker, the gateway overlay routes only the paths it lists;
do not publish the KMS host port, and protect any management route you expose
with JWT and network policy.

## Docker single-port gateway

The Compose stack ships a gateway overlay at `compose/docker-compose.gateway.yml` that puts a Traefik reverse proxy in front of the services. Bring the base stack and the overlay up together:

```bash
docker compose -f docker-compose.yml -f docker-compose.gateway.yml up -d
```

Traefik terminates TLS on `443`, redirects `80` to `443`, and fans out to the services by host and path with `passHostHeader: true`, so the inbound Host reaches the backend unchanged. The static configuration is in `compose/gateway/traefik/traefik.yml` and the routing table is in `compose/gateway/traefik/dynamic.yml`.

### Local evaluation certificate

For local evaluation, generate a wildcard certificate with the kit script:

```bash
scripts/gen-local-wildcard-cert.sh
```

On Windows use `scripts\gen-local-wildcard-cert.ps1`. The script writes to `compose/gateway/certs/`:

- `wildcard.crt` and `wildcard.key`. The server certificate for `*.saas.localtest.me` (the default base domain) and the operator host, mounted into Traefik.
- `local-ca.crt`. The local CA. Trust it in your operating system, browser, and wallet to avoid certificate warnings.
- `local-truststore.p12`. A JVM truststore holding the CA (password `changeit`), mounted into the containers so they trust the gateway when fetching per-tenant JWKS over TLS.

The script uses `mkcert` when available (run `mkcert -install` once so your browser trusts the CA) and otherwise falls back to a self-signed openssl CA you trust manually. Override the base domain with `EDK_PLATFORM_BASE_DOMAIN` and the truststore password with `EDK_TRUSTSTORE_PASSWORD`. Re-run any time; it overwrites the cert material.

The local default base domain is `saas.localtest.me`, whose subdomains resolve
to `127.0.0.1` with no DNS setup, so
`https://platform.saas.localtest.me` and
`https://<tenant>.saas.localtest.me` reach the gateway on your machine.

### A real base domain in production

For a real base domain, supply publicly trusted certificate material instead of
the local-evaluation material. The recommended form is a wildcard certificate
for `*.<your-base>` plus `platform.<your-base>`. The certificate can come from
Let's Encrypt or any other public CA; with Let's Encrypt, use DNS-01 validation
for wildcard issuance. Place the certificate and key in
`compose/gateway/certs/` as `wildcard.crt` and `wildcard.key`, and remove the
local-evaluation truststore mounts from the overlay, since a publicly trusted
certificate is validated against the default JVM truststore. If you use
individual certificates instead, update the Traefik TLS configuration to load
the certificate for every tenant host and the platform host before exposing
those hosts.

The Traefik routing table reads the base domain literally; its file provider does not interpolate environment variables. Set `EDK_PLATFORM_BASE_DOMAIN` to your domain and replace `saas.localtest.me` throughout `compose/gateway/traefik/dynamic.yml` with your base domain so the host rules match. Point public DNS for `platform.<base-domain>` and `*.<base-domain>` at the machine that runs the gateway.

### Let's Encrypt gateway for public evaluation

The Docker kit also includes a Let's Encrypt gateway renderer for public
evaluation on a real base domain. Use this when `platform.<base-domain>` and
`*.<base-domain>` resolve to the machine running Docker and inbound TCP `443`
reaches that machine.

Render the overlay on Windows:

```powershell
.\scripts\start-letsencrypt.ps1 `
  -BaseDomain edk.example.com `
  -Email admin@example.com `
  -Challenge tls-alpn `
  -Staging
```

Render it on Linux or macOS:

```bash
scripts/start-letsencrypt.sh \
  --base-domain edk.example.com \
  --email admin@example.com \
  --challenge tls-alpn \
  --staging
```

The script writes these generated files:

- `compose/docker-compose.letsencrypt.yml`
- `compose/gateway/traefik/traefik.letsencrypt.generated.yml`
- `compose/gateway/traefik/dynamic.letsencrypt.generated.yml`

Start the stack with the generated overlay:

```bash
cd compose
docker compose -f docker-compose.yml -f docker-compose.letsencrypt.yml up -d --wait
```

Run once with `-Staging` / `--staging` first to validate DNS and routing without
using Let's Encrypt production rate limits. After the staging run works, render
again without staging and restart the stack so Traefik obtains production
certificates.

`tls-alpn` validation is the simplest mode and only requires inbound TCP `443`.
It can issue only concrete DNS names, not `*.<base-domain>`. The renderer requests
one certificate for `platform.<base-domain>` plus the comma-separated tenant
aliases passed through `-TenantAliases` / `--tenant-aliases` (`acme,globex,initech`
by default). Add every tenant hostname you want covered before starting Traefik,
or rerender and restart before exposing a new tenant host. For an actual wildcard
certificate that covers arbitrary future tenants, use DNS-01. Cloudflare example:

```powershell
$env:CF_DNS_API_TOKEN = "<token>"
.\scripts\start-letsencrypt.ps1 `
  -BaseDomain edk.example.com `
  -Email admin@example.com `
  -Challenge dns `
  -DnsProvider cloudflare `
  -Staging
```

The Let's Encrypt overlay replaces `docker-compose.gateway.yml`; do not combine
both gateway overlays. Because the certificate is publicly trusted, this overlay
does not mount `compose/gateway/certs` into the containers and does not set a JVM
truststore override.

## Kubernetes single-port gateway

In Kubernetes the single-port front door uses the Gateway API. One wildcard
HTTPS listener terminates TLS for the operator host and all tenant hosts;
HTTPRoutes fan out by host and path. When you adopt the gateway, disable the
classic per-service Ingress objects so the gateway is the only public entry
point. The ready-to-copy examples live under `helm/edk-enterprise/examples/`.

Common gateway settings under `gateway`:

| Key | Purpose |
| --- | --- |
| `gateway.enabled` | Render the Gateway and HTTPRoutes. |
| `gateway.className` | GatewayClass to bind to (cilium, a GKE class, an AWS Gateway API class). |
| `gateway.operatorHost` | Operator host label; the operator plane is `<operatorHost>.<baseDomain>`. |
| `gateway.baseDomain` | Wildcard base domain. Defaults to `global.platformBaseDomain`. |
| `gateway.tls.mode` | `secret` to reference an existing wildcard TLS Secret, or `certManager` to provision the wildcard through a cert-manager ClusterIssuer. Use DNS-01 for Let's Encrypt wildcard certificates. |
| `gateway.tls.secretName` | Wildcard TLS Secret name when `mode` is `secret`. |
| `gateway.tls.clusterIssuer` | ClusterIssuer name when `mode` is `certManager`. |
| `gateway.httpRedirect` | Add a port 80 listener and a redirect route that 301s to HTTPS. |

### Cilium Gateway API

```yaml
gateway:
  enabled: true
  className: cilium
  operatorHost: platform
  baseDomain: example.com
  tls:
    mode: secret
    secretName: edk-wildcard-tls
  httpRedirect: true

ingress:
  legacy:
    enabled: false
```

See `helm/edk-enterprise/examples/gateway-cilium-values.yaml`.

### GKE Gateway API

GKE Gateway preserves the inbound Host and sets `X-Forwarded-Proto` by default. For the wildcard certificate you either reference a pre-created Kubernetes TLS Secret (`tls.mode: secret`) or provision a Google-managed certificate for `*.<base-domain>` using DNS authorization and bind it to the Gateway with a `networking.gke.io/certmap` annotation.

```yaml
gateway:
  enabled: true
  className: gke-l7-global-external-managed
  operatorHost: platform
  baseDomain: example.com
  tls:
    mode: secret
    secretName: edk-wildcard-tls
  httpRedirect: true

ingress:
  legacy:
    enabled: false
```

See `helm/edk-enterprise/examples/gateway-gke-values.yaml`.

### AWS

Two options exist. With the AWS Gateway API controller, set `gateway.enabled` true and `gateway.className` to the published GatewayClass, exactly as the Cilium and GKE examples. The common path uses classic Ingress with the AWS Load Balancer Controller (ALB): one internet-facing ALB terminates TLS on 443 with a single ACM wildcard certificate and routes by host and path. The ALB controller groups Ingress objects that share a group name onto one load balancer, so all public hosts land on one ALB and one port.

```yaml
gateway:
  enabled: false

ingress:
  legacy:
    enabled: true
  public:
    annotations:
      alb.ingress.kubernetes.io/scheme: internet-facing
      alb.ingress.kubernetes.io/target-type: ip
      alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
      alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:us-east-1:123456789012:certificate/REPLACE-WITH-WILDCARD-CERT
      alb.ingress.kubernetes.io/ssl-redirect: "443"
      alb.ingress.kubernetes.io/group.name: edk-enterprise
```

Use one ACM wildcard certificate for `*.<base-domain>`; it covers the operator host and every tenant host. See `helm/edk-enterprise/examples/gateway-aws-alb-values.yaml` for the per-service host entries.

### Azure

The Application Gateway Ingress Controller (AGIC) terminates TLS on 443 and routes by host and path. AGIC rewrites the Host header to the backend pool address by default, which breaks tenant resolution. Preserve the original public Host on every route: set `appgw.ingress.kubernetes.io/backend-hostname` per service to the public host, or disable host override on the Application Gateway HTTP setting so the inbound Host passes through unchanged.

Supply the wildcard certificate to the Application Gateway either from Azure Key Vault (`appgw.ingress.kubernetes.io/appgw-ssl-certificate` referencing a pre-uploaded cert) or from a Kubernetes TLS Secret in the Ingress tls block.

See `helm/edk-enterprise/examples/gateway-azure-agic-values.yaml` for the full per-service `backend-hostname` annotations.

### Classic per-service ingress

When you do not use the single-port gateway, keep `ingress.legacy.enabled: true` (the chart default). The chart renders a public Ingress for the protocol and resolver paths and an internal Ingress for the admin paths, per service. Set TLS, redirect, and certificate annotations under `ingress.public.annotations` and `ingress.internal.annotations`, and the per-service hosts under `services.<name>.publicIngress.host` and `services.<name>.internalIngress.host`. `helm/edk-enterprise/examples/public-protocol-internal-kms-values.yaml` shows this with cert-manager issuing the public certificates.

## Admin console routing

The optional admin console is a Next.js app served under the `/admin-console`
path prefix on the platform host. The gateway routes
`https://platform.<base-domain>/admin-console` to the `admin-console` container
on port `3000`. The console owns the prefix and emits its assets under
`/admin-console/_next/...`, so the route is served **without** a StripPrefix:
forward the full path including `/admin-console` to the backend. Stripping the
prefix breaks asset loading.

The `/admin-console` route must take precedence over the platform catch-all so
that `/admin-console` requests reach the console and not the platform service.
Give the console route higher priority than the platform host route.

**Traefik (Compose).** The gateway overlay routes the `/admin-console` prefix on
the platform host to the `admin-console` service. The router matches
`Host(platform.<base-domain>) && PathPrefix(/admin-console)` with no StripPrefix
middleware, and is given a higher priority than the platform catch-all router so
the more specific path wins. The routing table lives in
`compose/gateway/traefik/dynamic.yml`.

**Kubernetes Gateway API / Ingress.** With the Gateway API, an HTTPRoute on the
platform host matches the `/admin-console` path prefix and forwards to the
admin-console Service on port `3000`, with no URLRewrite/path filter that strips
the prefix. Gateway API longest-prefix matching makes the `/admin-console` route
win over the platform host's `/` route. With classic Ingress, add an
`/admin-console` prefix path on the platform public Ingress ahead of the
catch-all, again without a rewrite annotation that strips the prefix.

### Future per-tenant console (not enabled)

The per-tenant console at `https://<tenant>.<base-domain>/admin-console` is a
future capability and is not enabled. Do **not** add a `/admin-console` route on
tenant hosts until a per-tenant API authorization proxy enforces tenant
isolation. The gateway only routes by host and path; it does not prevent a
tenant principal from reaching platform-admin APIs or another tenant's data.
Until that proxy exists, exposing the console on tenant hosts is a
tenant-isolation breach. The Helm `enableTenantConsole: false` flag keeps the
tenant route off.
