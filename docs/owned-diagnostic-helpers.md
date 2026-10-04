# Owned diagnostic helpers on Windows

These opt-in helpers prepare an independently owned diagnostic customer
environment. Normal customer provisioning and key-window rotation keep their
existing defaults. They do not start containers, create gateway routes, produce
release evidence, or establish runtime readiness.

## Fresh external authority assets

Choose an existing private directory that you own exclusively. The destination
must be an absolute, previously nonexistent child. For example:

```powershell
.\scripts\generate-secret-authority-keys.ps1 `
  -ExternalOutputRoot D:\diagnostics\verifier-owned\private `
  -OutputDirectory D:\diagnostics\verifier-owned\private\authority-window-01 `
  -Workload service-platform,service-crypto,service-data,service-tenant-as,service-oid4vp
```

`service-data` is the DID workload identity. The root must already exist; it
cannot be a drive/share root or contain a reparse point. The helper refuses
existing destinations, including empty directories, and never removes external
output. Use a new destination for another window. Keep generated private keys
outside source control and evidence reports.

Each satellite receives only its own assertion key and the central public key.
The platform receives the central signing key and workload public keys. Mount
the generated directories read-only in their respective containers. The
generated `window.env` keeps the same in-container `/app/secret-authority`
coordinates as normal customer output.

An independently owned environment file can consume those coordinates through
`scripts/generate-compose-secrets.mjs --env <absolute-private-env-file>`, with
`EDK_SECRET_AUTHORITY_ROOT` pointing to this window. Start with fresh secret
fields; the secret generator preserves values that are already set.

Without `-ExternalOutputRoot`, the keys helper remains confined to its own
`compose/.secret-authority` directory and replaces its previous selected window.
Do not run that ordinary rotation against a window used by another environment.

## Verifier-only tenant registration

After the owned platform, tenant AS, tenant KMS, DID and verifier are running,
normal setup/license import is complete, and the gateway routes are loaded:

```powershell
.\scripts\provision.ps1 `
  -EnvFile D:\diagnostics\verifier-owned\private\environment.json `
  -TenantName "Owned verifier diagnostic" -TenantSlug verifier-diagnostic `
  -SkipSetup -VerifierOnly
```

Supply the own operator credential using the existing stdin/private-environment
mechanism. `-VerifierOnly` sends the supported provisioning selection
`issuer=false`, `verifier=true`, `keysAndDids=true`, `sampleData=false`. Login and
the hosted authorization server remain enabled. No issuer or sample data is
requested; any verifier test data and credential-issuer trust configuration
must be provisioned separately through the normal APIs.

This option applies when registering a new tenant. It does not remove an issuer
or existing data from a previously registered tenant. Without the option, the
ordinary customer provisioning selection remains all four values `true`.

Fresh diagnostic QA licenses still require their accepted managed producer
receipt and the normal protected-bundle import. These helpers neither generate
a license nor change embedded trust, deployment identifiers or license gates.
Use an owned Compose project, storage, resource reservations and loopback port;
preprovision the existing TLS ingress readiness route to that same verifier.

## Focused verification

```powershell
pwsh -NoProfile -File .\scripts\tests\test-diagnostic-helpers.ps1
powershell.exe -NoProfile -File .\scripts\tests\test-diagnostic-helpers.ps1
```

The suite executes the real PowerShell destination-preparation block and tenant
request constructor, including CLI parameter binding, against temporary owned
files. It uses real junctions for reparse tests. It invokes no OpenSSL, HTTP,
Docker or Gradle and produces no keys. It does not prove live bootstrap or
readiness.
