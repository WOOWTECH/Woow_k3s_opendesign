#!/usr/bin/env bash
#
# Same-workspace LiteLLM wiring (平台契約：同工作區自動串接只帶網址): the platform
# injects llmGateway.baseUrl = http://<release>-litellm.<ns>.svc.cluster.local:4000/v1
# (URL only, never a key). Asserts:
#   - the URL reaches the main container ONLY as env LITELLM_BASE_URL, through a
#     runtime ConfigMap (t-open-design-llm-gateway) referenced by envFrom (optional);
#     OPENAI_BASE_URL / ANTHROPIC_BASE_URL are never set by it
#   - ★ the pod template (every workload object, byte for byte) is IDENTICAL whether
#     the URL is unset, set, or changed — the operator's password reset
#     (helm upgrade --atomic --timeout 15s + rollout restart) must never wait for a
#     new pod because of it; the URL never appears in a workload spec
#   - trailing "/" trimmed; a value that is not a plain http(s) URL is dropped (no
#     env, no egress hole) instead of failing the render; a missing llmGateway map
#     (--reuse-values from an older chart) renders
#   - NetworkPolicy: a same-namespace hole to the LiteLLM proxy pod
#     (name=litellm, component=app) on TCP 4000 exists only while the URL is set
#     (the internet rule excludes 10.0.0.0/8)
#   - #1538: the same runtime ConfigMap carries OD_ALLOWED_INTERNAL_HOSTS = the URL's
#     host name (no port, no CIDR) so the daemon's SSRF guard lets the tenant reach
#     the same-workspace LiteLLM; a tenant's config.extraConfig entry is appended (not
#     hidden); llmGateway.allowInternalHost=false / bad URL / no URL → no LiteLLM entry
#
# Usage:    bash charts/open-design/tests/test-llm-gateway.sh
# Requires: helm + yq (mikefarah).
set -euo pipefail
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELM="${HELM_BINARY:-helm}"
command -v yq >/dev/null 2>&1 || { echo "SKIP (llm-gateway): yq (mikefarah) required"; exit 0; }
fail() { echo "FAIL (llm-gateway): $1"; exit 1; }

BASE=(--set-string config.sensitive.admin_password=pinned-test-password-1)
CM='t-open-design-llm-gateway'
MAIN='select(.kind=="StatefulSet" and .metadata.name=="t-open-design") | .spec.template.spec.containers[] | select(.name=="open-design")'
U='http://svc-1f000001-litellm.paas-ws-test.svc.cluster.local:4000/v1'
U2='http://svc-2e000002-litellm.paas-ws-test.svc.cluster.local:4000/v1'
render() { $HELM template t "$CHART_DIR" --namespace paas-ws-test "${BASE[@]}" "$@"; }
workloads() { render "$@" | yq 'select(.kind=="Deployment" or .kind=="StatefulSet")'; }
cmval() { render "$@" | yq "select(.kind==\"ConfigMap\" and .metadata.name==\"$CM\") | .data.LITELLM_BASE_URL // \"<unset>\""; }

