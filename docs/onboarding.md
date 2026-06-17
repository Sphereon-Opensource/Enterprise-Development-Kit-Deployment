# Onboarding the first tenant

After the stack is up (Docker Compose or Kubernetes), onboard your first tenant.
A tenant is a self-contained issuer and verifier with its own public endpoints
for the issuer, verifier, authorization server, and DID document. In the
single-port gateway model, the tenant is reached at
`<tenant-slug>.<base-domain>`, while the platform/operator plane is reached at
`platform.<base-domain>`.

The stack must be running the published enterprise images from the private Nexus Docker repository `nexus.sphereon.com/edk-docker`. Kubernetes deployments install the `edk-enterprise` chart from Sphereon's private Nexus Helm repository `https://nexus.sphereon.com/repository/edk-helm`; the enterprise images are private Nexus artifacts only.

There are two ways to do it:

- The `scripts/provision` helper, which calls the REST APIs directly and drives the whole flow.
- The Postman collection, which walks the same flow request by request so you see every step.

Both read their configuration from the same Postman customer environment file under `postman/`.

## Before you start

You need:

- A running EDK enterprise deployment reachable at `https://platform.<base-domain>` and `https://<tenant-slug>.<base-domain>`.
- A Sphereon license token.
- Operator account details for the platform. First-run setup creates this account after license activation.
- Node.js on your PATH. The provision script uses it to read the environment JSON and to compute the PKCE code challenge.

## Configuration

Both onboarding paths read `postman/EDK-Enterprise-Deployment.customer.postman_environment.json`. The file ships with the customer-facing inputs only. Replace each placeholder with your deployment's values:

| Variable | What to set it to |
| --- | --- |
| `baseDomain` | The customer-controlled base domain. The platform is `https://platform.<baseDomain>` and the tenant is `https://<tenantSlug>.<baseDomain>` |
| `tenantSlug` | The first tenant slug. The default is `acme` |
| `tenantName` | The first tenant display name |
| `licenseToken` | Your Sphereon license token. Setup installs it |
| `operatorEmail`, `operatorPassword` | The operator account credentials. Setup bootstraps the account after license activation; sign-in authenticates with it |

The Postman collection derives `platformUrl`, `issuerUrl`, `verifierUrl`, `asUrl`, `kmsUrl`, `didUrl`, `operatorRedirectUri`, and the public endpoint hosts from those inputs. The provision scripts do the same, while still accepting explicit URL variables for non-standard deployments.

## Option A: the provision script

The provision script runs against the already-running deployment and onboards the platform and the first tenant by calling the published REST APIs. It performs, in order:

1. Waits for the platform service to report healthy at `https://platform.<base-domain>/health`.
2. Runs platform setup only if the setup gate is still open: it installs the license token, then bootstraps the operator account as the final gate-closing setup step. If the gate is already closed, this step is skipped, so the script is safe to re-run.
3. Signs the operator in through the platform authorization-code flow with PKCE, carrying cookies and the login form CSRF tuple like a browser, and exchanges the authorization code for an operator access token.
4. Registers the first production tenant. Tenant registration provisions the tenant runtime surfaces for issuer, verifier, authorization server, KMS, and DID routing.
5. Binds the tenant's three public endpoints: the OID4VCI issuer, the OID4VP verifier, and the OAuth2 authorization server.
6. Prints a summary with the operator console URL (`https://platform.<base-domain>/admin-console`) and the tenant's public metadata URLs.

Windows:

```powershell
.\scripts\provision.ps1
```

Linux or macOS:

```bash
./scripts/provision.sh
```

### Flags

| Windows | Linux/macOS | Effect |
| --- | --- | --- |
| `-EnvFile <path>` | `--env-file <path>` | Use a different Postman customer environment file. Defaults to the one under `postman/` |
| `-TenantName <name>` | `--tenant-name <name>` | Override the tenant display name from the environment file |
| `-TenantSlug <slug>` | `--tenant-slug <slug>` | Override the tenant slug from the environment file |
| `-SkipSetup` | `--skip-setup` | Skip platform setup when the platform is already initialized |

Examples:

```powershell
.\scripts\provision.ps1 -TenantName "Acme Corporation" -TenantSlug acme
.\scripts\provision.ps1 -SkipSetup
```

```bash
./scripts/provision.sh --tenant-name "Acme Corporation" --tenant-slug acme
./scripts/provision.sh --skip-setup
```

When the run finishes, the script prints the operator console URL, the tenant id, and the tenant's issuer metadata, AS metadata, and `did.json` URLs so you can confirm the tenant is live. Use the operator account created during setup to sign in at `https://platform.<base-domain>/admin-console`.

## Option B: the Postman collection

The Postman collection walks the same onboarding flow request by request, plus the later issuance and verification steps, so you can run and inspect each call. Import these two files into Postman:

- `postman/EDK-Enterprise-Deployment.postman_collection.json` (the requests)
- `postman/EDK-Enterprise-Deployment.customer.postman_environment.json` (the variables you fill in)

Select the imported environment, fill in the variables above, then run the folders in order. The collection derives all public service URLs from `baseDomain` and `tenantSlug`, then passes values from one request to the next through collection variables, so run within a folder top to bottom.

The folders, in order:

| Folder | What it does |
| --- | --- |
| `01 Platform Onboarding` | Generates the license request, verifies and installs your license token, then bootstraps the operator account and closes the setup gate |
| `02 Operator Sign-in` | Signs in as the operator and exchanges the authorization code for an operator token |
| `03 Tenant Onboarding` | Registers the tenant and binds its issuer, verifier, and authorization server public endpoints at `<tenantSlug>.<baseDomain>` |
| `04 Tenant Federation` | Registers a federation IdP for the tenant |
| `05 Tenant Service Token` | Obtains a service token for tenant-scoped admin calls |
| `06 Tenant Keys and DID` | Generates assertion and authentication keys and creates the tenant `did:web` identifier |
| `07 Issuer Settings` | Creates the issuer design used by credential offers |
| `08 Credential Designs` | Creates the sample EuPid and Mdl credential designs |
| `09 Status Lists` | Creates a status list and exercises revoke and reactivate |
| `10 Hosted Branding Verification` | Checks public metadata and hosted branding assets |
| `11 Issue Credentials Simple` | Issues credentials with subject data supplied directly in the offer |
| `12 Issue Credentials Pipeline` | Issues credentials through the attribute pipeline flow |
| `13 DCQL Queries` | Creates verifier DCQL query definitions |
| `14 Verification` | Creates and manages a verification session |
| `15 Authorization Code Offer` | Creates an offer with the authorization code grant |

Run at least `01`, `02`, and `03` to bring a tenant online. The later folders configure and exercise issuance and verification for that tenant.

## After onboarding

Each tenant is reachable at its own host, normally
`https://<tenant-slug>.<base-domain>` in the single-port gateway model. For the
default hosted issuer, the OID4VCI `credential_issuer` identifier is that tenant
origin, not the platform host. Confirm the tenant is live by fetching:

- `https://<tenant-host>/.well-known/openid-credential-issuer` (issuer metadata)
- `https://<tenant-host>/.well-known/oauth-authorization-server` (AS metadata)
- `https://<tenant-host>/.well-known/did.json` (the tenant DID document)

These public endpoints are the issuer, AS, and DID resolver surfaces. The operator UI is `https://platform.<base-domain>/admin-console`. The tenant's administrative REST paths stay internal or controlled by gateway policy and require the operator or tenant service token.
