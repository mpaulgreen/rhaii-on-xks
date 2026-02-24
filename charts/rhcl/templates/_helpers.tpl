{{/*
Expand the name of the chart.
*/}}
{{- define "rhcl.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "rhcl.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "rhcl.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "rhcl.labels" -}}
helm.sh/chart: {{ include "rhcl.chart" . }}
{{ include "rhcl.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: rhcl
{{- end }}

{{/*
Selector labels
*/}}
{{- define "rhcl.selectorLabels" -}}
app.kubernetes.io/name: {{ include "rhcl.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Construct the full image reference with registry, repository, and digest
*/}}
{{- define "rhcl.image" -}}
{{- $registry := .registry | default .Values.images.registry -}}
{{- $repository := .repository -}}
{{- $digest := .digest -}}
{{- if $digest }}
{{- printf "%s/%s@%s" $registry $repository $digest }}
{{- else }}
{{- printf "%s/%s" $registry $repository }}
{{- end }}
{{- end }}

{{/*
Return the appropriate apiVersion for RBAC
*/}}
{{- define "rhcl.rbac.apiVersion" -}}
rbac.authorization.k8s.io/v1
{{- end }}

{{/*
Return the appropriate apiVersion for Deployment
*/}}
{{- define "rhcl.deployment.apiVersion" -}}
apps/v1
{{- end }}
