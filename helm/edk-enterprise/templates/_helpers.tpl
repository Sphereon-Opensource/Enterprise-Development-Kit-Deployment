{{- define "edk-enterprise.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "edk-enterprise.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "edk-enterprise.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "edk-enterprise.serviceName" -}}
{{- printf "%s-%s" (include "edk-enterprise.fullname" .root) .name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
East-west JWT audiences are protocol identifiers shared with source-level STS
and tenant-registration contracts. They are intentionally not chart values:
changing one side would make otherwise valid tokens unusable at another
receiver.
*/}}
{{- define "edk-enterprise.serviceAudience" -}}
{{- $audiences := dict
    "platform" "enterprise-platform"
    "tenant-kms" "enterprise-tenant-kms"
    "tenant-as" "enterprise-tenant-as"
    "did" "enterprise-tenant-did"
    "issuer" "enterprise-issuer"
    "verifier" "enterprise-verifier"
    "wallet-unit" "enterprise-wallet-unit"
    "wallet-interaction" "enterprise-wallet-interaction"
-}}
{{- required (printf "unsupported service audience role %q" .) (index $audiences .) -}}
{{- end -}}

{{- define "edk-enterprise.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "edk-enterprise.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "edk-enterprise.selectorLabels" -}}
app.kubernetes.io/name: {{ include "edk-enterprise.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .name }}
{{- end -}}

{{- define "edk-enterprise.gateway.baseDomain" -}}
{{- $globalBase := required "global.platformBaseDomain is required; set it explicitly for every installation" .Values.global.platformBaseDomain -}}
{{- $base := .Values.gateway.baseDomain | default $globalBase -}}
{{- $base -}}
{{- end -}}

{{/*
Tenant-host path-prefix routing table per service, mirroring the single-port
gateway contract. Returns a YAML list of path prefixes for the given service
name, or an empty list for services that are not tenant-routed.
*/}}
{{- define "edk-enterprise.gateway.tenantPaths" -}}
{{- $name := .name -}}
{{- if eq $name "issuer" -}}
- /oid4vci
- /credential
- /deferredCredential
- /nonce
- /notification
- /public/statuslists
- /public/schema
- /public/assets
- /.well-known/openid-credential-issuer
- /api/oid4vci/v1
- /api/credential-design/v1
- /api/statuslist/v1
{{- else if eq $name "verifier" -}}
- /oid4vp
- /request_uri
- /direct_post
- /api/oid4vp/v1
- /api/dcql/v1
{{- else if eq $name "tenant-kms" -}}
{{/* The runtime KMS API is advertised on the TENANT origin by the bootstrap
     runtime-config (tenantKms.endpoints.api = /api/kms/v1), so the tenant host
     must route it. Tenant scoping comes from the bearer, not the host, which is
     why the Compose gateway routes this path on any host at a priority above the
     platform catch-all. */}}
- /api/kms/v1
{{- else if eq $name "did" -}}
- /1.0/identifiers
- /.well-known/did.json
- /api/did/v1
{{- else if eq $name "tenant-as" -}}
- /authorize
- /par
- /token
- /userinfo
- /oauth2
- /login
- /logout
- /api/trust-domain/v1
- /.well-known/oauth-authorization-server
- /.well-known/openid-configuration
- /.well-known/jwks.json
{{- else if eq $name "admin-console-tenant" -}}
{{/* Direct public testing-console support paths on the tenant-mode runtime. */}}
- /admin-console/api/oid4vci/v1/testing
- /admin-console/api/oid4vp/v1/testing
- /admin-console/_next
- /admin-console/public/assets
{{- end -}}
{{- end -}}

{{- define "edk-enterprise.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "edk-enterprise.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "edk-enterprise.platformServiceAccountName" -}}
{{- if .Values.serviceAccount.platform.create -}}
{{- default (printf "%s-platform" (include "edk-enterprise.fullname" .)) .Values.serviceAccount.platform.name -}}
{{- else -}}
{{- required "serviceAccount.platform.name is required when serviceAccount.platform.create=false" .Values.serviceAccount.platform.name -}}
{{- end -}}
{{- end -}}

{{- define "edk-enterprise.validateImageRegistry" -}}
{{- $registry := trimSuffix "/" (lower (default "" .Values.global.imageRegistry)) -}}
{{- if or (eq $registry "sphereon") (hasPrefix "sphereon/" $registry) (regexMatch "^(docker\\.io|index\\.docker\\.io|registry-1\\.docker\\.io)(/|$)" $registry) -}}
{{- fail "global.imageRegistry must not point at public Docker Hub. Use nexus.sphereon.com/edk-docker for EDK enterprise images." -}}
{{- end -}}
{{- if eq $registry "nexus.sphereon.com" -}}
{{- fail "global.imageRegistry must include the EDK Docker repository. Use nexus.sphereon.com/edk-docker, not host-only nexus.sphereon.com." -}}
{{- end -}}
{{- end -}}

{{/*
Reject unsafe `latest` settings that can leave old enterprise images running
after a Helm upgrade. Production releases must use a versioned tag. Development
may use `latest`, but only with an Always pull policy.
*/}}
{{- define "edk-enterprise.validateImageReference" -}}
{{- $tag := lower (default .Chart.AppVersion .Values.global.imageTag) -}}
{{- $pullPolicy := lower (default "IfNotPresent" .Values.global.imagePullPolicy) -}}
{{- $deploymentMode := lower (default "dev" .Values.platform.bootstrap.deploymentMode) -}}
{{- if and (eq $tag "latest") (eq $deploymentMode "prod") -}}
{{- fail "global.imageTag=latest is not allowed when platform.bootstrap.deploymentMode=prod. Pin the approved enterprise release tag supplied through your EDK distribution channel." -}}
{{- end -}}
{{- if and (eq $tag "latest") (ne $pullPolicy "always") -}}
{{- fail "global.imageTag=latest requires global.imagePullPolicy=Always for non-production testing; preferably pin the approved enterprise release tag supplied through your EDK distribution channel." -}}
{{- end -}}
{{- end -}}

{{/* Validate the selected Gateway API TLS termination mode and its required inputs. */}}
{{- define "edk-enterprise.validateGatewayTls" -}}
{{- if .Values.gateway.enabled -}}
{{- $mode := .Values.gateway.tls.mode -}}
{{- if not (has $mode (list "secret" "certManager" "external")) -}}
{{- fail (printf "gateway.tls.mode must be one of secret, certManager, external (got %q)." $mode) -}}
{{- end -}}
{{- if and (eq $mode "secret") (eq (trim (default "" .Values.gateway.tls.secretName)) "") -}}
{{- fail "gateway.tls.mode=secret requires gateway.tls.secretName to reference an existing wildcard TLS Secret." -}}
{{- end -}}
{{- if and (eq $mode "certManager") (eq (trim (default "" .Values.gateway.tls.clusterIssuer)) "") -}}
{{- fail "gateway.tls.mode=certManager requires gateway.tls.clusterIssuer." -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
The chart does not generate runtime credentials. Requiring existing Secret
references here prevents otherwise healthy-looking pods from starting without
east-west Authorization headers or software-keystore access.
*/}}
{{- define "edk-enterprise.validateRuntimeSecrets" -}}
{{- $satelliteEnabled := or (index .Values.services "tenant-kms").enabled .Values.services.did.enabled (index .Values.services "tenant-as").enabled (index .Values.services "wallet-unit").enabled (index .Values.services "wallet-interaction").enabled .Values.services.issuer.enabled .Values.services.verifier.enabled -}}
{{- $identitySecret := trim (default "" .Values.serviceIdentity.internalClientExistingSecret) -}}
{{- $keystoreSecret := trim (default "" .Values.keystore.existingSecret) -}}
{{- $portalBffSecret := trim (default "" .Values.portalBff.existingSecret) -}}
{{- $issuerPipelineSecret := trim (default "" .Values.issuerPipeline.existingSecret) -}}
{{- if and $satelliteEnabled (eq $identitySecret "") -}}
{{- fail "serviceIdentity.internalClientExistingSecret is required when an EDK satellite service is enabled. Create a Kubernetes Secret (for example edk-runtime-secrets) containing the key configured by serviceIdentity.internalClientSecretKey (default: internal-client-secret), then reference that Secret by name." -}}
{{- end -}}
{{- if and (or .Values.services.platform.enabled (index .Values.services "tenant-kms").enabled) (eq $keystoreSecret "") -}}
{{- fail "keystore.existingSecret is required when platform or tenant-kms is enabled. Create a Kubernetes Secret (for example edk-runtime-secrets) containing the key configured by keystore.passwordKey (default: keystore-password), then reference that Secret by name." -}}
{{- end -}}
{{- if and .Values.services.platform.enabled (index .Values.services "admin-console").enabled (eq $portalBffSecret "") -}}
{{- fail "portalBff.existingSecret is required when platform and admin-console are enabled. Create a Kubernetes Secret containing the key configured by portalBff.clientSecretKey, then reference that Secret by name." -}}
{{- end -}}
{{- if and .Values.services.issuer.enabled (eq $issuerPipelineSecret "") -}}
{{- fail "issuerPipeline.existingSecret is required when the issuer service is enabled. Create a Kubernetes Secret containing independent 32-byte base64url values under issuerPipeline.masterKekKey and issuerPipeline.blindIndexKey, then reference that Secret by name." -}}
{{- end -}}
{{- if eq .Values.issuerPipeline.masterKekKey .Values.issuerPipeline.blindIndexKey -}}
{{- fail "issuerPipeline.masterKekKey and issuerPipeline.blindIndexKey must be distinct Secret keys." -}}
{{- end -}}
{{- if eq .Values.portalBff.kms.encryptionKeyAlias .Values.portalBff.kms.handleHmacKeyAlias -}}
{{- fail "portalBff.kms.encryptionKeyAlias and portalBff.kms.handleHmacKeyAlias must be distinct." -}}
{{- end -}}
{{- range $name := list "platform" "tenant-kms" "tenant-as" "did" "issuer" "verifier" "wallet-unit" "wallet-interaction" -}}
{{- $service := index $.Values.services $name -}}
{{- if and $service.enabled (eq (trim (default "" (index $.Values.secretAuthority.existingSecrets $name))) "") -}}
{{- fail (printf "secretAuthority.existingSecrets.%s is required when services.%s.enabled=true; reference a workload-isolated Secret containing the configured secret-authority coordinates and key files." $name $name) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Runtime configuration shared by every secret-consuming satellite. */}}
{{- define "edk-enterprise.secretAuthoritySatelliteConfig" -}}
# The local service identity is cryptographically bound into the execution
# assertion and must equal secret.authority.satellite.workload-id.
sphereon:
  service:
    id: {{ .workloadId | quote }}
secret:
  authority:
    allowed-clock-skew-millis: 2000
    satellite:
      workload-id: {{ .workloadId | quote }}
      workload-hosting-revision: 1
      assertion:
        issuer: sphereon-secret-workload
        audience: enterprise-platform
        ttl-millis: 30000
        signing-key: ${env:SECRET_AUTHORITY_SATELLITE_ASSERTION_SIGNING_KEY}
      permit:
        issuer: enterprise-platform
        audience: sphereon-secret-use
        verification-keys: ${env:SECRET_AUTHORITY_SATELLITE_PERMIT_VERIFICATION_KEYS}
{{- end -}}

{{/* Fixed runtime pools used by every tenant workload's local secret broker. */}}
{{- define "edk-enterprise.secretManagementSatelliteDatabaseConfig" -}}
{{- $tenantDb := .Values.database.tenant -}}
database:
  app:
    # The platform barrier owns DDL; satellites receive runtime roles only.
    secret-management-admin:
      dialect: {{ .Values.database.dialect }}
      isolation: shared
      host: {{ $tenantDb.host }}
      port: {{ $tenantDb.port }}
      database: {{ $tenantDb.name }}
      username: secret_management_admin
      password: ${env:EDK_SECRET_MANAGEMENT_ADMIN_DB_PASSWORD}
      pool:
        dedicated-pool: true
    secret-management-tenant:
      dialect: {{ .Values.database.dialect }}
      isolation: shared
      host: {{ $tenantDb.host }}
      port: {{ $tenantDb.port }}
      database: {{ $tenantDb.name }}
      username: secret_management_tenant_serving
      password: ${env:EDK_SECRET_MANAGEMENT_TENANT_DB_PASSWORD}
      pool:
        dedicated-pool: true
{{- end -}}

{{/* Platform-owned command families every satellite resolves over gRPC. */}}
{{- define "edk-enterprise.remotePlatformRoutingModules" -}}
platform:
  target: SERVER
  transport: GRPC
  endpoint: {{ printf "grpc://%s:%v" (include "edk-enterprise.serviceName" (dict "root" . "name" "platform")) .Values.grpc.port | quote }}
  serviceTokenAudience: {{ include "edk-enterprise.serviceAudience" "platform" | quote }}
  services:
    config:
      target: SERVER
      transport: GRPC
      endpoint: {{ printf "grpc://%s:%v" (include "edk-enterprise.serviceName" (dict "root" . "name" "platform")) .Values.grpc.port | quote }}
      serviceTokenAudience: {{ include "edk-enterprise.serviceAudience" "platform" | quote }}
application:
  target: SERVER
  transport: GRPC
  endpoint: {{ printf "grpc://%s:%v" (include "edk-enterprise.serviceName" (dict "root" . "name" "platform")) .Values.grpc.port | quote }}
  serviceTokenAudience: {{ include "edk-enterprise.serviceAudience" "platform" | quote }}
{{- end -}}

{{/* The platform is both the central permit issuer and a satellite consumer. */}}
{{- define "edk-enterprise.secretAuthorityPlatformConfig" -}}
sphereon:
  service:
    id: service-platform
secret:
  authority:
    allowed-clock-skew-millis: 2000
    central:
      permit:
        issuer: enterprise-platform
        audience: sphereon-secret-use
        signing-key: ${env:SECRET_AUTHORITY_CENTRAL_PERMIT_SIGNING_KEY}
      assertion:
        issuer: sphereon-secret-workload
        audience: enterprise-platform
        verification-keys: ${env:SECRET_AUTHORITY_CENTRAL_ASSERTION_VERIFICATION_KEYS}
    satellite:
      workload-id: service-platform
      workload-hosting-revision: 1
      assertion:
        issuer: sphereon-secret-workload
        audience: enterprise-platform
        ttl-millis: 30000
        signing-key: ${env:SECRET_AUTHORITY_SATELLITE_ASSERTION_SIGNING_KEY}
      permit:
        issuer: enterprise-platform
        audience: sphereon-secret-use
        verification-keys: ${env:SECRET_AUTHORITY_SATELLITE_PERMIT_VERIFICATION_KEYS}
{{- end -}}

{{/*
Route-only services have no local tenant keystore. The chart has no external
tenant-KMS target override, so rendering those services without tenant-kms
would create endpoints that can never provision or use tenant keys.
*/}}
{{- define "edk-enterprise.validateTenantKmsDependency" -}}
{{- $kmsConsumerEnabled := or .Values.services.did.enabled (index .Values.services "tenant-as").enabled .Values.services.issuer.enabled .Values.services.verifier.enabled -}}
{{- if and $kmsConsumerEnabled (not (index .Values.services "tenant-kms").enabled) -}}
{{- fail "services.tenant-kms.enabled must be true while did, tenant-as, issuer, or verifier is enabled: these route-only services send tenant key operations to the in-chart tenant-kms service." -}}
{{- end -}}
{{- end -}}

{{/* Validate the service graph represented by the service-specific routes. */}}
{{- define "edk-enterprise.validateRuntimeDependencies" -}}
{{- if and .Values.services.issuer.enabled (not (index .Values.services "tenant-as").enabled) -}}
{{- fail "services.tenant-as.enabled must be true while issuer is enabled: the issuer routes OAuth2 commands to tenant-as." -}}
{{- end -}}
{{- if and .Values.services.verifier.enabled (not .Values.services.did.enabled) -}}
{{- fail "services.did.enabled must be true while verifier is enabled: the verifier routes DID resolution commands to did." -}}
{{- end -}}
{{- if and (index .Values.services "wallet-interaction").enabled (not (index .Values.services "wallet-unit").enabled) -}}
{{- fail "services.wallet-unit.enabled must be true while wallet-interaction is enabled: wallet interaction routes HSM policy authorization to wallet-unit." -}}
{{- end -}}
{{- end -}}
