{{/*
Nombre completo del release.
*/}}
{{- define "osfatun-frontend-usuario.fullname" -}}
{{- default .Chart.Name .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Labels comunes para todos los recursos del chart.
*/}}
{{- define "osfatun-frontend-usuario.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Imagen completa (repository:tag).
*/}}
{{- define "osfatun-frontend-usuario.image" -}}
{{ .Values.image.repository }}:{{ .Values.image.tag }}
{{- end }}
