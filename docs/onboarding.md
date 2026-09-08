# First-run setup and tenant onboarding

After the platform control plane is up (Docker Compose or Kubernetes), complete
first-run setup and then create tenants from the operator admin surface.

The platform/operator plane is reached at `https://platform.<base-domain>`.
Tenants are sibling hosts under the same customer-controlled base domain, such
as `https://<tenant-slug>.<base-domain>`. The tenant slug is chosen during
tenant creation, not before the stack starts. Tenant registration creates the
authorization server, issuer, verifier, DID, KMS material, and public endpoint
bindings for that tenant host.

The stack must be running the published enterprise images, for example
`nexus.sphereon.com/edk-docker/enterprise-platform:0.25.0-SNAPSHOT` and the
matching `nexus.sphereon.com/edk-docker/enterprise-*` workload images.
Kubernetes deployments install the `edk-enterprise` chart from the deployment
repository or your packaged chart repository.

## Primary customer flow

Use this flow for normal customer installations:

1. Start the full platform and workload stack.
2. Open the setup UI at `https://platform.<base-domain>/setup-license`, or open
   `https://platform.<base-domain>/admin-console` and follow the setup redirect.
3. Generate the license request. The platform creates the local license
   recipient key and returns the public license request payload.
4. Send that license request to the license issuer provided through your EDK distribution channel.
5. Import the protected license bundle ZIP returned by the license issuer.
6. Bootstrap the first platform operator account. This closes the anonymous
   setup gate.
7. Sign in at `https://platform.<base-domain>/admin-console`.
8. Create the first tenant from the admin console or the platform admin REST
   API. Choose the tenant slug at this step.

Do not configure the operator email, license installation id, deployment id, or
tenant slug in Docker Compose or Helm just to start the system. The setup UI/API
collects license and operator inputs during first-run setup. Tenant creation
collects tenant inputs after the operator is authenticated.

## Setup API

The setup UI uses the public setup API on the platform host. Customers can use
the same API directly when automating the setup flow.

Check whether setup is still open:

```http
GET /api/platform/setup/v1/status
```

Generate the license request:

```http
POST /api/platform/setup/v1/license-request/generate
Content-Type: application/json

{
  "alias": "platform-license-request",
  "providerId": "license",
  "algorithm": "ECDSA_SHA256",
  "use": "sig",
  "deployment": {
    "deployment": {
      "baseDomains": ["<base-domain>"]
    },
    "organizationName": "<organization-name>",
    "organizationUnit": "<organization-unit>",
    "locality": "<city>",
    "country": "<ISO-3166-alpha-2-country>",
    "licenseDeliveryMethod": "MANUAL",
    "contacts": [
      {
        "email": "<technical-contact-email>",
        "givenName": "<given-name>",
        "familyName": "<family-name>",
        "roles": ["TECHNICAL"]
      },
      {
        "email": "<administrator-contact-email>",
        "givenName": "<given-name>",
        "familyName": "<family-name>",
        "roles": ["ADMINISTRATOR"]
      }
    ]
  },
  "serialNumber": 1
}
```

Preview and import the protected license bundle returned by the license issuer:

```http
POST /api/platform/setup/v1/license/import/preview
Content-Type: multipart/form-data

bundle=@<protected-license-bundle.zip>
```

```http
POST /api/platform/setup/v1/license/import
Content-Type: multipart/form-data

bundle=@<protected-license-bundle.zip>
```

Bootstrap the first platform operator account:

```http
POST /api/platform/setup/v1/bootstrap
Content-Type: application/json

{
  "adminEmail": "<operator-email>",
  "adminDisplayName": "<operator-display-name>",
  "adminPassword": "<operator-password>"
}
```

After bootstrap completes, the setup gate is closed and setup endpoints are no
longer available anonymously. Sign in through the admin console with the
operator account created by the bootstrap call.

## Tenant creation API

Create tenants only after first-run setup is complete and an operator is signed
in. The admin console uses the platform admin API; automation can call it
directly with an operator access token.

```http
POST /api/platform/admin/v1/tenants
Authorization: Bearer <operator-access-token>
Content-Type: application/json

{
  "tenantType": "organization",
  "name": "<tenant-display-name>",
  "description": "<tenant-description>",
  "slug": "<tenant-slug>",
  "addIssuer": true,
  "addVerifier": true,
  "owner": {
    "type": "local",
    "email": "<tenant-owner-email>",
    "displayName": "<tenant-owner-display-name>"
  },
  "ownerDelivery": {
    "mode": "none"
  }
}
```

