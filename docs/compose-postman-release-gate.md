# Customer Compose/Postman release gate

`scripts/run-compose-postman-release-gate.ps1` is the maintained,
non-interactive release gate for the customer Compose topology. `Localtest`
uses the literal self-signed gateway fixture. `BehindEdge` renders a
customer-owned plain-HTTP stack gateway behind the existing shared edge
terminator. Both modes run the shipped 108-request Postman collection with the
maintained Newman and snapshot runner.

The customer walkthrough creates a disposable tenant-owned, MEMORY-backed
SOFTWARE KMS resource and exercises its complete supported lifecycle:
credential status, reference-first credential write, validation, credential
rotation, detach, and retire. Every opaque handle, credential reference, and
optimistic resource version is captured from the preceding API response; the
activation-created default KMS resource is not mutated.

## Prerequisites

- Docker Engine with Docker Compose v2 and Node.js 20 or newer.
- The dependencies under `deploy/edk/e2e/runner` installed.
- A populated customer Compose `.env`. Do not use `.env.example` for a live
  gate.
- A Windows-native `openssl.exe`. The gate mints a fresh, run-scoped Ed25519
  secret-authority window under the ignored `compose/.secret-authority/`
  directory, injects its coordinates through a disposable environment file,
  mounts only role-appropriate key material, and removes the directory during
  terminal cleanup.
- A populated copy of
  `postman/EDK-Enterprise-Deployment.customer.postman_environment.json`.
  `baseDomain` must equal `-BaseDomain`; all password, PKCE, and IdP client
  secret placeholders must be replaced. The IdP client secret is submitted by
  the collection and acts as the run's plaintext-storage canary. It must be an
  encoding-stable 16-128 character token containing only letters, digits,
  underscores, or hyphens. The gate checks raw, JSON-escaped, URL-encoded, and
  PostgreSQL COPY representations and sanitizes all configured credentials from
  retained text evidence.
- `Localtest` requires gateway certificates under `compose/gateway/certs`.
  Node trusts `local-ca.crt`; the gate does not disable TLS verification.
  `compose/gateway/traefik/dynamic.yml` remains the explicit
  `saas.localtest.me` fixture. Its gateway overlay must contain an active
  `appnet` alias for the Postman environment's tenant slug.
- `BehindEdge` requires the existing shared edge Traefik container, its
  externally created attachable `edge` network, public DNS/hairpin routing, and
  the edge's watched dynamic configuration directory. The wrapper renders a
  unique `gw-<EdgeEnvironment>` alias, stack routing, plain-HTTP Traefik
  configuration, and edge router. It publishes no gateway host ports and uses
  neither the Localtest CA nor private truststore mounts.
- All seven enterprise images already present locally under one new immutable
  tag: `enterprise-platform`, `enterprise-tenant-kms`, `enterprise-did`,
  `enterprise-tenant-as`, `enterprise-issuer`, `enterprise-verifier`, and
  `admin-console`. The tag cannot be `latest`, a branch name, or a snapshot.
  The images must carry one coherent set of OCI build labels. The coherent OCI
  version must exactly equal the selected immutable tag; the source, revision,
  creation time, and version form the retained release-identity fingerprint.
- Supporting Compose images such as PostgreSQL, Traefik, Jaeger, and the OTEL
  collector available locally. The gate uses `--pull never` after image
  preflight so a tag cannot change between verification and startup.
- For a clean installation, a protected license bundle ZIP. For an existing
  installation, the anonymous setup gate must already be closed.

## Static validation

This validates paths, the immutable seven-image plan, and the exact request
count without invoking Docker or making HTTP requests:

```powershell
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File .\scripts\run-compose-postman-release-gate.ps1 `
  -Tag 0.25.0-RC3-build.20260730 `
  -ProjectName edk_customer_rc3_gate `
  -ReportDir D:\edk-evidence\rc3-dry-run `
  -AccessMode Localtest `
  -BaseDomain saas.localtest.me `
  -SourceState ..\..\deploy\edk\build\reports\release-source-state-0.25.0-RC3-build.20260730.json `
  -ExpectedSource https://github.com/Sphereon-Opensource/VDX-infra `
  -ComposeEnvFile .\compose\.env.example `
  -PostmanEnvironmentFile .\postman\EDK-Enterprise-Deployment.customer.postman_environment.json `
  -PreProvisionedSetup `
  -DryRun
```

The coupled source test is also Docker-free:

```powershell
node .\scripts\run-compose-postman-release-gate.contract.test.mjs
```

The contract also renders `BehindEdge` for
`compose-rc3.nk.sphereon.com` and verifies the selected overlay has no host
ports, Localtest CA, or private truststore.

## Shared-edge release run

The edge environment label owns one disjoint host space and produces the
network alias `gw-<label>`. The wrapper fails if another edge router file
already references the requested base domain. During execution it verifies the
shared edge container and network, atomically installs the rendered edge route,
and removes only a route it installed after successful owned-project teardown.
`-KeepUp` and adopted projects retain their route.

