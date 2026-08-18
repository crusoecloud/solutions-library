{{- define "slurm-accounting.fullname" -}}
{{ .Values.clusterName }}-accounting
{{- end -}}

{{- define "slurm-accounting.mariadb.fullname" -}}
{{ .Values.clusterName }}-accounting-mariadb
{{- end -}}

{{- define "slurm-accounting.labels" -}}
app.kubernetes.io/part-of: {{ .Values.clusterName }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
