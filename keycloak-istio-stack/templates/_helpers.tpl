{{/* Consistent names and selectors make review and troubleshooting easier. */}}
{{- define "identity.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "identity.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 42 | trimSuffix "-" -}}
{{- else -}}
{{/* Reserve suffix space for -postgresql-headless (the longest resource name). */}}
{{- printf "%s-%s" .Release.Name (include "identity.name" .) | trunc 42 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "identity.keycloakName" -}}
{{- printf "%s-keycloak" (include "identity.fullname" .) -}}
{{- end -}}

{{- define "identity.postgresName" -}}
{{- printf "%s-postgresql" (include "identity.fullname" .) -}}
{{- end -}}

{{/* A fixed contract shared with charts/realm/templates/realm-configmap.yaml. */}}
{{- define "identity.realmConfigMap" -}}
{{- printf "%s-realm" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "identity.labels" -}}
app.kubernetes.io/part-of: {{ include "identity.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "identity.keycloakSelector" -}}
app.kubernetes.io/name: keycloak
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "identity.postgresSelector" -}}
app.kubernetes.io/name: postgresql
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
