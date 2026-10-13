# Diagnosing console, tenant registration and Azure KMS issues on 0.25.0

Use this with the [0.25.0 upgrade guide](upgrade-0.25.0.md). Updating image
tags does not update mounted configuration or previously generated gateway
files. This procedure preserves the databases, keystores and authority keys.

## Findings and limits

| Symptom | Finding | What still needs installation evidence |
| --- | --- | --- |
| Tenant Developer Console redirects to `/admin-console/developer-console` | The customer kit tagged `v0.25.0` contains a trailing-slash rewrite defect, also present in RC4/RC5. Replacing old files with those exact final files alone does not correct it. | Actual router, redirect chain and failing request on the affected tenant host. |
| Tenant registration reports an error but the tenant works | The final frontend catches errors from both registration and its subsequent onboarding-status polling in the same handler. A status-read failure can therefore report failure after successful creation. | Registration response, status-read response and correlation ID. |
| Enabling Azure environment variables prevents startup | Final configuration requires bracket-quoted provider IDs, the Azure environment manifest, its digest and the canonical environment variables. | First startup exception and property/source named by it. |
| `kms.key.generate-managed was refused` | The API message covers multiple typed-resource, authority, metadata and provider-execution failures. `{"alias":"test2","alg":"ECDSA_SHA256"}` is supported input. | The matching KMS refusal reason and authority/provider logs. |

These findings establish source/configuration behavior, not a completed repair
of a customer installation. Do not infer an Azure permission error from the
generic HTTP 500 alone.

## 1. Establish the installed configuration

Before changes, back up both databases, the platform and tenant KMS keystores,
blob storage, `.env`, secret-authority directory, service configuration and
active gateway files. Keep the same Compose project name and volume identities.
Do not use `docker compose down -v` to troubleshoot these symptoms.

From the deployment-kit root, use the **same complete Compose file list and
project selection as the installation**. The following examples assume the
standard gateway overlay; substitute the actual public-cert, Let's Encrypt or
custom overlays when applicable:

```bash
docker compose --project-directory ./compose \
  -f ./compose/docker-compose.yml -f ./compose/docker-compose.gateway.yml ps -a
docker compose --project-directory ./compose \
  -f ./compose/docker-compose.yml -f ./compose/docker-compose.gateway.yml images
docker compose --project-directory ./compose \
  -f ./compose/docker-compose.yml -f ./compose/docker-compose.gateway.yml config --quiet
```

Record running image IDs/digests for all eight product images, including both
`admin-console` and `admin-console-tenant` containers. A tag in `.env` does not
prove which image a running container uses. Inspect the mounted gateway file,
not just the template in the repository. Full rendered Compose configuration
contains credentials; keep it private and share only redacted relevant fields.

## 2. Correct the Developer Console rewrite

There are two different browser entry points:

- Platform operator: `https://platform.<base-domain>/admin-console/developer-console`.
- Tenant developer: `https://<tenant>.<base-domain>/developer-console`.

The platform catch-all has priority 1000. It intentionally takes precedence
over the tenant Developer Console router (priority 280); the platform
`/admin-console` router has priority 1100. Testing `/developer-console` on the
platform host is therefore not a test of the tenant projection.

In the tagged customer kit, `developer-console-page-rewrite` is:

```yaml
developer-console-page-rewrite:
  replacePathRegex:
    regex: "^/developer-console(?:/(.*))?$"
    replacement: "/admin-console/developer-console/$1"
```

For a root request, this produces `/admin-console/developer-console/`.
Next.js trailing-slash normalization can redirect the browser to the internal
mount. Change this middleware to:

```yaml
developer-console-page-rewrite:
  replacePathRegex:
    regex: "^/developer-console(/.*)?$"
    replacement: "/admin-console/developer-console$1"
```

Apply the correction to the active rendered file and its source template:

- `compose/gateway/traefik/dynamic.yml`
- `compose/gateway/traefik/dynamic.public-cert.template.yml`
- `compose/gateway/traefik/dynamic.letsencrypt.template.yml`

Use only the file/template appropriate to the installed overlay at runtime,
but retain the correction in templates so regeneration cannot reintroduce it.
Render using the existing domain and TLS choices. The Traefik file provider
does not interpolate the base domain from `.env`. Keep `passHostHeader: true`
and the original public Host through any outer proxy/CDN.

