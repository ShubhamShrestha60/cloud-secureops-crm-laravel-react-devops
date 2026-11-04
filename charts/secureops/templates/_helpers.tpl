{{/*
Common labels + names. Keep selectors stable across releases.
*/}}
{{- define "secureops.labels" -}}
helm.sh/chart: {{ include "secureops.chart" . }}
app.kubernetes.io/name: secureops
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "secureops.chart" -}}
{{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{- define "secureops.backendFullname" -}}
{{ .Release.Name }}-backend
{{- end }}

{{- define "secureops.frontendFullname" -}}
{{ .Release.Name }}-frontend
{{- end }}

{{- define "secureops.secretName" -}}
{{ .Release.Name }}-backend
{{- end }}
