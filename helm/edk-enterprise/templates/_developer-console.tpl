{{/* Explicit backend REST prefixes; protocol and wallet paths never grant catalog exposure.
Keep these in sync with gateway.tenantPaths and the additional tenant HTTPRoutes.
Only deployed, gateway-enabled services contribute. Audiences come from the identity catalog. */}}
{{- define "edk-enterprise.developerConsoleGatewayServices" -}}
{{- $root := . -}}
{{- $entries := list -}}
{{- $roles := (.Files.Get "files/service-identity-catalog.yaml" | fromYaml).roles -}}
{{- $prefixes := dict
  "platform" (list "/api/platform/config/v1/tenants" "/api/trust-domain/v1" "/api/audit/v1" "/api/forms/v1" "/api/workflow/v1" "/api/lifecycle/v1" "/api/services/v1" "/api/v1/config" "/api/invitation/v1/invitations")
  "tenant-kms" (list "/api/kms/v1")
  "did" (list "/api/did/v1" "/1.0/identifiers")
  "blob" (list "/api/theme/v1" "/api/assets/v1" "/api/connector/v1" "/api/blob-store/v1" "/api/users/v1" "/api/v1/schemas" "/api/v1/tabular-mapping-templates")
  "tenant-as" (list "/api/identity/v1" "/api/identity-auth/v1/admin" "/api/party/v1" "/api/account-actions")
  "issuer" (list "/api/oid4vci/v1" "/api/credential-design/v1" "/api/statuslist/v1" "/api/catalog/v1" "/public/schema" "/public/statuslists")
  "verifier" (list "/api/oid4vp/v1" "/api/dcql/v1" "/oid4vp/backend")
-}}
{{- if .Values.gateway.enabled -}}
{{- if eq (include "edk-enterprise.topologyMode" .) "monolith" -}}
{{- /* The monolith mounts the additional modules in services/service-monolith/build.gradle.kts.
All its REST receivers use the platform audience. Keep explicit namespaces, never /api. */ -}}
{{- $paths := list -}}
{{- range $name, $servicePaths := $prefixes -}}
{{- if (index $root.Values.services $name).enabled -}}
{{- $paths = concat $paths $servicePaths -}}
{{- end -}}
{{- end -}}
{{- $paths = concat $paths (list "/api/audit/v1" "/api/booking/v1" "/api/users/v1" "/api/services/v1" "/api/connector/v1" "/api/inbox/v1" "/api/eidas/signatures/v1" "/api/model/v1" "/api/semantic/binding/v1" "/api/semantic/vocabulary/v1" "/api/forms/v1" "/api/workflow/v1" "/api/modeling/v1" "/api/organization/v1" "/api/lifecycle/v1" "/api/v1/data/tabular" "/api/v1/tabular-mapping-templates") | uniq -}}
{{- $paths = without $paths "/api/blob-store/v1" "/api/v1/schemas" -}}
{{- $paths = append $paths "/api/v1/batch-invite" -}}
{{- $entries = append $entries (dict "serviceId" "service-platform" "audience" (index $roles "platform").receiverAudience "scopes" (list) "pathPrefixes" $paths "enabled" true) -}}
{{- else -}}
{{- range $name, $paths := $prefixes -}}
{{- if (index $root.Values.services $name).enabled -}}
{{- $role := index $roles $name -}}
{{- $entries = append $entries (dict "serviceId" $role.serviceId "audience" $role.receiverAudience "scopes" (list) "pathPrefixes" $paths "enabled" true) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- toJson $entries -}}
{{- end -}}
