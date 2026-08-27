# Secret management

Secrets are a first-class control-plane resource. They are not configuration
properties and are not selected through a deployment-wide backend switch.
Operators configure platform storage, publish isolated provider offerings, and
set tenant policy in the **Secrets** area of the admin console. Tenants can use
only the offerings and tenant-managed provider modes allowed by that policy.

The API returns opaque `secretId` handles. It never returns provider paths,
partitions, backend identifiers, environment-variable names, or plaintext.
Applications persist the handle, not a `${secret:...}` or `${env:...}`
expression.

## Deployment roots

The platform requires two deployment-owned roots before it starts:

1. An immutable, non-exportable cloud KMS key-encryption key (KEK), accessed
   only through the platform workload identity. The platform must have a
   dedicated identity; satellite service accounts cannot use the KEK.
2. The platform database owner credential for deployment-time migration, plus
   separate credentials for the secret-management admin and tenant-serving
   runtime pools.

The PostgreSQL roles have fixed names:

- `secret_management_admin` performs platform-admin DML after migration. It
  does not own the schema, cannot create objects, must not be a superuser, and
  must not have `BYPASSRLS`.
- `secret_management_tenant_serving` is subject to row-level security. It must
  not be a superuser and must not have `BYPASSRLS`.

The named `secret-management-migrator` route reuses the existing platform
database owner only during startup. It runs the greenfield legacy-state guard,
removes empty obsolete objects, applies SQLDelight migrations and hardening,
then grants the exact runtime privileges. HTTP request handling never uses that
route.

Docker Compose creates these roles on a fresh bundled platform database from
`compose/postgres-init/10-secret-management-roles.sh`. Set
`EDK_SECRET_MANAGEMENT_ADMIN_DB_PASSWORD`,
`EDK_SECRET_MANAGEMENT_TENANT_DB_PASSWORD`, and
`EDK_SECRET_MANAGEMENT_RUNTIME_DB_PASSWORD` to distinct strong values.

For Helm or an externally managed database, create the roles before starting
the platform and store their passwords in the Kubernetes Secret selected by
`database.secretManagement.existingSecret`. The default keys are
`admin-password`, `tenant-password`, and `runtime-password`. Grant all three roles `USAGE` on the target
schema; do not grant `CREATE`, ownership, role membership, superuser, or
`BYPASSRLS`.

## Storage tiers

- The bootstrap store contains only credentials that unlock platform storage
  and platform-wide offering provisioners. It is enveloped under the deployment
  KEK.
- The active platform store contains tenant-owned provider credentials and
  tenant-scoped capabilities.
- Each tenant's selected provider contains that tenant's application secrets.

A provider credential is never stored in the provider it unlocks.

Environment and Kubernetes-mounted sources are deployment-only and read-only.
They require an explicit startup manifest of managed opaque secret IDs. They
cannot be tenant offerings or writable defaults.

## Provider egress

Provider endpoints are HTTPS-only and resolve through the platform's central
egress policy. Loopback, link-local, metadata, and private destinations are
denied by default. DNS is re-resolved and the selected address is checked again
before credentials are released.

Private Vault and PrivateLink endpoints require a platform-owned hostname and
CIDR allowlist. For Compose, edit
`compose/config/secret-provider-private-endpoints.manifest`. For Helm, set
`secretManagement.egress.privateEndpointAllowlist`. Each entry uses a reviewed
hostname pattern with one or more exact CIDRs; both the hostname and the
resolved address must match. The allowlist is mounted only into the platform
workload and cannot be supplied through tenant APIs.

## Provider changes

Provider definitions are immutable after a revision becomes ready. Endpoint,
account, vault, mount, KMS binding, isolation, and credential changes create a
candidate revision. The platform performs credential staging, authenticated
write/read/delete connectivity probes, preflight, and a fenced migration before
changing an assignment.

Mutations use strong `ETag`/`If-Match` validators. Creates, rotations, and
migration starts also require an idempotency key. A missing validator returns
`428`; a stale validator returns `412`; policy or dependency conflicts return
`409`.

Blank credential fields retain their current value. Supplying a value rotates
it. Clearing an optional credential requires a separate explicit confirmation.
Plaintext is write-only and must not be placed in Helm values, ConfigMaps,
Docker Compose files, logs, or Postman environments.

## Greenfield migration

This schema does not dual-read or import legacy secret-provider configuration.
Startup aborts with an explicit reset diagnostic if legacy provider,
migration, or config-key state exists. The deployment owner performs this
check before any new schema change. Restore the pre-migration database snapshot
to run an older binary; otherwise reset the legacy state before starting this
release.