Tenant registration provisions the default authorization server, KMS provider
and key material, tenant DID, issuer, verifier, and public endpoint bindings for
`https://<tenant-slug>.<base-domain>`.

If registration returns `503 SERVICE_UNAVAILABLE` and mentions remote platform
configuration, `platform.config.get`, or a missing Authorization header, inspect
the tenant-AS and platform logs together. For Helm deployments, verify that
`serviceIdentity.internalClientExistingSecret` references a Secret in the release
namespace and that it contains the distinct `serviceIdentity.clientSecretKeys`
entries (tenant-AS uses `tenant-as-service-client-secret`). Also verify
`keystore.existingSecret` and `keystore-password`, then restart the platform and
the satellite whose key changed after correcting or rotating Secret data. This is an east-west
service-identity failure, not an operator bearer-token failure or a reason to
recreate the tenant database.

If the internal token request instead returns `invalid_target`, trace the
effective caller client ID, then the route `serviceTokenAudience`, then that
client's `default-access-token-audience` and
`allowed-access-token-audiences`, and finally the receiver's expected audience.
The AS permits an omitted audience only with a nonblank default and permits one
explicit audience only when it is the default or an allowed additional target;
missing defaults, unregistered targets, and multiple or duplicate targets are
rejected. An explicit route audience or
`preferServiceTokenOverSessionBearer=true` is fail-closed and cannot use a
session, delegation, or anonymous fallback.

Read the onboarding status returned by registration:

```http
GET /api/platform/admin/v1/tenant-onboarding/<correlation-id>
Authorization: Bearer <operator-access-token>
```

Read the tenant and endpoint bindings:

```http
GET /api/platform/admin/v1/tenants/<tenant-id>
Authorization: Bearer <operator-access-token>
```

```http
GET /api/platform/admin/v1/tenants/<tenant-id>/public-endpoints
Authorization: Bearer <operator-access-token>
```

## Optional validation helpers

The repository also includes scripts and a Postman collection. They are not the
normal customer setup path; they are useful for validation, demos, and repeatable
API automation.

Both helpers read `postman/EDK-Enterprise-Deployment.customer.postman_environment.json`.
The supplied file is a post-setup environment with six values: `baseDomain`,
`tenantSlug`, `tenantName`, `operatorEmail`, `operatorPassword` and
`tenantOwnerPassword`. These are Postman/provision variables, not Docker Compose
or Helm startup variables.
The collection derives the platform origin, the tenant gateway origin, every
protocol API root, the tenant KMS and trust-domain API bases and the tenant-scoped
`did:web` values from `baseDomain` and `tenantSlug` before each request, and keeps
them in collection scope. Do not add a platform URL, a DID hostname or a
service-container URL to the environment; changing `baseDomain` or `tenantSlug`
is enough. The operator OAuth callback is derived from the platform URL and the
hosted session during sign-in; the PKCE verifiers and the tenant service client
secret are generated during the run and cleared afterwards. Provider-specific
values (your Azure Key Vault or AWS KMS, external keys and certificates, a
published trust list) are collection variables with `replace-with-` placeholders
next to the disabled folders that use them.

### Provision script

The all-in-one provision script drives the same REST APIs against an
already-running stack. With the supplied post-setup environment, run it with
`-SkipSetup` or `--skip-setup`: it signs the operator in, creates the tenant,
and verifies the tenant gateway endpoint bindings. To automate an installation
whose setup gate is still open, pass a separate environment file that also
defines `licenseBundleZipPath`; the script then imports that bundle and creates
the first operator before tenant onboarding.

Windows:

```powershell
.\scripts\provision.ps1
```

Linux or macOS:

```bash
./scripts/provision.sh
```

Useful flags:

| Windows | Linux/macOS | Effect |
| --- | --- | --- |
| `-EnvFile <path>` | `--env-file <path>` | Use a different Postman customer environment file |
| `-TenantName <name>` | `--tenant-name <name>` | Override the tenant display name |
| `-TenantSlug <slug>` | `--tenant-slug <slug>` | Override the tenant slug |
| `-SkipSetup` | `--skip-setup` | Skip setup when the platform is already initialized |

The script expects the workload containers or pods to be running before tenant
registration starts. It does not create endpoint bindings manually; it fails if
tenant setup did not create the required gateway route metadata. Use it to
verify that tenant setup created each protocol endpoint binding.

