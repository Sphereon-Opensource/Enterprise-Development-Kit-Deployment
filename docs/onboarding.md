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
The supplied file is a post-setup environment. It contains `baseDomain`,
`tenantSlug`, `tenantName`, `operatorEmail`, `operatorPassword`,
`tenantOwnerPassword`, `tenantOwnerCodeVerifier`, `tenantServiceClientId`, and
`tenantServiceClientSecret`.
These are Postman/provision variables, not Docker Compose or Helm startup
variables.
The operator OAuth callback is derived from the platform URL and the hosted
session during sign-in; do not add or fill any separate callback variable.
The collection derives the platform origin, tenant gateway origin, protocol API
roots, issuer/verifier display URLs, resource identifiers, and tenant-scoped
`did:web` values from onboarding responses. Do not add a DID hostname or
service-container URL to the environment. The optional VICAL source remains a
collection-local HTTPS value because it belongs to the customer's published
trust infrastructure; override that value only when using a real VICAL URL.

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

The supplied collection starts after platform setup. Run its 304 requests in
folder order:

| Folder | What it does |
| --- | --- |
| `00 Before You Start` | Checks the imported environment and gateway contract before authenticated requests |
| `01 Operator Sign-in` | Obtains the operator token with the client_credentials grant of the confidential operator client that the setup script registered |
| `02 Tenant Onboarding` | Registers the tenant, waits for onboarding completion, enables the tenant-owned Developer Console with its response-derived revision, verifies tenant public endpoint bindings, and registers the tenant service client on the tenant authorization server |
| `03 Subtenants` | Registers a two-level tenant hierarchy, lists the children at both levels, reconciles registration rows, and gives the deepest subtenant its own service client, issuer and issued credential |
| `04 Tenant Federation` through `11 Credential Designs` | Configure tenant federation, the disposable SOFTWARE KMS create/write/validate/rotate/detach/retire lifecycle, DID, issuer settings and credential designs |
| `12 Status Lists` | The JWT list, then nested `01 CWT mdoc` for the CWT-signed mdoc list, `02 Bitstring VCDM` for the two-bit bitstring list with revocation and suspension, and `03 Shared list` for one list shared by two credential configurations and two issuer instances |
| `13 Hosted Branding Verification` through `15 OID4VCI Pre-authorized Transaction Code` | Hosted branding, SD-JWT and mdoc issuance, and the pre-authorized transaction-code flow |
| `16 VCDM 1.1` and `17 VCDM 2.0` | Issue W3C VC-JWT credentials in both VCDM versions and check the `BitstringStatusListEntry` status entry each one carries |
| `18 Issue Credentials Pipeline` through `21 Authorization Code Offer` | Pipeline issuance, DCQL, verification and the authorization-code offer examples |
| `22 Trust Domains` | Creates and verifies tenant trust-domain configuration and the VICAL/trust-list integration surface |

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
