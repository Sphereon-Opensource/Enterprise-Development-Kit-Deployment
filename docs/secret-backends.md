# Secret backends

The enterprise services need signing keys, KMS provider credentials, and
database credentials. Supply these as references to a secret backend rather than
as literal values. The services resolve a reference at runtime against the
backend you select.

Do not put plaintext credentials in values files or config templates used for
production.

## KMS providers

The KMS service holds signing key material and serves signing operations to DID,
tenant-AS, issuer, and verifier. Choose the provider that matches your key
custody requirements:

- Software keystore. Keys live in a PKCS#12 keystore the KMS service manages.
  This is the platform config default (`kms.providers.software`). It is the
  right choice for evaluation and for deployments where a software keystore meets
  your custody policy. No external secret system is required, but you still
  supply the keystore password as a reference.
- Managed vault (for example HashiCorp Vault). Keys and credentials live in the
  vault. The service references them; the vault performs storage and access
  control.
- Cloud KMS (for example AWS Secrets Manager or Azure Key Vault). Credentials
  and key references live in the cloud provider's secret store. The service
  resolves a reference at use time.

Select the KMS provider through configuration. The platform first-run setup binds
to the provider named by `PLATFORM_SETUP_KMS_PROVIDER_ID` (default `_license_`).
The license recipient key used for setup activation is also KMS-backed in
interactive deployments (`license.recipient.kms.enabled=true`) and defaults to
the platform system license provider with alias `license-recipient`; non-platform
services consume the platform's effective license projection rather than mounting
that private key.
The admin and onboarding secret backend is selected by
`application.admin.secret-backend.type` in the platform config template (env
`EDK_SECRET_BACKEND`); choose a production backend before going live.

## Selecting a backend in Helm values

The chart accepts standard Kubernetes `env.valueFrom.secretKeyRef` entries under
each service's `env` list. This is the Kubernetes-native form and the most direct
way to bind a credential from a Secret already in the cluster.

```yaml
database:
  existingSecret: edk-postgres
  usernameKey: username
  passwordKey: password

services:
  tenant-as:
    env:
      - name: OAUTH2_SERVER_SIGNING_KEY_REF
        valueFrom:
          secretKeyRef:
            name: edk-as-signing
            key: key-ref
  issuer:
    env:
      - name: OID4VCI_ISSUER_SIGNING_KEY_REF
        valueFrom:
          secretKeyRef:
            name: edk-issuer-signing
            key: key-ref
  tenant-kms:
    env:
      - name: KMS_PROVIDER_CREDENTIALS_REF
        valueFrom:
          secretKeyRef:
            name: edk-kms-provider
            key: credentials-ref
```

This is the form in `examples/secret-backed-credentials-values.yaml`. The
database username and password always come from the Secret named in
`database.existingSecret`; the chart never renders a database password literal.

## Secrets as references

When the credential lives in an external secret system rather than a Kubernetes
Secret, set the environment variable to a reference string. The service resolves
the reference against the backend at runtime. The reference forms are:

Vault:

```yaml
services:
  kms:
    env:
      - name: KMS_PROVIDER_CREDENTIALS_REF
        value: "${secret:vault:kv/edk/kms:credentials}"
```

AWS Secrets Manager:

```yaml
services:
  issuer:
    env:
      - name: OID4VCI_ISSUER_SIGNING_KEY_REF
        value: "${secret:aws-secrets-manager:prod/edk/issuer:signing-key-ref}"
```

Azure Key Vault:

```yaml
services:
  as:
    env:
      - name: OAUTH2_SERVER_SIGNING_KEY_REF
        value: "${secret:azure-key-vault:edk-prod-vault:as-signing-key-ref}"
```

Kubernetes mounted secret:

```yaml
services:
  did:
    env:
      - name: DID_WEB_HOSTING_SECRET_REF
        value: "${secret:kubernetes-mount:/mnt/secrets/did:hosting-secret}"
```

The reference is `${secret:<backend>:<location>:<name>}`. The backend you name
must be reachable from the running service (network access, mounted credentials,
or platform identity, depending on the backend). The value the service reads is
the resolved secret, never the reference string itself.
