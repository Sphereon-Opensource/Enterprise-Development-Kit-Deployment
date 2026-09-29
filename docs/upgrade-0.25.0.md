# Upgrading a Docker Compose installation to 0.25.0

This guide covers an existing Docker Compose installation of 0.25.0-RC4 or
0.25.0-RC5 that keeps its databases, keystores and secret-authority keys. Both
release candidates upgrade directly to 0.25.0. Do not stop at RC5 on the way
from RC4.

Helm installations use `scripts/upgrade-helm.sh` and the values files under
`helm/edk-enterprise/examples/upgrades/`; see the
[Kubernetes quickstart](quickstart-kubernetes.md).

## What stays the same

- The Compose project name (`edk-enterprise`), the service names and the named
  volumes: `platform-postgres-data`, `tenant-postgres-data`,
  `platform-keystore`, `tenant-kms-keystore` and `blob-store-data`. Keep all of
  them. The keystores hold key material that is not in the databases.
- The service set. 0.25.0 runs the same services as RC4 and RC5 from the same
  images: `enterprise-platform`, `enterprise-tenant-as`,
  `enterprise-tenant-kms`, `enterprise-did`, `service-data` (the
  `enterprise-blob` service), `enterprise-issuer`, `enterprise-verifier`, and
  `admin-console` (started twice, as `admin-console` and
  `admin-console-tenant`), plus the two PostgreSQL databases and the bundled
  OpenTelemetry collector and Jaeger. The product images come from
  `nexus.sphereon.com/edk-docker` with one tag.
- The secret-authority key set in `EDK_SECRET_AUTHORITY_ROOT` and the four
  `SECRET_AUTHORITY_*` values in `.env`. Do not generate a new key set during
  the upgrade.
- The secret-management environment manifests. Their secret ids did not
  change.

## What changes

### Environment variables

