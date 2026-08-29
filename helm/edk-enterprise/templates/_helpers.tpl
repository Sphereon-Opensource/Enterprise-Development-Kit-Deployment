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

{{/*
Exact browser origins accepted by the public REST CORS policy. The platform
origin is always present; tenant wallet origins and optional docs origins are
merged without weakening the policy to a wildcard.
*/}}
{{- define "edk-enterprise.browserCorsOrigins" -}}
{{- $origins := list .Values.platform.externalBaseUrl -}}
{{- range (.Values.platform.corsOrigins | default (list)) -}}
{{- $origins = append $origins . -}}
{{- end -}}
{{- if .Values.docsPlayground.enabled -}}
{{- range (.Values.docsPlayground.origins | default (list)) -}}
{{- $origins = append $origins . -}}
{{- end -}}
{{- end -}}
{{- join "," (uniq $origins) -}}
{{- end -}}

{{- define "edk-enterprise.serviceName" -}}
{{- printf "%s-%s" (include "edk-enterprise.fullname" .root) .name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Identity-plane ClusterIP used before serving-ready. Tenant-KMS dials platform-identity; platform boot dials tenant-kms-identity. These Services publish not-ready addresses because kube Ready is /ready. */}}
{{- define "edk-enterprise.identityServiceName" -}}
{{- printf "%s-%s-identity" (include "edk-enterprise.fullname" .root) .name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
The chart has one deployment model. `topology.mode` changes only the process
composition: distributed exposes the individual logical workloads; monolith
hosts the same logical services in one application process. Shared deployment
settings remain under their existing value names.
*/}}
{{- define "edk-enterprise.topologyMode" -}}
{{- lower (default "distributed" .Values.topology.mode) -}}
{{- end -}}