```powershell
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File .\scripts\run-compose-postman-release-gate.ps1 `
  -Tag 0.25.0-RC3-build.20260730 `
  -ProjectName edk_customer_rc3_edge_gate `
  -ReportDir D:\edk-evidence\rc3-edge-compose-postman `
  -AccessMode BehindEdge `
  -BaseDomain compose-rc3.nk.sphereon.com `
  -EdgeEnvironment compose-rc3 `
  -EdgeNetworkName edge `
  -EdgeTrustedSubnet 172.16.100.0/24 `
  -EdgeTraefikContainer vdx-edge-traefik-1 `
  -EdgeRouterDirectory ..\..\deploy\edge\dynamic `
  -SourceState ..\..\deploy\edk\build\reports\release-source-state-0.25.0-RC3-build.20260730.json `
  -ExpectedSource https://github.com/Sphereon-Opensource/VDX-infra `
  -ComposeEnvFile .\compose\.env `
  -PostmanEnvironmentFile D:\secure\customer.edge.postman_environment.json `
  -LicenseBundleZipPath D:\secure\edk-license-bundle.zip `
  -ResetVolumes
```

The shared edge must already own public 80/443 and a publicly trusted wildcard
certificate resolver. The customer stack joins its existing external network;
it never starts, restarts, or reconfigures the shared edge container itself.

## Clean-volume release run

`-ResetVolumes` is the explicit authorization to delete only the named Compose
project's volumes before startup. It cannot be combined with
`-PreProvisionedSetup`.

```powershell
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File .\scripts\run-compose-postman-release-gate.ps1 `
  -Tag 0.25.0-RC3-build.20260730 `
  -ProjectName edk_customer_rc3_gate `
  -ReportDir D:\edk-evidence\rc3-compose-postman `
  -AccessMode Localtest `
  -BaseDomain saas.localtest.me `
  -SourceState ..\..\deploy\edk\build\reports\release-source-state-0.25.0-RC3-build.20260730.json `
  -ExpectedSource https://github.com/Sphereon-Opensource/VDX-infra `
  -ComposeEnvFile .\compose\.env `
  -PostmanEnvironmentFile D:\secure\EDK-Enterprise-Deployment.rc3.postman_environment.json `
  -LicenseBundleZipPath D:\secure\edk-license-bundle.zip `
  -ResetVolumes
```

The gate previews and imports the protected bundle through the platform setup
API, bootstraps the operator using the returned activation link, and verifies
that the setup gate closes. A structured setup-status document is required
while the gate is open. After setup, the gate completes a fresh authorization
code plus PKCE sign-in with the exact configured operator and requires a
`platform-admin` token. A pre-provisioned run uses the same sign-in proof so an
unrelated gateway 404 cannot masquerade as a closed product setup gate.
`setup-evidence.json` records whether a supplied license bundle was actually
consumed. The gate does not accept caller-invented installation, tenant,
resource, or activation identifiers.

## Existing pre-provisioned installation

The gate inventories every Compose-project-labeled container, network, and
volume before startup. A stopped project with only volumes or networks is still
an existing project. The gate refuses to adopt any existing project unless
`-UseExistingProject` is explicit:

```powershell
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File .\scripts\run-compose-postman-release-gate.ps1 `
  -Tag 0.25.0-RC3-build.20260730 `
  -ProjectName edk_customer_rc3_gate `
  -ReportDir D:\edk-evidence\rc3-preprovisioned `
  -AccessMode Localtest `
  -BaseDomain saas.localtest.me `
  -SourceState ..\..\deploy\edk\build\reports\release-source-state-0.25.0-RC3-build.20260730.json `
  -ExpectedSource https://github.com/Sphereon-Opensource/VDX-infra `
  -ComposeEnvFile D:\secure\customer-compose.env `
  -PostmanEnvironmentFile D:\secure\customer.postman_environment.json `
  -PreProvisionedSetup `
  -UseExistingProject
```

`-UseExistingProject` fails when no existing project assets are present, so an
adoption can never be reclassified as gate ownership. By default, a project
owned and started by the gate is torn down without deleting its volumes.
Ownership is established before reset/start mutation, so a partially failed
`compose up` is captured and cleaned up. `-KeepUp` retains it for diagnosis.
`-RemoveVolumesOnTeardown` explicitly authorizes deleting volumes during final
teardown. An adopted project is left running to preserve its prior ownership
boundary.

## Evidence and failure bar

The explicit report directory receives:

- the release plan, non-interpolated Compose config, resolved image list,
  coherent seven-image preflight, release-identity fingerprint, and the image
  ID of the exactly one running container for every release-bearing service;
- Compose startup, `ps`, timestamped logs, setup evidence, and a final evidence
  manifest with SHA-256 hashes. Teardown occurs before terminal evidence
  finalization. The detached `evidence-manifest.sha256` accounts for the
  manifest itself; the manifest explicitly documents why the detached hash
  file cannot self-hash;
- Newman CLI output, JUnit, failure summary, and snapshot drift patch when
  drift occurs. The runner's secret-bearing runtime environment and optional
  HTML report are isolated in disposable staging and are not retained;
- platform and tenant schema-only PostgreSQL dumps;
- plaintext-canary absence results for Compose logs and data-only dumps from
  both databases, plus a final scan of the retained evidence bundle. Database
  dump producer and scanner exit codes are checked independently, and data-only
  dump bytes are streamed to the scanner rather than retained.

The run fails unless Newman captures exactly 108 requests with exit code zero.
Skipped requests therefore fail the request-count and snapshot gate. Failed
requests/assertions, missing/stale/drifted snapshots, incoherent images, an
unexpectedly open setup gate, image-ID mismatch, empty evidence, or a plaintext
canary in logs/database rows all fail the release gate. JUnit must contain a
complete `testsuites` document with numeric and internally consistent totals,
at least one suite and testcase, and zero failures/errors. A teardown failure
produces a terminal `failed` manifest and can never leave a `passed` manifest.