| Variable | RC4 and RC5 | 0.25.0 |
| --- | --- | --- |
| `EDK_TAG` | Defaulted to `0.25.0-SNAPSHOT` when unset | Required. Compose refuses to start without it. |
| `EDK_PLATFORM_BASE_DOMAIN` | Required | Unchanged |
| `EDK_FEDERATION_SESSION_ENCRYPTION_KEY` | Not used | Required. 32 random bytes, base64. The tenant authorization server encrypts pending external-login sessions with it. |
| `EDK_INTERNAL_CLIENT_SECRET_EMAIL` | Required | Removed. No service reads it. Delete the line. |
| `EDK_ONBOARDING_UI_EXTERNAL_BASE_URL` | Optional | Removed. The onboarding UI always uses the platform URL. |
| `EDK_KMS_INTERNAL_BASE_URL`, `EDK_BLOB_EXTERNAL_BASE_URL` | Optional | Removed. Both services use fixed internal addresses. |
| `EDK_SECRET_MANAGEMENT_ENVIRONMENT_MANIFEST`, `EDK_SECRET_MANAGEMENT_ENVIRONMENT_MANIFEST_SHA256` | RC5 only, optional | Unchanged. The digest is now written by `generate-compose-secrets.mjs`. |
| `EDK_PLATFORM_KMS_AZURE_*`, `EDK_PLATFORM_KMS_AWS_*` | RC5 only, optional | Unchanged. See [Shared cloud KMS providers](#shared-cloud-kms-providers-rc5). |

RC4 and RC5 shipped the same `.env.example`. Both contained placeholder values
that are public:

- `EDK_INTERNAL_CLIENT_SECRET_*=replace-me-...`
- `EDK_PIPELINE_MASTER_KEK` and `EDK_PIPELINE_BLIND_INDEX_KEY` with fixed
  example values.

If your `.env` still holds them, the upgrade works, but plan their rotation
(see [After the upgrade](#after-the-upgrade)).

### Service configuration files

The files under `compose/config/` are part of the kit. Take the 0.25.0 files
and reapply your own changes to them rather than keeping the RC files.

- **Platform authorization server.** RC4 configured the platform
  authorization server under `oauth2.servers.default`. RC5 and 0.25.0 name it
  `platform` and select it with `oauth2.servers.default-server: platform`.
  0.25.0 still reads the RC4 layout, so an unchanged RC4 file starts, but the
  kit file uses the new layout. When you move to it, replace the
  `oauth2.servers.default` block instead of keeping it next to the new
  `platform` block.
- **Removed platform keys.** RC4 and RC5 `platform.application.yml` had a
  `platform.sts` block (`workload-client-id`,
  `secret-bootstrap-workload-client-ids`, `allowed-audiences`), an `email`
  internal client, and `public-clients.allow-any` and
  `permissive-redirect-uri` on the platform server. 0.25.0 does not read them.
  Each internal client now declares its own `token-exchange` settings, and the
  operator client declares the audiences it may exchange for.
- **New platform keys.** `server.sts.provisioning-client-id`, the
  `security` authentication-level defaults (password login is accepted at
  0.25.0), and the tenant invalidation database route
  (`database.app.tenant-invalidation`, RC5 already had it).
- **Blob service.** `blob.application.yml` gained the same `security`
  authentication-level defaults and an `authz` block that limits branding and
  asset-library writes to tenant and platform administrators.
- **Tenant authorization server.** `tenant-as.application.yml` reads
  `EDK_FEDERATION_SESSION_ENCRYPTION_KEY` (passed to the container as
  `FEDERATION_SESSION_ENCRYPTION_KEY`) and pins its application database route
  to the shared `public` schema.
- **Tenant KMS.** `tenant-kms.application.yml` declares its local
  `secret-management` settings, which RC4 did not have.
- **Shared cloud KMS provider ids.** 0.25.0 reads the ids under
  `secret-management.authority.platform-providers` only in bracket-quoted form,
  for example `"[azure-shared-signing]"`. RC5 used unquoted ids.

### Database schema

You do not run migrations by hand. On its first start the 0.25.0 platform
migrates the platform database, the secret-management tables, and every tenant
schema in the tenant database, and converts stored authorization-server
records. The other services wait for the platform to report healthy and only
validate the schema; they never receive DDL credentials.

The restricted secret-management database roles get an explicit
`search_path` in 0.25.0. The Compose PostgreSQL health check reruns the role
script on every probe, so existing databases receive this change on the first
start without a manual SQL step.

### Gateway routes

The shipped Traefik route table (`compose/gateway/traefik/dynamic.yml` and the
public-cert and Let's Encrypt templates) gained tenant-host routes that 0.25.0
clients call:

- `/api/oauth2/v1` (authorization-server listing) and `/api/account-actions/v1`
  (owner activation) to the tenant authorization server.
- `/api/audit/v1`, `/api/forms/v1`, `/api/workflow/v1`, `/api/lifecycle/v1`,
  `/api/services/v1`, `/api/v1/config` and `/api/invitation/v1/invitations` to
  the platform.
- `/api/connector/v1`, `/api/blob-store/v1`, `/api/users/v1`, `/api/v1/schemas`
  and `/api/v1/tabular-mapping-templates` to the blob service.
- Developer console reads under `/api/developer-console/v1`,
  `/developer-journeys/index.json`, and the developer console sign-in paths.

A route file rendered from an RC template lacks these routes, and requests to
them return 404 at the gateway. Render it again with the 0.25.0 template, using
the same command and base domain as at install. If you operate your own
reverse proxy, add the same host and path rules.

## Upgrade steps from RC5

1. Back up both PostgreSQL databases and the `platform-keystore`,
   `tenant-kms-keystore` and `blob-store-data` volumes. Keep a copy of `.env`
   and of the secret-authority directory.
2. Check out the 0.25.0 kit next to your current installation, or replace the
   kit files in place. Keep your `compose/.env` and your secret-authority
   directory.
3. Compare your `compose/config/*.yml` files with the RC5 versions of the kit.
   Move any change you made into the 0.25.0 files. If you declared a shared
   Azure or AWS KMS provider, keep the bracket-quoted ids of the 0.25.0 file.
4. In `compose/.env`, delete `EDK_INTERNAL_CLIENT_SECRET_EMAIL`,
   `EDK_ONBOARDING_UI_EXTERNAL_BASE_URL`, `EDK_KMS_INTERNAL_BASE_URL` and
   `EDK_BLOB_EXTERNAL_BASE_URL` if present.
5. Make sure every value that the running RC5 containers use is written in
   `.env`. The generator in the next step fills empty values with new random
   ones, which is correct for new secrets but breaks existing data for a value
   that was empty in `.env` and supplied some other way. In particular check
   `EDK_KEYSTORE_PASSWORD`, `EDK_PLATFORM_DB_PASSWORD`,
   `EDK_TENANT_DB_PASSWORD`, the three `EDK_SECRET_MANAGEMENT_*_DB_PASSWORD`
   values, `EDK_ADMIN_CONSOLE_WORKLOAD_CLIENT_SECRET` and both
   `EDK_PIPELINE_*` keys. `docker compose config` on the RC5 files shows the
   values the containers received.
6. Run `node scripts/generate-compose-secrets.mjs`. It adds
   `EDK_FEDERATION_SESSION_ENCRYPTION_KEY`, recomputes the manifest digest when
   you selected a non-default manifest, keeps every existing value, and lists
   the values that come from the published template.
7. If you use the public-cert or Let's Encrypt gateway, or the behind-edge
   overlay, render the route file again from the 0.25.0 template.
8. Run the upgrade wrapper with the target tag and the same Compose file list
   you use for the installation:

   ```bash
   bash ./scripts/upgrade-compose.sh \
     --image-tag 0.25.0 \
     --compose-dir ./compose \
     --file ./compose/docker-compose.yml \
     --file ./compose/docker-compose.gateway.yml
   ```

   On Windows use `.\scripts\upgrade-compose.ps1 -ImageTag 0.25.0` with the
   same `-ComposeDir` and `-File` values. The wrapper detects RC5, pulls the
   0.25.0 images, starts the platform first and waits for every service.
9. Set `EDK_TAG=0.25.0` in `.env` so later Compose commands use the same
   images.

## Upgrade steps from RC4

Follow the RC5 steps with these additions:

- In step 3, the RC4 `platform.application.yml` still configures the platform
  authorization server under `oauth2.servers.default`. Take the 0.25.0 file and
  reapply your changes to it, replacing the `oauth2.servers.default` block.
- Upgrade straight to 0.25.0. The RC5 platform image stops during authority
  bootstrap with `VDX_CONFIGURATION_INTERPOLATION_DENIED` for
  `oauth2.servers.default.webauthn.rp.id` when it reads an RC4 platform file.
  The upgrade wrapper already goes directly from RC4 to 0.25.0.
- RC4 had no shared cloud KMS declarations. Leave the
  `EDK_PLATFORM_KMS_*` variables unset unless you want to add one after the
  upgrade.

## If the platform does not start

- `Authorization-server migration source previously failed`: set
  `AUTHORIZATION_SERVER_MIGRATION_RESUME_FAILED=true` in `.env`, start the
  stack once, then remove the line again. Do not change the `oauth2.servers`
  configuration between the failed start and the retry.
- `INVALID_CONFIGURATION` naming a shared KMS provider: the provider id is not
  bracket-quoted, or a `KIND` is set without the matching manifest. Use the
  0.25.0 `platform.application.yml` and select the manifest that lists the
  provider's secret.
- A container that stops at startup with a missing variable message: run
  `node scripts/generate-compose-secrets.mjs` again and check that the
  variable is in `.env`.

Startup errors name the property and the property source that supplied it.
They never print the configured value.

## After the upgrade

- Existing tenants keep their hosts, keys, DIDs and credential
  configurations. The OID4VCI credential issuer identifier of each tenant is
  `https://<tenant>.<base-domain>/oid4vci/<tenant>`. Wallets that hold an
  offer or credential issued under an older identifier need a new offer.
- Rotate values that came from the published template in a maintenance window:
  - `EDK_INTERNAL_CLIENT_SECRET_*`: clear the value, run
    `generate-compose-secrets.mjs`, and restart the whole stack at once. The
    platform registers each internal client with the value from its own
    environment, and the service presents the value from its own, so both must
    change together.
  - `EDK_PIPELINE_MASTER_KEK` and `EDK_PIPELINE_BLIND_INDEX_KEY`: rotate when no
    issuance pipeline session is open. Open sessions sealed with the old keys
    cannot be read after the change.
- Remove `edk-compose-upgrade-backup` only after you have verified the
  installation and kept your database backups.
