{{/* Common labels */}}
{{- define "crusoe-node-remediation.labels" -}}
app.kubernetes.io/name: crusoe-node-remediation
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/* Fullname */}}
{{- define "crusoe-node-remediation.fullname" -}}
{{ .Release.Name }}-crusoe-node-remediation
{{- end -}}
