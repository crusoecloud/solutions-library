{{/*
URL of the Loki gateway service within the cluster.
Used for the Grafana datasource and can be referenced elsewhere.
*/}}
{{- define "logging.lokiUrl" -}}
http://{{ .Release.Name }}-loki-gateway.{{ .Release.Namespace }}.svc.cluster.local
{{- end }}

{{/*
Namespace where the Grafana datasource ConfigMap should be created.
Defaults to the release namespace so Grafana's sidecar can find it when
Grafana is deployed in the same namespace.
*/}}
{{- define "logging.grafanaNamespace" -}}
{{- .Values.grafanaDatasource.grafanaNamespace | default .Release.Namespace }}
{{- end }}
