{{/* Major version taken from the image tag, for example "14" from "14.12". */}}
{{- define "postgres.major" -}}
{{- splitList "." (toString .Values.image.tag) | first -}}
{{- end -}}

{{/* Labels that identify the pods of this release. They never change. */}}
{{- define "postgres.selectorLabels" -}}
app.kubernetes.io/name: postgres
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Labels put on every object of this release. */}}
{{- define "postgres.labels" -}}
{{ include "postgres.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}