# ── runtime ConfigMap + envFrom ─────────────────────────────────────────────
[ "$(render | yq "select(.kind==\"ConfigMap\" and .metadata.name==\"$CM\") | .metadata.name")" = "$CM" ] \
  || fail "runtime ConfigMap $CM must always be rendered (data {} when unset)"
[ "$(cmval)" = "<unset>" ] || fail "LITELLM_BASE_URL must be absent by default"
[ "$(cmval --set llmGateway.baseUrl="$U/")" = "$U" ] || fail "LITELLM_BASE_URL must carry the URL (trailing / trimmed)"
REF="$(render | yq "$MAIN | .envFrom[] | select(.configMapRef.name==\"$CM\")")"
[ -n "$REF" ] || fail "main container lacks envFrom configMapRef $CM"
[ "$(printf '%s' "$REF" | yq '.configMapRef.optional')" = "true" ] || fail "envFrom $CM must be optional"
for v in OPENAI_BASE_URL ANTHROPIC_BASE_URL; do
  [ -z "$(render --set llmGateway.baseUrl="$U" | yq "$MAIN | .env[] | select(.name==\"$v\") | .name")" ] \
    || fail "$v must not be set by the LiteLLM wiring (would hijack the tenant's provider)"
done
[ -z "$(render --set llmGateway.baseUrl="$U" | yq "select(.kind==\"ConfigMap\" and .metadata.name==\"$CM\") | .data | keys | .[] | select(. != \"LITELLM_BASE_URL\" and . != \"OD_ALLOWED_INTERNAL_HOSTS\")")" ] \
  || fail "$CM must carry nothing but LITELLM_BASE_URL and OD_ALLOWED_INTERNAL_HOSTS"
# ── #1538: SSRF allowlist for exactly the LiteLLM host name ──────────────────
H='svc-1f000001-litellm.paas-ws-test.svc.cluster.local'
ihosts() { render "$@" | yq "select(.kind==\"ConfigMap\" and .metadata.name==\"$CM\") | .data.OD_ALLOWED_INTERNAL_HOSTS // \"<unset>\""; }
[ "$(ihosts)" = "<unset>" ] || fail "#1538: OD_ALLOWED_INTERNAL_HOSTS must be absent without a LiteLLM URL"
[ "$(ihosts --set llmGateway.baseUrl="$U")" = "$H" ] || fail "#1538: OD_ALLOWED_INTERNAL_HOSTS must be the LiteLLM host name only (got $(ihosts --set llmGateway.baseUrl="$U"))"
[ "$(ihosts --set llmGateway.baseUrl="http://SVC-1F000001-LITELLM.paas-ws-test.svc.cluster.local:4000/v1/")" = "$H" ] || fail "#1538: host name must be lower-cased, port dropped"
[ "$(ihosts --set llmGateway.baseUrl="$U" --set llmGateway.allowInternalHost=false)" = "<unset>" ] || fail "#1538: allowInternalHost=false must not exempt the LiteLLM host"
[ "$(ihosts --set llmGateway.baseUrl="$U" --set config.extraConfig.OD_ALLOWED_INTERNAL_HOSTS=10.9.8.7)" = "$H,10.9.8.7" ] || fail "#1538: a tenant's extraConfig OD_ALLOWED_INTERNAL_HOSTS must be kept (appended)"
[ "$(ihosts --set config.extraConfig.OD_ALLOWED_INTERNAL_HOSTS=ollama.lan)" = "ollama.lan" ] || fail "#1538: extraConfig OD_ALLOWED_INTERNAL_HOSTS alone must still win over the empty runtime ConfigMap"
for bad in 'not a url' 'javascript:alert(1)' 'http://x/"$(id)"'; do
  [ "$(ihosts --set-string llmGateway.baseUrl="$bad")" = "<unset>" ] || fail "#1538: invalid llmGateway.baseUrl=[$bad] must not produce an allowlist entry"
done
[ "$(ihosts --set llmGateway=null)" = "<unset>" ] || fail "#1538: a missing llmGateway map must not produce an allowlist entry"
render --set llmGateway.baseUrl="$U" | yq 'select(.kind=="ConfigMap" and .metadata.name=="t-open-design-config") | .data | keys | .[]' | grep -qx OD_ALLOWED_INTERNAL_HOSTS \
  && fail "#1538: OD_ALLOWED_INTERNAL_HOSTS must live in the runtime ConfigMap only (not the hashed config)"

# (0.5.0: the Omnigent host is off by default — checked with the kit turned on.)
PT="$(render --set omnigentHost.enabled=true | yq "$MAIN | .env[] | select(.name==\"OG_PASSTHROUGH\") | .value")"
case ",$PT," in *,LITELLM_BASE_URL,*) ;; *) fail "OG_PASSTHROUGH must pass LITELLM_BASE_URL to Omnigent sessions ($PT)" ;; esac
# ── ★ pod template byte-identical across URL values ────────────────────────
W0="$(workloads)"
[ -n "$W0" ] || fail "no workload rendered"
[ "$(workloads --set llmGateway.baseUrl="$U")" = "$W0" ] || fail "setting llmGateway.baseUrl changed a workload (pod template must be identical)"
[ "$(workloads --set llmGateway.baseUrl="$U2")" = "$W0" ] || fail "changing llmGateway.baseUrl changed a workload"
[ "$(workloads --set llmGateway=null)" = "$W0" ] || fail "a missing llmGateway map changed a workload"
workloads --set llmGateway.baseUrl="$U" | grep -q 'svc-1f000001-litellm' && fail "the URL leaked into a workload spec"

# ── bad values: dropped, never a render failure ──────────────────────────────
for bad in 'not a url' 'javascript:alert(1)' 'ftp://x/v1' 'http://a b/v1' 'http://x/"$(id)"'; do
  render --set-string llmGateway.baseUrl="$bad" >/dev/null 2>&1 || fail "render failed for llmGateway.baseUrl=[$bad] (must drop, not fail)"
  [ "$(cmval --set-string llmGateway.baseUrl="$bad")" = "<unset>" ] || fail "invalid llmGateway.baseUrl=[$bad] must be dropped"
done
render --set llmGateway=null >/dev/null 2>&1 || fail "render failed without an llmGateway map (--reuse-values)"
# ── NetworkPolicy: same-namespace LiteLLM proxy hole, only while the URL is set ─
NP() { render "$@" | yq 'select(.kind=="NetworkPolicy" and .metadata.name=="t-open-design-allow") | .spec.egress[] | select(.to[0].podSelector.matchLabels."app.kubernetes.io/name"=="litellm")'; }
[ -z "$(NP)" ] || fail "LiteLLM egress hole must be absent while llmGateway.baseUrl is empty"
P="$(NP --set llmGateway.baseUrl="$U")"
[ -n "$P" ] || fail "LiteLLM egress hole missing while llmGateway.baseUrl is set"
[ "$(printf '%s' "$P" | yq '.to[0].podSelector.matchLabels."app.kubernetes.io/component"')" = "app" ] || fail "hole must target the LiteLLM proxy pod (component=app), not its database"
[ "$(printf '%s' "$P" | yq '.to | length')" = "1" ] || fail "hole must have exactly one peer"
[ "$(printf '%s' "$P" | yq '.to[0] | has("namespaceSelector") or has("ipBlock")')" = "false" ] || fail "hole must stay inside this namespace (podSelector only)"
[ "$(printf '%s' "$P" | yq -o=json -I=0 '.ports')" = '[{"protocol":"TCP","port":4000}]' ] || fail "hole must be TCP 4000 only"
[ -z "$(NP --set llmGateway.baseUrl="$U" --set networkPolicy.litellmEgress.enabled=false)" ] || fail "litellmEgress.enabled=false must drop the hole"
[ -z "$(NP --set-string llmGateway.baseUrl='not a url')" ] || fail "an invalid URL must not open the hole"
[ -n "$(NP --set llmGateway.baseUrl="$U" --set networkPolicy.litellmEgress=null)" ] || fail "a missing litellmEgress map (--reuse-values) must fall back to the defaults"
echo "PASS (llm-gateway): LITELLM_BASE_URL via runtime ConfigMap + optional envFrom only (no OPENAI_/ANTHROPIC_BASE_URL); pod template byte-identical across unset/set/changed URL; bad values dropped, never fatal; daemon → same-ns LiteLLM proxy TCP 4000 hole only while the URL is set; OD_ALLOWED_INTERNAL_HOSTS = LiteLLM host name only (#1538)."
