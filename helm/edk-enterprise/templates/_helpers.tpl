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
{{- $base := .Values.gateway.baseDomain | default .Values.global.platformBaseDomain -}}
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
{{- else if eq $name "did" -}}
- /1.0/identifiers
- /.well-known/did.json
- /api/did/v1
{{- else if eq $name "tenant-kms" -}}
- /api/kms/v1
{{- else if eq $name "tenant-as" -}}
- /authorize
- /token
- /userinfo
- /oauth2
- /login
- /.well-known/oauth-authorization-server
- /.well-known/openid-configuration
- /.well-known/jwks.json
{{- else if eq $name "admin-console" -}}
{{/* Direct same-origin BFF/static support paths for the public testing console. */}}
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

{{/*
The Gateway TLS mode is a three-way switch and a typo would silently render a
broken listener set, so validate it. secret and certManager need an in-cluster
certificate reference; external explicitly must not carry one.
*/}}
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
{{- if and (eq (lower .Values.platform.bootstrap.deploymentMode) "prod") (eq (lower .Values.platform.secretBackend.type) "config-system-dev-only") -}}
{{- fail "platform.secretBackend.type=config-system-dev-only is not allowed when platform.bootstrap.deploymentMode=prod. Configure the installation's durable secret backend." -}}
{{- end -}}
{{- if eq .Values.portalBff.kms.encryptionKeyAlias .Values.portalBff.kms.handleHmacKeyAlias -}}
{{- fail "portalBff.kms.encryptionKeyAlias and portalBff.kms.handleHmacKeyAlias must be distinct." -}}
{{- end -}}
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
{{- if and (or .Values.services.issuer.enabled .Values.services.verifier.enabled) (not (index .Values.services "wallet-interaction").enabled) -}}
{{- fail "services.wallet-interaction.enabled must be true while issuer or verifier is enabled: both route wallet interaction commands to that service." -}}
{{- end -}}
{{- if and (index .Values.services "wallet-interaction").enabled (not (index .Values.services "wallet-unit").enabled) -}}
{{- fail "services.wallet-unit.enabled must be true while wallet-interaction is enabled: wallet interaction routes HSM policy authorization to wallet-unit." -}}
{{- end -}}
{{- end -}}
