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

Both read `postman/EDK-Enterprise-Deployment.customer.postman_environment.json`.
Its two essential values are `baseDomain` and `tenantSlug`: the platform is at
`https://platform.<baseDomain>` and the tenant at `https://<tenantSlug>.<baseDomain>`,
so neither the collection nor the script needs URL variables. These are client-side
variables, not Docker Compose or Helm startup variables.

The Postman collection does not need sign-in passwords: you sign in through
Postman's OAuth2 dialog. The provision script signs in by itself, so it needs
the operator credentials, which are not in the environment file.

### Provision script

The all-in-one provision script drives the same REST APIs against an
already-running stack. On an installation that is already set up, run it with
`-SkipSetup` or `--skip-setup`: it signs the operator in, creates the tenant,
and verifies the tenant gateway endpoint bindings. On an installation whose
setup gate is still open, also give it the license bundle; the script then
imports that bundle and creates the first operator before tenant onboarding.

Give the script the operator email with `-OperatorEmail` / `--operator-email`
or `EDK_OPERATOR_EMAIL`, and the license bundle with `-LicenseBundle` /
`--license-bundle` or `EDK_LICENSE_BUNDLE_ZIP_PATH`.

For the password, the first of these wins:

- `-PasswordStdin` / `--password-stdin` reads it from the first line of
  standard input. Use this in CI and other automation.
- The `EDK_OPERATOR_PASSWORD` environment variable.
- `operatorPassword` in a private copy of the environment file, passed with
  `-EnvFile` / `--env-file`. The same copy can hold `operatorEmail` and
  `licenseBundleZipPath`. Do not import it into a shared Postman workspace.
- When you run the script in a terminal, it asks for the password without
  echoing it.

There is deliberately no parameter that takes the password itself, and the
scripts never pass it on a command line, so it does not end up in shell
history or the process list.

Windows:

```powershell
.\scripts\provision.ps1 -OperatorEmail ops@example.com -SkipSetup
```

Linux or macOS:

```bash
./scripts/provision.sh --operator-email ops@example.com --skip-setup
```

In automation, pipe the password in:

```bash
printf '%s\n' "$OPERATOR_PASSWORD" | ./scripts/provision.sh --operator-email ops@example.com --password-stdin --skip-setup
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

The Postman collection covers the same flow request by request, and continues with
what developers do next. Import these files into Postman:

- `postman/EDK-Enterprise-Deployment.postman_collection.json`
- `postman/EDK-Enterprise-Deployment.customer.postman_environment.json`

It starts after platform setup and has one folder per identity:

| Folder | What it does |
| --- | --- |
| `1. Platform operator` | Lists the tenants and registers a tenant when `tenantSlug` does not exist yet, then follows onboarding. Optional: child tenants, and sharing a platform Azure Key Vault with tenants |
| `2. Tenant owner: create a service client` | Signed in as the tenant owner, registers the client-credentials service client your application uses |
| `3. Tenant APIs` | With the service client's token: authorization servers, keys and DIDs, Azure Key Vault, the credential issuer, designs, status lists, defining your own credential, issuing and revoking, DCQL queries and verification, trust domains, and a Keycloak wallet login |

Each folder signs in through its own OAuth2 settings, and every folder lists what
exists before it creates anything, so you can run it again. See
[the Postman guide](../postman/README.md) for the details.

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
