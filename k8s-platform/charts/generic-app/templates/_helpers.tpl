{{- define "app.name" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{- define "app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "app.name" . }}
{{- end }}

{{- define "app.labels" -}}
{{ include "app.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{- define "app.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}{{ include "app.name" . }}{{ else }}{{ .Values.serviceAccount.name | default "default" }}{{ end -}}
{{- end }}

{{/* The image reference: a digest wins over a tag. */}}
{{- define "app.image" -}}
{{- $repository := required "image.repository is required" .Values.image.repository -}}
{{- if .Values.image.digest -}}
{{ $repository }}@{{ .Values.image.digest }}
{{- else -}}
{{ $repository }}:{{ required "image.tag or image.digest is required" .Values.image.tag }}
{{- end -}}
{{- end }}

{{/* The pod template, shared by every workload kind. */}}
{{- define "app.pod" -}}
metadata:
  labels:
    {{- include "app.selectorLabels" . | nindent 4 }}
    {{- with .Values.podLabels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- if or .Values.config .Values.podAnnotations }}
  annotations:
    {{- if .Values.config }}
    checksum/config: {{ toYaml .Values.config | sha256sum }}
    {{- end }}
    {{- with .Values.podAnnotations }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- end }}
spec:
  serviceAccountName: {{ include "app.serviceAccountName" . }}
  automountServiceAccountToken: {{ .Values.serviceAccount.automountToken }}
  {{- if has .Values.kind (list "Job" "CronJob") }}
  restartPolicy: {{ .Values.job.restartPolicy }}
  {{- end }}
  {{- with .Values.imagePullSecrets }}
  imagePullSecrets:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  securityContext:
    {{- toYaml .Values.podSecurityContext | nindent 4 }}
  {{- with .Values.initContainers }}
  initContainers:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  containers:
    - name: app
      image: {{ include "app.image" . }}
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      {{- with .Values.command }}
      command:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.args }}
      args:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.env }}
      env:
        {{- range $name, $value := . }}
        - name: {{ $name }}
          {{- if kindIs "map" $value }}
          {{- toYaml $value | nindent 10 }}
          {{- else }}
          value: {{ $value | quote }}
          {{- end }}
        {{- end }}
      {{- end }}
      {{- with .Values.envFrom }}
      envFrom:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.ports }}
      ports:
        {{- range $name, $port := . }}
        - name: {{ $name }}
          containerPort: {{ $port | int }}
        {{- end }}
      {{- end }}
      {{- with .Values.probes.liveness }}
      livenessProbe:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.probes.readiness }}
      readinessProbe:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.probes.startup }}
      startupProbe:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      resources:
        {{- toYaml .Values.resources | nindent 8 }}
      securityContext:
        {{- toYaml .Values.securityContext | nindent 8 }}
      {{- if or .Values.config .Values.persistence.enabled .Values.volumeMounts }}
      volumeMounts:
        {{- if .Values.config }}
        - name: config
          mountPath: {{ .Values.configMountPath }}
          readOnly: true
        {{- end }}
        {{- if .Values.persistence.enabled }}
        - name: data
          mountPath: {{ .Values.persistence.mountPath }}
        {{- end }}
        {{- with .Values.volumeMounts }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      {{- end }}
    {{- with .Values.sidecars }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- $claim := and .Values.persistence.enabled (ne .Values.kind "StatefulSet") }}
  {{- if or .Values.config $claim .Values.volumes }}
  volumes:
    {{- if .Values.config }}
    - name: config
      configMap:
        name: {{ include "app.name" . }}
    {{- end }}
    {{- if $claim }}
    - name: data
      persistentVolumeClaim:
        claimName: {{ include "app.name" . }}
    {{- end }}
    {{- with .Values.volumes }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- end }}
  {{- with .Values.nodeSelector }}
  nodeSelector:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.tolerations }}
  tolerations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.affinity }}
  affinity:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.topologySpreadConstraints }}
  topologySpreadConstraints:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end }}
