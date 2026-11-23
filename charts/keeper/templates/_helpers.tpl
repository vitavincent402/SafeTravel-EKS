{{- define "keeper.labels" -}}
app.kubernetes.io/part-of: keeper
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "keeper.image" -}}
{{- $root := index . 0 -}}
{{- $name := index . 1 -}}
{{- required "image.registry is required" $root.Values.image.registry }}/keeper/{{ $name }}:{{ required "image.tag is required" $root.Values.image.tag }}
{{- end -}}