### Postman collection

The Postman collection walks the same flow request by request, plus later
issuance and verification examples. Import these files into Postman:

- `postman/EDK-Enterprise-Deployment.postman_collection.json`
- `postman/EDK-Enterprise-Deployment.customer.postman_environment.json`

The supplied collection starts after platform setup. Run its 214 requests in
folder order:

| Folder | What it does |
| --- | --- |
| `00 Before You Start` | Explains the six environment values, how every URL derives from them, and what each folder covers |
| `01 Operator Sign-in` | Signs the platform operator in with the authorization-code flow and PKCE and stores the operator token |
| `02 Tenant Onboarding` | Registers the tenant, waits for onboarding to complete, verifies the tenant public endpoint bindings, checks that the runtime service discovery matches the derived API bases, and resolves the issuer and verifier instance ids |
| `03 Tenant Owner Activation and Sign-in` | Activates the tenant owner through the one-time link, signs the owner in on the tenant host, and registers the confidential tenant service client |
| `04 Tenant Service Token` | Obtains the tenant service token with client_credentials |
| `05 Subtenants` | Registers a subtenant and lists the children of the parent |
| `06 Tenant Keys and DID` | Lists the KMS offerings and resources the tenant holds, validates the setup KMS, and discovers the activation-created `did:web` and its hosted `did.json` |
| `07 Bring Your Own KMS` | Registers your own Azure Key Vault or AWS KMS as a tenant KMS resource, registers references to existing external keys and certificate chains, and (for operators) the platform tenant's vault. Disabled until you fill in your provider values |
| `08 KMS Provider Sharing` | How the platform offers one of its KMSes to a tenant, how the tenant enables it and picks its default provider, and the runtime provider list that joins both planes |
| `09 Authorization Servers and Federation` | A hosted authorization server with clients and identities, an external authorization server from OIDC discovery, the federation binding that lets holders sign in there, and the issuer bindings and protocol profile |
| `10 Issuer Settings` and `11 Credential Designs` | Issuer branding and the EuPid (SD-JWT VC) and Mdl (mdoc) designs with render variants and logo assets |
| `12 Status Lists` | The did:web-signed JWT list, the x5c-signed list, revoke, reactivate and read, then the `CWT mdoc` list and the two-bit `Bitstring VCDM` list with suspension |
| `13 Credential Configurations` | How a credential configuration expresses its signing key, trust mechanism, validity, scope and status-list binding: reads of the provisioned EuPid and Mdl configurations, the VCDM 1.1 and 2.0 registrations, and binding the CWT list to Mdl |
| `14 Hosted Branding Verification` | The hosted VCT metadata, issuer well-known metadata and content-addressed assets |
| `15 Issue SD-JWT VC and mdoc` through `20 Authorization Code Issuance` | Issuance by pre-authorized code with a headless wallet, with a transaction code, of W3C VCDM 1.1 and 2.0 credentials with `BitstringStatusListEntry`, through the pipeline API, and the authorization-code offer with its authorization server metadata |
| `21 DCQL Queries` and `22 Verification` | DCQL queries and verifier bindings, then a verification request, its signed request object, status polling and cancellation |
| `23 Trust Domains and Trust Lists` | Trust domains, anchors, admissions, attachments and eligibility grants; the mdoc VICAL source; a trust list you publish (ETSI TS 119 612) and a list of trusted entities (ETSI TS 119 602) registered as sources |
| `24 KMS Runtime API` | Providers, keys, raw signatures and verification, and certificate chains and references on the tenant KMS API |
| `25 Developer Console Settings` | The tenant's Developer Console policy |

## After onboarding

Each tenant is reachable at its own host, normally
`https://<tenant-slug>.<base-domain>` in the single-port gateway model. For the
default hosted issuer, the OID4VCI `credential_issuer` identifier is that tenant
origin, not the platform host. Confirm the tenant is live by fetching:

- `https://<tenant-host>/.well-known/openid-credential-issuer`
- `https://<tenant-host>/.well-known/oauth-authorization-server`
- `https://<tenant-host>/.well-known/did.json`

These are public protocol and resolver surfaces through the gateway, not direct
container endpoints or runtime probes. The operator UI is
`https://platform.<base-domain>/admin-console`. Administrative REST paths stay
internal or controlled by gateway policy and require the operator or tenant
service token.
