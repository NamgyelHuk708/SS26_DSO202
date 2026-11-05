{{/*
_helpers.tpl - named templates shared by every file in templates/.
Files starting with "_" never render as objects. Every name is prefixed
with the chart name because named templates are global across subcharts.
*/}}

{{/* task-tracker.name: chart name, or nameOverride. */}}
{{- define "task-tracker.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
task-tracker.fullname: base name of every object. Truncated to 63 chars
(DNS label limit). If the release name already contains the chart name
(e.g. task-tracker-dev) it is used alone, avoiding task-tracker-dev-task-tracker.
*/}}
{{- define "task-tracker.fullname" -}}
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

{{/* task-tracker.chart: "<name>-<version>" for the helm.sh/chart label. */}}
{{- define "task-tracker.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
task-tracker.environment: stops rendering with a clear message when no
environment is chosen, so no object is ever produced without one.
*/}}
{{- define "task-tracker.environment" -}}
{{- required "environment must be set (dev, staging or prod): pass -f environments/<env>.yaml" .Values.environment }}
{{- end }}

{{/*
task-tracker.selectorLabels: the SMALL, STABLE set that selectors use.
Call with (dict "ctx" . "component" "backend"). Never put the chart or app
version here: Deployment/StatefulSet selectors are immutable, so a label
that changes between releases would break every upgrade.
*/}}
{{- define "task-tracker.selectorLabels" -}}
app.kubernetes.io/name: {{ include "task-tracker.name" .ctx }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/* task-tracker.labels: full recommended label set for every object. */}}
{{- define "task-tracker.labels" -}}
helm.sh/chart: {{ include "task-tracker.chart" .ctx }}
{{ include "task-tracker.selectorLabels" . }}
app.kubernetes.io/version: {{ .ctx.Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .ctx.Release.Service }}
app.kubernetes.io/part-of: task-tracker
app.kubernetes.io/environment: {{ include "task-tracker.environment" .ctx | quote }}
{{- end }}

{{/* task-tracker.image: "<repository>:<tag or appVersion>". Call with (dict "ctx" . "img" .Values.images.backend). */}}
{{- define "task-tracker.image" -}}
{{- printf "%s:%s" .img.repository (.img.tag | default .ctx.Chart.AppVersion) }}
{{- end }}

{{/* Names of the objects that other templates refer to - one source of truth. */}}
{{- define "task-tracker.dbName" -}}{{ include "task-tracker.fullname" . }}-db{{- end }}
{{- define "task-tracker.backendName" -}}{{ include "task-tracker.fullname" . }}-backend{{- end }}
{{- define "task-tracker.frontendName" -}}{{ include "task-tracker.fullname" . }}-frontend{{- end }}
{{- define "task-tracker.configName" -}}{{ include "task-tracker.fullname" . }}-config{{- end }}
{{- define "task-tracker.secretName" -}}{{ include "task-tracker.fullname" . }}-secret{{- end }}

{{/*
task-tracker.configChecksums: Pod annotations holding hashes of the rendered
ConfigMap and Secret. Any content change -> new hash -> new Pod template ->
rolling update. Without them, a ConfigMap change never restarts the Pods.
*/}}
{{- define "task-tracker.configChecksums" -}}
checksum/config: {{ include (print .Template.BasePath "/configmap.yaml") . | sha256sum }}
checksum/secret: {{ include (print .Template.BasePath "/secret.yaml") . | sha256sum }}
{{- end }}