Reload the active Traefik configuration; for the standard overlay a maintenance
restart uses the same Compose arguments followed by `restart traefik`. Check
Traefik logs for configuration rejection. Check any outer proxy/CDN for a
cached redirect after correcting the origin. Do not introduce an HTTP redirect
to the internal Next.js mount or strip `/admin-console` from its assets.

Verify with browser Network logging preserved and uncached GET requests:

```bash
curl -sS -D - -o /dev/null https://<tenant>.<base-domain>/developer-console
curl -sS -D - -o /dev/null https://platform.<base-domain>/admin-console/developer-console
```

The tenant root must no longer redirect to `/admin-console/developer-console`.
Check the rendered page, assets, catalog and sign-in/callback flow too; HTTP
200 alone does not prove the browser works. If the platform page itself fails,
identify whether the document or a subsequent API/asset request returns 404.
The tenant rewrite correction does not explain every platform-host failure.

## 3. Configure a deployment-shared Azure provider

Use the final `compose/config/platform.application.yml`. Its provider key is
`"[azure-shared-signing]"`, not `azure-shared-signing`. Retain the typed
credential reference `sec_platform_azure_kms_client_secret_01`.

Configure the following in the existing private `compose/.env`:

```dotenv
EDK_PLATFORM_KMS_AZURE_KIND=AZURE_KEY_VAULT
EDK_PLATFORM_KMS_AZURE_VAULT_URI=https://<vault-name>.vault.azure.net
EDK_PLATFORM_KMS_AZURE_TENANT_ID=<entra-directory-id>
EDK_PLATFORM_KMS_AZURE_CLIENT_ID=<app-registration-client-id>
EDK_PLATFORM_KMS_AZURE_CLIENT_SECRET=<client-secret>
EDK_PLATFORM_KMS_AZURE_HSM_TYPE=KEYVAULT
EDK_PLATFORM_KMS_AZURE_SHARED_TENANTS=<comma-separated-tenant-ids>
EDK_SECRET_MANAGEMENT_ENVIRONMENT_MANIFEST=./config/secret-management-environment.azure.manifest
```

Use `*` for shared tenants only when intentionally offering this provider to
all tenants. If AWS is also enabled, select the combined `azure-aws` manifest
and supply its required variables. Do not select the combined manifest with
empty AWS credentials.

The Azure manifest must contain the existing console and software-KMS entries
and this additional mapping:

```text
sec_platform_azure_kms_client_secret_01=EDK_PLATFORM_KMS_AZURE_CLIENT_SECRET
```

Legacy `AZURE_KEYVAULT_ENDPOINT`, `AZURE_TENANT_ID`, `AZURE_CLIENT_ID` and
`AZURE_CLIENT_SECRET` assignments alone do not configure this provider in the
shipped customer Compose file. A successful startup with `*_KIND` unset does
not prove that Azure is configured. Keycloak credentials are a separate flow.

Before running the generator, ensure `.env` contains the existing effective
database passwords, keystore password, workload secrets and pipeline keys.
The generator fills empty values; generating replacements for existing secrets
would break the installation. Then, from the kit root:

```bash
node scripts/generate-compose-secrets.mjs --env ./compose/.env
```

This derives `EDK_SECRET_MANAGEMENT_ENVIRONMENT_MANIFEST_SHA256` from the
selected manifest. Do not hash the file bytes manually: the digest algorithm
uses the manifest's sorted secret IDs. Follow the upgrade guide to reconcile
all service files and recreate the containers with the updated environment.
A `restart` alone does not inject changed Compose environment variables.

If startup still fails, capture the first `INVALID_CONFIGURATION`, manifest,
digest or interpolation exception. Do not disable authority checks or edit
provider metadata directly in SQL.

## 4. Diagnose the runtime key-generation refusal

First decide which tenant should own the key. A request made through the
platform console uses its authenticated context; it is not automatically a
request for a selected customer tenant. Platform generation is not categorically
forbidden, but the active provider must be visible in that session.

For a customer tenant, use its authenticated session and host. Enable the
shared offering through the supported API before generating a key:

```text
POST /api/platform/config/v1/tenants/<tenant-id>/kms/shared-providers/azure-shared-signing:enable
GET  /api/kms/v1/providers
POST /api/kms/v1/providers/azure-shared-signing/keys
```

