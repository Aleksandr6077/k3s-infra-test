{{/*
Имя чарта
*/}}
{{- define "nginx.name" -}}
{{- .Chart.Name -}}
{{- end -}}

{{/*
Полное имя (release-name + chart-name)
*/}}
{{- define "nginx.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Метки
*/}}
{{- define "nginx.labels" -}}
app: {{ include "nginx.name" . }}
{{- end -}}
