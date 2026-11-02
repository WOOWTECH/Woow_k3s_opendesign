{{/* Optional same-container Paseo app; absent values after --reuse-values stay off. */}}
{{- define "open-design.paseo" -}}
{{- toYaml (merge (deepCopy (.Values.paseo | default dict)) (dict "enabled" false "origin" "")) -}}
{{- end -}}

{{- define "open-design.paseoOrigin" -}}
{{- $p := include "open-design.paseo" . | fromYaml -}}
{{- default (include "open-design.publicOrigin" .) $p.origin | trim | trimSuffix "/" | lower -}}
{{- end -}}

{{- define "open-design.paseoValidate" -}}
{{- $p := include "open-design.paseo" . | fromYaml -}}
{{- if $p.enabled -}}
{{- if or (not .Values.authProxy.enabled) (not .Values.authProxy.basicAuth.enabled) -}}
{{- fail "paseo.enabled requires authProxy.enabled and authProxy.basicAuth.enabled" -}}
{{- end -}}
{{- if not .Values.image.enforceBindHost -}}
{{- fail "paseo.enabled requires image.enforceBindHost so the original daemon argv is explicit" -}}
{{- end -}}
{{- if not (has (lower .Values.config.bindHost) (list "127.0.0.1" "localhost" "::1")) -}}
{{- fail "paseo.enabled requires a loopback config.bindHost" -}}
{{- end -}}
{{- $origin := include "open-design.paseoOrigin" . -}}
{{- if not (regexMatch "^https://[a-z0-9.-]+(:[0-9]{1,5})?$" $origin) -}}
{{- fail "paseo.enabled requires a concrete HTTPS origin in paseo.origin or config.allowedOrigins" -}}
{{- end -}}
{{- $mcp := include "open-design.mcp" . | fromYaml -}}
{{- if or (eq (int .Values.service.targetPort) 7460) (eq (int .Values.authProxy.port) 7460) (and $mcp.enabled (eq (int $mcp.port) 7460)) -}}
{{- fail "Paseo uses loopback port 7460; daemon, authproxy and MCP must use other ports" -}}
{{- end -}}
{{- if or (not .Values.persistence.data.enabled) (not .Values.persistence.home.enabled) -}}
{{- fail "paseo.enabled requires persistent data and home volumes" -}}
{{- end -}}
{{- if and .Values.console.enabled (has (.Values.console.externalPath | default "") (list "/paseo" "/paseo/setup" "/paseo/assets" "/api/paseo-bridge")) -}}
{{- fail "console.externalPath conflicts with the Paseo app routes" -}}
{{- end -}}
{{- range .Values.extraEnv -}}
{{- if or (hasPrefix "OPENDESIGN_PASEO_" .name) (eq .name "HOME") -}}
{{- fail "with paseo.enabled, HOME and OPENDESIGN_PASEO_* env are chart-managed; remove duplicate extraEnv entries" -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* One common gate for every actual Paseo upstream location. Paths are preserved. */}}
{{- define "open-design.paseoProxy" -}}
auth_basic "Open Design";
auth_basic_user_file /etc/nginx/auth/.htpasswd;
{{ include "woow.authguard.verified" . }}
if ($od_paseo_origin_ok = 0) { return 403; }
# No request URLs in upstream error logs; runtime owns sanitized diagnostics.
access_log off;
error_log /dev/null;
client_max_body_size 1m;
proxy_pass http://127.0.0.1:7460;
proxy_http_version 1.1;
proxy_set_header Host $od_upstream_host;
proxy_set_header Origin $http_origin;
proxy_set_header Authorization "";
proxy_set_header X-Remote-User-Id $remote_user;
proxy_set_header X-Forwarded-Host $od_upstream_host;
proxy_set_header X-Forwarded-Proto https;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection $connection_upgrade;
proxy_buffering off;
proxy_read_timeout 3600s;
proxy_send_timeout 3600s;
{{- end -}}
