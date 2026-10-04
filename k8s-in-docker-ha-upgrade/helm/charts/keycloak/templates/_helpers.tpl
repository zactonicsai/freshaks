{{/* Labels that identify the pods of this release. They never change. */}}
{{- define "keycloak.selectorLabels" -}}
app.kubernetes.io/name: keycloak
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Labels put on every object of this release. */}}
{{- define "keycloak.labels" -}}
{{ include "keycloak.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}