All three requests use `https://<tenant>.<base-domain>`. Confirm the provider
appears in that session's provider listing. For intentional platform-owned
keys, check the same listing under the platform session instead.

On refusal, correlate the request time/ID with `enterprise-tenant-kms` and
`enterprise-platform` logs. Relevant markers are:

```text
VDX_KMS_MANAGED_KEY_PREPARE_REFUSED
VDX_KMS_MANAGED_KEY_GENERATE_REFUSED
VDX_KMS_MANAGED_KEY_INDEX_REFUSED
```

| Reason | Next check |
| --- | --- |
| `binding-unresolved`, `visible-resource-absent` | Session tenant, enabled offering and active resource handle. |
| `provider-metadata-inactive`, `provider-operation-inactive`, `provider-operation-mismatch` | Active provider revision and operation metadata; capture evidence for engineering rather than rewriting rows. |
| `resource-execution-refused`, `secret-use-denied` | Authority decision, workload identity, credential handle and manifest consistency. |
| `exception-provider-generate-*`, `provider-returned-no-key` | Azure response/exception, credentials, vault access, network reachability and timeout. |
| Index/reference-store refusal | Determine whether Azure already created the key before retrying. |

Do not repeatedly submit the same alias after an ambiguous failure. Check for
an already-created cloud key and VDX reference first. Preserve existing cloud
keys and BYOK/BYOC registrations while diagnosing.

## 5. Distinguish registration from a status-read failure

Capture the registration POST response before retrying. If it returned 201,
retain `tenant.id` and `correlationId`, and inspect the subsequent request:

```text
GET /api/platform/admin/v1/tenant-onboarding/<correlationId>
```

The console may prefix this with `/admin-console` through its BFF. Use the
actual browser request and the same authenticated session. The final frontend
puts this read and registration in the same `try/catch`; a failed read can
display a registration error even after a successful POST. Its polling loop
has 120 attempts with 1.5-second delays between attempts.

- **201 followed by a failed status GET:** diagnose BFF/gateway/session failure
  and report the frontend error-reporting defect; do not register again.
- **Non-201 registration:** inspect response and correlation information, then
  check tenant-AS, tenant-KMS and platform logs for the failed provisioning step.
- **A tenant exists after a timeout:** look up its lifecycle status before any
  retry or cleanup; durable state alone does not establish all steps completed.

For `REMOTE_PLATFORM_CONFIG_UNAVAILABLE`, `platform.config.get`, or missing
internal authorization, follow [signing-key provisioning troubleshooting](troubleshooting.md#tenant-registration-fails-during-signing-key-provisioning).
Align service client secrets, audiences and routing; an operator login working
does not establish internal service authentication works.

The reported legacy-table probe `SELECT COUNT(*) FROM vdx_tenant_idp WHERE 1 = 0`
needs its surrounding migration/startup logs. Do not create that obsolete table
manually or assume it caused the tenant error merely because it appears in logs.

## Upgrade and acceptance

RC4/RC5 upgrade directly to final using the [upgrade guide](upgrade-0.25.0.md),
plus the rewrite correction above. The wrapper has an RC1-to-RC2 intermediate
step for older installations; do not invent an RC6 migration path (the shipped
planner does not recognize RC6). Establish the actual installed release first.
An installation already on final normally needs configuration reconciliation,
not a downgrade or replay of old migrations.

After preserving existing secrets, updating files and regenerating the active
gateway configuration, the standard-overlay invocation is:

```bash
bash ./scripts/upgrade-compose.sh --image-tag 0.25.0 \
  --compose-dir ./compose \
  --file ./compose/docker-compose.yml \
  --file ./compose/docker-compose.gateway.yml
```

Use the actual overlay/project selection, keep `EDK_TAG=0.25.0` for subsequent
commands, and let platform startup run database migrations. The wrapper's
configuration backup is not a substitute for database/keystore backups.

Acceptance requires: healthy services and expected image digests; working
tenant Developer Console including catalog and sign-in; successful tenant
registration and status display; provider visibility in the intended session;
and one controlled Azure key generation plus signing verification. Record
request IDs and final outcomes. On migration failure, preserve logs and stop;
restore matching database/keystore/config backups under the deployment recovery
procedure rather than starting an older binary against an upgraded database.