{{- define "edk-enterprise.monolithServiceName" -}}
{{- printf "%s-monolith" (include "edk-enterprise.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Map a logical service target to the actual in-cluster backend. */}}
{{- define "edk-enterprise.logicalServiceName" -}}
{{- if eq (include "edk-enterprise.topologyMode" .root) "monolith" -}}
{{- include "edk-enterprise.monolithServiceName" .root -}}
{{- else -}}
{{- include "edk-enterprise.serviceName" . -}}
{{- end -}}
{{- end -}}

{{/*
Product-neutral service-identity catalog. Receiver audiences, gRPC receiver
flags, and NetworkPolicy peers are catalog-owned. Callers must pass the chart
root so Helm can load files/service-identity-catalog.yaml.
*/}}
{{- define "edk-enterprise.serviceIdentity.catalogYaml" -}}
{{- $raw := .Files.Get "files/service-identity-catalog.yaml" -}}
{{- if not $raw -}}
{{- fail "files/service-identity-catalog.yaml is missing from the chart" -}}
{{- end -}}
{{- $raw -}}
{{- end -}}

{{- define "edk-enterprise.serviceIdentity.role" -}}
{{- $role := .role | default .name -}}
{{- $catalog := include "edk-enterprise.serviceIdentity.catalogYaml" .root | fromYaml -}}
{{- $row := index $catalog.roles $role -}}
{{- if not $row -}}
{{- fail (printf "unknown service-identity role %q" $role) -}}
{{- end -}}
{{- toYaml $row -}}
{{- end -}}

{{- define "edk-enterprise.serviceIdentity.receiverAudience" -}}
{{- $role := .role | default .name -}}
{{- $row := include "edk-enterprise.serviceIdentity.role" . | fromYaml -}}
{{- required (printf "service-identity role %q has no receiverAudience" $role) $row.receiverAudience -}}
{{- end -}}

{{- define "edk-enterprise.serviceIdentity.grpcReceiver" -}}
{{- $row := include "edk-enterprise.serviceIdentity.role" . | fromYaml -}}
{{- if $row.grpcReceiver }}true{{ else }}false{{ end -}}
{{- end -}}

{{- define "edk-enterprise.serviceIdentity.defaultStsAudience" -}}
{{- $role := .role | default .name -}}
{{- $catalog := include "edk-enterprise.serviceIdentity.catalogYaml" .root | fromYaml -}}
{{- $row := index $catalog.roles $role -}}
{{- if not $row -}}
{{- fail (printf "unknown service-identity role %q" $role) -}}
{{- end -}}
{{- if $row.defaultStsAudience -}}
{{- $stsRow := index $catalog.roles $row.defaultStsAudience -}}
{{- required (printf "service-identity role %q defaultStsAudience %q is unknown" $role $row.defaultStsAudience) $stsRow.receiverAudience -}}
{{- else -}}
{{- $row.receiverAudience -}}
{{- end -}}
{{- end -}}

{{- define "edk-enterprise.serviceIdentity.extraStsAudiencesCsv" -}}
{{- $role := .role | default .name -}}
{{- $catalog := include "edk-enterprise.serviceIdentity.catalogYaml" .root | fromYaml -}}
{{- $row := index $catalog.roles $role -}}
{{- if not $row -}}
{{- fail (printf "unknown service-identity role %q" $role) -}}
{{- end -}}
{{- $audiences := list -}}
{{- range ($row.extraStsAudiences | default list) -}}
{{- $extra := index $catalog.roles . -}}
{{- if not $extra -}}
{{- fail (printf "service-identity role %q extraStsAudiences entry %q is unknown" $role .) -}}
{{- end -}}
{{- $audiences = append $audiences (required (printf "service-identity extra STS role %q has no receiverAudience" .) $extra.receiverAudience) -}}
{{- end -}}
{{- join "," $audiences -}}
{{- end -}}

{{- define "edk-enterprise.serviceIdentity.clientSecretEnvName" -}}
{{- printf "EDK_INTERNAL_CLIENT_SECRET_%s" (upper (replace "-" "_" .)) -}}
{{- end -}}

{{- define "edk-enterprise.serviceIdentity.clientSecretEnvInterpolation" -}}
${env:{{ include "edk-enterprise.serviceIdentity.clientSecretEnvName" . }}}
{{- end -}}

{{- define "edk-enterprise.serviceIdentity.clientSecretKey" -}}
{{- $keys := .root.Values.serviceIdentity.clientSecretKeys | default dict -}}
{{- $key := trim (toString (default "" (index $keys .role))) -}}
{{- if eq $key "" -}}
{{- fail (printf "serviceIdentity.clientSecretKeys.%s is required when the %s client is enabled. Set a distinct Kubernetes Secret key per satellite client; serviceIdentity.internalClientSecretKey is no longer supported." .role .role) -}}
{{- end -}}
{{- $key -}}
{{- end -}}

{{- define "edk-enterprise.serviceIdentity.roleNeedsClientSecret" -}}
{{- $catalog := include "edk-enterprise.serviceIdentity.catalogYaml" .root | fromYaml -}}
{{- $row := index $catalog.roles .role -}}
{{- if and $row $row.clientId -}}
{{- if eq $row.kind "satellite" -}}
{{- $svc := index .root.Values.services .role -}}
{{- if and $svc $svc.enabled }}true{{ else }}false{{ end -}}
{{- else if eq $row.kind "auxiliary-client" -}}
{{- if (index .root.Values.services "tenant-as").enabled }}true{{ else }}false{{ end -}}
{{- else }}false{{ end -}}
{{- else }}false{{ end -}}
{{- end -}}

{{- define "edk-enterprise.serviceIdentity.platformClientSecretEnv" -}}
{{- $catalog := include "edk-enterprise.serviceIdentity.catalogYaml" . | fromYaml -}}
{{- $envs := list -}}
{{- $secret := .Values.serviceIdentity.internalClientExistingSecret -}}
{{- range $role, $row := $catalog.roles -}}
{{- if eq (include "edk-enterprise.serviceIdentity.roleNeedsClientSecret" (dict "root" $ "role" $role)) "true" -}}
{{- $key := include "edk-enterprise.serviceIdentity.clientSecretKey" (dict "root" $ "role" $role) -}}
{{- $envs = append $envs (dict "name" (include "edk-enterprise.serviceIdentity.clientSecretEnvName" $role) "valueFrom" (dict "secretKeyRef" (dict "name" $secret "key" $key))) -}}
{{- end -}}
{{- end -}}
{{- if $envs -}}
{{- toYaml $envs -}}
{{- end -}}
{{- end -}}

{{/*
Thin wrapper over catalog receiverAudience. Requires dict root+name (or role).
*/}}
{{- define "edk-enterprise.serviceAudience" -}}
{{- if kindIs "string" . -}}
{{- fail (printf "edk-enterprise.serviceAudience requires dict root+name; got string %q" .) -}}
{{- end -}}
{{- include "edk-enterprise.serviceIdentity.receiverAudience" (dict "root" .root "role" (.name | default .role)) -}}
{{- end -}}

{{- define "edk-enterprise.validateServiceIdentityCatalog" -}}
{{- $catalog := include "edk-enterprise.serviceIdentity.catalogYaml" . | fromYaml -}}
{{- if not $catalog.roles -}}
{{- fail "service-identity catalog has no roles" -}}
{{- end -}}
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

{{- /*
Platform AS WebAuthn policy. Keep this topology-neutral: both the distributed
platform ConfigMap and the monolith container profile use this exact policy,
derived from the one customer-facing platform origin.
*/ -}}
{{- define "edk-enterprise.platformWebAuthnConfig" -}}
webauthn:
  enabled: true
  rp-id: {{ printf "%s.%s" .Values.gateway.operatorHost (include "edk-enterprise.gateway.baseDomain" .) | quote }}
  allowed-origins: {{ .Values.platform.externalBaseUrl | quote }}
  attestation-policy: none
  user-verification: required
  allowed-transports: "internal,hybrid"
  backup-state-policy: allow-any
  challenge-ttl-seconds: 300
  level3-prf-enabled: false
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
{{- else if eq $name "blob" -}}
- /api/theme/v1
- /api/assets/v1
{{- else if eq $name "tenant-as" -}}
- /as
- /authorize
- /par
- /token
- /userinfo
- /oauth2
- /login
- /logout
- /account-action
- /api/account-actions
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
{{- else if eq $name "business-wallet" -}}
- /wallets
- /_next
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

{{/* Fail closed on unknown gRPC auth aliases, insecure none, or mtls without certs. */}}
{{- define "edk-enterprise.validateGrpcAuthMode" -}}
{{- $mode := lower (trim (toString (default "" .Values.grpc.authMode))) -}}
{{- $allowNone := .Values.grpc.allowInsecureNone | default false -}}
{{- if eq $mode "none" -}}
{{- if not $allowNone -}}
{{- fail "grpc.authMode=none requires grpc.allowInsecureNone=true" -}}
{{- end -}}
{{- else if not (has $mode (list "service-jwt" "mtls" "mesh-mtls")) -}}
{{- fail (printf "grpc.authMode must be one of service-jwt, mtls, mesh-mtls (or none with grpc.allowInsecureNone=true); got %q." .Values.grpc.authMode) -}}
{{- end -}}
{{- if eq $mode "mtls" -}}
{{- $tls := default dict .Values.grpc.tls -}}
{{- $cert := trim (toString (default "" $tls.cert)) -}}
{{- $key := trim (toString (default "" $tls.key)) -}}
{{- $ca := trim (toString (default "" $tls.clientCa)) -}}
{{- if or (eq $cert "") (eq $key "") (eq $ca "") -}}
{{- fail "grpc.authMode=mtls requires grpc.tls.cert, grpc.tls.key, and grpc.tls.clientCa" -}}
{{- end -}}
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
{{- $mode := include "edk-enterprise.topologyMode" . -}}
{{- $satelliteEnabled := and (eq $mode "distributed") (or (index .Values.services "tenant-kms").enabled .Values.services.did.enabled .Values.services.blob.enabled (index .Values.services "tenant-as").enabled (index .Values.services "wallet-unit").enabled (index .Values.services "wallet-interaction").enabled .Values.services.issuer.enabled .Values.services.verifier.enabled) -}}
{{- $identitySecret := trim (default "" .Values.serviceIdentity.internalClientExistingSecret) -}}
{{- $keystoreSecret := trim (default "" .Values.keystore.existingSecret) -}}
{{- $portalBffSecret := trim (default "" .Values.portalBff.existingSecret) -}}
{{- $issuerPipelineSecret := trim (default "" .Values.issuerPipeline.existingSecret) -}}
{{- $federationSessionSecret := trim (default "" .Values.federationSessionEncryption.existingSecret) -}}
{{- $tenantAsEnabled := index .Values.services "tenant-as" -}}
{{- if hasKey .Values.serviceIdentity "internalClientSecretKey" -}}
{{- fail "serviceIdentity.internalClientSecretKey is no longer supported. Set serviceIdentity.clientSecretKeys.<role> to a distinct Kubernetes Secret key for each satellite client." -}}
{{- end -}}
{{- if and $satelliteEnabled (eq $identitySecret "") -}}
{{- fail "serviceIdentity.internalClientExistingSecret is required when an EDK satellite service is enabled. Create a Kubernetes Secret (for example edk-runtime-secrets) containing the distinct keys in serviceIdentity.clientSecretKeys, then reference that Secret by name." -}}
{{- end -}}
{{- $catalog := include "edk-enterprise.serviceIdentity.catalogYaml" . | fromYaml -}}
{{- $usedSecretKeys := dict -}}
{{- range $role, $row := $catalog.roles -}}
{{- if eq (include "edk-enterprise.serviceIdentity.roleNeedsClientSecret" (dict "root" $ "role" $role)) "true" -}}
{{- $key := include "edk-enterprise.serviceIdentity.clientSecretKey" (dict "root" $ "role" $role) -}}
{{- if hasKey $usedSecretKeys $key -}}
{{- fail (printf "serviceIdentity.clientSecretKeys values must be distinct; %s and %s both use %s" (index $usedSecretKeys $key) $role $key) -}}
{{- end -}}
{{- $_ := set $usedSecretKeys $key $role -}}
{{- end -}}
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
{{- if and (or (eq $mode "monolith") (and $tenantAsEnabled $tenantAsEnabled.enabled)) (eq $federationSessionSecret "") -}}
{{- fail "federationSessionEncryption.existingSecret is required when the monolith or tenant-as service is enabled. Create a Kubernetes Secret containing an independent 32-byte standard base64 value under federationSessionEncryption.key, then reference that Secret by name." -}}
{{- end -}}
{{- if eq .Values.portalBff.kms.encryptionKeyAlias .Values.portalBff.kms.handleHmacKeyAlias -}}
{{- fail "portalBff.kms.encryptionKeyAlias and portalBff.kms.handleHmacKeyAlias must be distinct." -}}
{{- end -}}
{{- $secretWorkloads := list "platform" -}}
{{- if eq $mode "distributed" -}}
{{- $secretWorkloads = list "platform" "tenant-kms" "tenant-as" "did" "blob" "issuer" "verifier" "wallet-unit" "wallet-interaction" -}}
{{- end -}}
{{- range $name := $secretWorkloads -}}
{{- $service := index $.Values.services $name -}}
{{- if and $service.enabled (eq (trim (default "" (index $.Values.secretAuthority.existingSecrets $name))) "") -}}
{{- fail (printf "secretAuthority.existingSecrets.%s is required when services.%s.enabled=true; reference a workload-isolated Secret containing the configured secret-authority coordinates and key files." $name $name) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "edk-enterprise.validateTopology" -}}
{{- $mode := include "edk-enterprise.topologyMode" . -}}
{{- if not (has $mode (list "distributed" "monolith")) -}}
{{- fail (printf "topology.mode must be distributed or monolith (got %q)" $mode) -}}
{{- end -}}
{{- end -}}

{{/*
Email is optional in either topology. When present, render one shared account
configuration into the application process that owns EmailService. SMTP secrets
remain resource-bound secret-management data and never become Helm values.
*/}}
{{- define "edk-enterprise.validateEmail" -}}
{{- if .Values.email.enabled -}}
{{- $account := index .Values.email.accounts "default" -}}
{{- if ne $account.transportId "smtp" -}}
{{- fail "email.accounts.default.transportId must be smtp; the chart's deployment account renderer supports SMTP only" -}}
{{- end -}}
{{- if eq (trim $account.fromAddress) "" -}}
{{- fail "email.accounts.default.fromAddress is required when email.enabled=true" -}}
{{- end -}}
{{- if eq (trim $account.smtp.host) "" -}}
{{- fail "email.accounts.default.smtp.host is required when email.enabled=true" -}}
{{- end -}}
{{- if and $account.smtp.useStarttls $account.smtp.useSsl -}}
{{- fail "email.accounts.default.smtp.useStarttls and useSsl cannot both be true" -}}
{{- end -}}
{{- if and (ne (trim $account.smtp.username) "") (not (or $account.smtp.useStarttls $account.smtp.useSsl)) -}}
{{- fail "authenticated SMTP requires email.accounts.default.smtp.useStarttls or useSsl" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "edk-enterprise.emailEnv" -}}
{{- if .Values.email.enabled -}}
{{- $account := index .Values.email.accounts "default" -}}
- name: VDX_SERVICE_EMAIL_ROUTING_DEFAULT_ACCOUNT_ID
  value: {{ .Values.email.routing.defaultAccountId | quote }}
- name: VDX_SERVICE_EMAIL_ACCOUNTS_DEFAULT_TRANSPORT_ID
  value: {{ $account.transportId | quote }}
- name: VDX_SERVICE_EMAIL_ACCOUNTS_DEFAULT_FROM_ADDRESS
  value: {{ $account.fromAddress | quote }}
{{- with $account.fromName }}
- name: VDX_SERVICE_EMAIL_ACCOUNTS_DEFAULT_FROM_NAME
  value: {{ . | quote }}
{{- end }}
{{- with $account.replyTo }}
- name: VDX_SERVICE_EMAIL_ACCOUNTS_DEFAULT_REPLY_TO
  value: {{ . | quote }}
{{- end }}
- name: VDX_SERVICE_EMAIL_ACCOUNTS_DEFAULT_SMTP_HOST
  value: {{ $account.smtp.host | quote }}
- name: VDX_SERVICE_EMAIL_ACCOUNTS_DEFAULT_SMTP_PORT
  value: {{ $account.smtp.port | quote }}
{{- with $account.smtp.username }}
- name: VDX_SERVICE_EMAIL_ACCOUNTS_DEFAULT_SMTP_USERNAME
  value: {{ . | quote }}
{{- end }}
- name: VDX_SERVICE_EMAIL_ACCOUNTS_DEFAULT_SMTP_USE_STARTTLS
  value: {{ $account.smtp.useStarttls | quote }}
- name: VDX_SERVICE_EMAIL_ACCOUNTS_DEFAULT_SMTP_USE_SSL
  value: {{ $account.smtp.useSsl | quote }}
- name: VDX_SERVICE_EMAIL_ACCOUNTS_DEFAULT_SMTP_CONNECTION_TIMEOUT_MS
  value: {{ $account.smtp.connectionTimeoutMs | quote }}
- name: VDX_SERVICE_EMAIL_ACCOUNTS_DEFAULT_SMTP_READ_TIMEOUT_MS
  value: {{ $account.smtp.readTimeoutMs | quote }}
{{- with .Values.email.allowedPrivateDestinations }}
- name: VDX_SERVICE_EMAIL_SMTP_ALLOWED_PRIVATE_DESTINATIONS
  value: {{ . | quote }}
{{- end }}
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
    allowed-clock-skew-millis: 5000
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
    # The platform barrier owns DDL and authority persistence. Satellites receive
    # only the tenant-serving runtime role for their local persistence.
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
    secret-management-runtime:
      dialect: {{ .Values.database.dialect }}
      isolation: shared
      host: {{ $tenantDb.host }}
      port: {{ $tenantDb.port }}
      database: {{ $tenantDb.name }}
      username: secret_management_runtime
      password: ${env:EDK_SECRET_MANAGEMENT_RUNTIME_DB_PASSWORD}
      pool:
        dedicated-pool: true
{{- end -}}

{{/* Platform-owned command families every satellite resolves over gRPC. */}}
{{- define "edk-enterprise.remotePlatformRoutingModules" -}}
platform:
  target: SERVER
  transport: GRPC
  endpoint: {{ printf "grpc://%s:%v" (include "edk-enterprise.serviceName" (dict "root" . "name" "platform")) .Values.grpc.port | quote }}
  serviceTokenAudience: {{ include "edk-enterprise.serviceAudience" (dict "root" . "name" "platform") | quote }}
  services:
    config:
      target: SERVER
      transport: GRPC
      endpoint: {{ printf "grpc://%s:%v" (include "edk-enterprise.serviceName" (dict "root" . "name" "platform")) .Values.grpc.port | quote }}
      serviceTokenAudience: {{ include "edk-enterprise.serviceAudience" (dict "root" . "name" "platform") | quote }}
application:
  target: SERVER
  transport: GRPC
  endpoint: {{ printf "grpc://%s:%v" (include "edk-enterprise.serviceName" (dict "root" . "name" "platform")) .Values.grpc.port | quote }}
  serviceTokenAudience: {{ include "edk-enterprise.serviceAudience" (dict "root" . "name" "platform") | quote }}
{{- end -}}

{{/* The platform is both the central permit issuer and a satellite consumer. */}}
{{- define "edk-enterprise.secretAuthorityPlatformConfig" -}}
sphereon:
  service:
    id: service-platform
secret:
  authority:
    allowed-clock-skew-millis: 5000
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
{{- if eq (include "edk-enterprise.topologyMode" .) "distributed" -}}
{{- $kmsConsumerEnabled := or .Values.services.did.enabled (index .Values.services "tenant-as").enabled .Values.services.issuer.enabled .Values.services.verifier.enabled -}}
{{- if and $kmsConsumerEnabled (not (index .Values.services "tenant-kms").enabled) -}}
{{- fail "services.tenant-kms.enabled must be true while did, tenant-as, issuer, or verifier is enabled: these route-only services send tenant key operations to the in-chart tenant-kms service." -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Validate the service graph represented by the service-specific routes. */}}
{{- define "edk-enterprise.validateRuntimeDependencies" -}}
{{- if eq (include "edk-enterprise.topologyMode" .) "distributed" -}}
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
{{- end -}}
