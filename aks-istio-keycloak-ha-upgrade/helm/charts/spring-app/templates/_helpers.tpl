{{/* Labels that identify the pods of this release. They never change. */}}
{{- define "spring-app.selectorLabels" -}}
app.kubernetes.io/name: {{ .Release.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Labels put on every object of this release. */}}
{{- define "spring-app.labels" -}}
{{ include "spring-app.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/part-of: sso-demo
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{/* Name of the Secret that holds the OIDC client secret. */}}
{{- define "spring-app.secretName" -}}
{{- default (printf "%s-oidc" .Release.Name) .Values.oidc.existingSecret -}}
{{- end -}}
