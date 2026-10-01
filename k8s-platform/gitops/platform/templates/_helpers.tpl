{{/*
platform.enabled: "true" unless the entry sets enabled: false.
*/}}
{{- define "platform.enabled" -}}
{{- if eq (toString (get . "enabled")) "false" }}false{{ else }}true{{ end -}}
{{- end }}

{{/*
platform.hosted: "true" when the provider supplies this add-on, so Argo CD must not install the chart.
The Terraform cluster drivers apply the same rule to decide which managed add-ons to enable.
  - no catalog entry for this cluster type, or hosted: false on the add-on -> chart
  - catalog entry "builtin"                                                -> provider (already there)
  - any other catalog entry                                                -> provider when cluster.hostedAddons is true
Call with: dict "root" $ "name" <add-on key> "addon" <add-on entry>
*/}}
{{- define "platform.hosted" -}}
{{- $cluster := .root.Values.cluster | default dict -}}
{{- $catalog := index (.root.Values.hostedAddonCatalog | default dict) (toString $cluster.type) | default dict -}}
{{- if or (not (hasKey $catalog .name)) (eq (toString (get .addon "hosted")) "false") -}}
false
{{- else if eq (toString (get $catalog .name)) "builtin" -}}
true
{{- else if eq (toString (get $cluster "hostedAddons")) "false" -}}
false
{{- else -}}
true
{{- end -}}
{{- end }}
