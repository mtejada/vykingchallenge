{{- define "cino-bar.fullname" -}}
{{- .Chart.Name -}}
{{- end -}}

{{- define "cino-bar.labels" -}}
app: {{ include "cino-bar.fullname" . }}
release: {{ .Release.Name }}
{{- end -}}

{{- define "cino-bar.selectorLabels" -}}
app: {{ include "cino-bar.fullname" . }}
release: {{ .Release.Name }}
{{- end -}}

{{- define "cino-bar.backendURL" -}}
{{- $host := "" -}}
{{- if and .Values.backend.ingress .Values.backend.ingress.enabled (gt (len .Values.backend.ingress.hosts) 0) -}}
  {{- $host = (index .Values.backend.ingress.hosts 0).host -}}
{{- end -}}
{{- if $host -}}
{{- printf "https://%s" $host -}}
{{- else -}}
http://{{ include "cino-bar.fullname" . }}-backend:{{ .Values.backend.service.port }}/api/v1
{{- end -}}
{{- end }}

{{- define "cino-bar.corsAllowedOrigins" -}}
{{- join "," .Values.global.corsAllowedOrigins -}}
{{- end }}

{{- define "cino-bar.externalSecretsServiceAccountName" -}}
{{- if .Values.externalSecrets.serviceAccount.name }}
{{- .Values.externalSecrets.serviceAccount.name }}
{{- else }}
{{- printf "%s-external-secrets" (include "cino-bar.fullname" .) }}
{{- end }}
{{- end }}
