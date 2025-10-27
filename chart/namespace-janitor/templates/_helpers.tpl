{{- define "namespace-janitor.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "namespace-janitor.fullname" -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "namespace-janitor.labels" -}}
app.kubernetes.io/name: {{ include "namespace-janitor.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "namespace-janitor.selectorLabels" -}}
app.kubernetes.io/name: {{ include "namespace-janitor.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "namespace-janitor.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "namespace-janitor.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "namespace-janitor.alertSecretName" -}}
{{- if .Values.alertSecret.name -}}
{{ .Values.alertSecret.name }}
{{- else -}}
{{ printf "%s-alerts" (include "namespace-janitor.fullname" .) }}
{{- end -}}
{{- end -}}
