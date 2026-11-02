{{/* Same-workspace LiteLLM wiring helpers (llmGateway.baseUrl → LITELLM_BASE_URL,
     networkPolicy.litellmEgress). Separate file so it never collides with _helpers.tpl edits. */}}
{{/*
Same-workspace LiteLLM gateway (llmGateway.baseUrl, injected by the platform:
http://<release>-litellm.<ns>.svc.cluster.local:4000/v1). CR/LF stripped, trimmed,
one trailing "/" removed; anything that is not a plain http(s) URL prints "" (no
env, no egress hole; NOTES says so) — never a render failure. A missing
llmGateway map (--reuse-values from an older chart) counts as "".
*/}}
{{- define "open-design.llmGatewayRawBaseUrl" -}}
{{- (.Values.llmGateway | default dict).baseUrl | default "" | toString | replace "\r" "" | replace "\n" "" | trim -}}
{{- end -}}
{{- define "open-design.llmGatewayBaseUrl" -}}
{{- $u := include "open-design.llmGatewayRawBaseUrl" . | trimSuffix "/" -}}
{{- if regexMatch "^https?://[A-Za-z0-9._~:/?#@!$&()*+,;=%\\[\\]-]+$" $u -}}{{ $u }}{{- end -}}
{{- end -}}
{{/*
#1538: OD_ALLOWED_INTERNAL_HOSTS for the runtime ConfigMap — the host name of the
injected LiteLLM URL (port dropped; the daemon keeps only the host name anyway),
joined with any config.extraConfig.OD_ALLOWED_INTERNAL_HOSTS. Empty URL, an invalid
URL or llmGateway.allowInternalHost=false → only the tenant's own entry (if any).
*/}}
{{- define "open-design.llmGatewayAllowedInternalHosts" -}}
{{- $hosts := list -}}
{{- $gw := .Values.llmGateway | default dict -}}
{{- $allow := ternary $gw.allowInternalHost true (hasKey $gw "allowInternalHost") -}}
{{- $u := include "open-design.llmGatewayBaseUrl" . -}}
{{- if and $allow $u -}}
{{- $h := regexReplaceAll ":[0-9]+$" (urlParse $u).host "" | lower -}}
{{- if regexMatch "^[a-z0-9.-]+$" $h -}}
{{- $hosts = append $hosts $h -}}
{{- end -}}
{{- end -}}
{{- $extra := (.Values.config.extraConfig | default dict).OD_ALLOWED_INTERNAL_HOSTS | default "" | toString | replace "\r" "" | replace "\n" "" | trim -}}
{{- if $extra -}}
{{- $hosts = append $hosts $extra -}}
{{- end -}}
{{- join "," $hosts -}}
{{- end -}}
{{/* Runtime ConfigMap carrying LITELLM_BASE_URL (templates/llm-gateway-configmap.yaml). */}}
{{- define "open-design.llmGatewayConfigMapName" -}}
{{- printf "%s-llm-gateway" (include "open-design.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{/*
NetworkPolicy egress peer for the same-workspace LiteLLM proxy (charts/litellm labels
its proxy pod app.kubernetes.io/name=litellm + component=app; its database pod does
not match). Only while llmGateway.baseUrl is set; defaults apply when
networkPolicy.litellmEgress is missing (--reuse-values from an older chart).
Prints "" when no rule should be rendered.
*/}}
{{- define "open-design.litellmEgress" -}}
{{- $e := .Values.networkPolicy.litellmEgress | default dict -}}
{{- $on := ternary $e.enabled true (hasKey $e "enabled") -}}
{{- if and $on (include "open-design.llmGatewayBaseUrl" .) -}}
{{- $labels := $e.podLabels | default (dict "app.kubernetes.io/name" "litellm" "app.kubernetes.io/component" "app") -}}
{{- $ports := $e.ports | default (list 4000) -}}
{{- toYaml (dict "podLabels" $labels "ports" $ports) -}}
{{- end -}}
{{- end -}}
