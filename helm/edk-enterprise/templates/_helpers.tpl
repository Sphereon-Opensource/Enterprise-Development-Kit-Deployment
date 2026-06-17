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
- /credential_deferred
- /nonce
- /notification
- /public/statuslists
- /.well-known/openid-credential-issuer
- /api/oid4vci/v1
- /api/credential-design/v1
- /api/statuslist/v1
{{- else if eq $name "verifier" -}}
- /oid4vp
- /request_uri
- /direct_post
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
{{/* FUTURE tenant-host console prefix; only consumed when enableTenantConsole. */}}
- /admin-console
{{- end -}}
{{- end -}}

{{- define "edk-enterprise.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "edk-enterprise.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}
