{{- /*
  authproxy-guard (AI-FIX-SEC-1, #1457) — canonical source: shared/authproxy-guard/chart/_authproxy-guard.tpl.
  Vendored byte-identically into charts/<chart>/templates/ by scripts/sync-authproxy-guard.sh.
  EDIT ONLY the shared copy; CI (`sync-authproxy-guard.sh --check`) fails on drift.

  What it gives the tenant-facing nginx auth-proxy of a chart:
    1. failed-login lockout   — an IP that sends `guard.maxFailures` wrong Basic-auth
       credentials (or wrong logins on `guard.loginPaths`) inside `guard.windowSeconds`
       gets 429 + Retry-After for `guard.lockSeconds`, correct password included. Counted per CLIENT
       IP (CF-Connecting-IP, which Cloudflare overwrites; falls back to the TCP peer), never per
       account, so a stranger cannot lock the real admin out. State = njs shared dict (per pod,
       RAM only); a pod restart clears it.
    2. security headers       — HSTS (180 d, no includeSubDomains/preload — a Cloudflare-zone
       decision), X-Content-Type-Options, X-Frame-Options SAMEORIGIN, CSP frame-ancestors 'self',
       Referrer-Policy, Permissions-Policy. Same policy as the platform pages (woow_paas_platform
       services/security_headers.py): a header the upstream already sets is never overwritten or
       duplicated (maps on $upstream_http_*).
    3. no fingerprinting      — server_tokens off (no nginx/x.y.z in error pages),
       proxy_hide_header X-Powered-By.
  Resetting the failure counter on a successful Basic login (a typo must not count against a user
  who then logs in) is only allowed in a location that really checked the credentials: that
  location says so with `{{ include "woow.authguard.verified" . }}` (renders `set $woow_auth_verified 1;`).
  Any other location (auth_basic off, a redirect, a health page, the app's own login) answers 2xx/3xx
  to an arbitrary Authorization header, so it must never reset the counter (AI-FIX-SEC-1-1).
  Every value has a default in the template, so an upgrade with --reuse-values from an older
  chart (no `authProxy.guard` map) renders the same as a fresh install. `authProxy.guard.enabled:
  false` renders none of it (the module is not even loaded).

  Callers (context `.` = chart root):
    top of nginx.conf          {{ include "woow.authguard.main" . }}
    inside http { }            {{ include "woow.authguard.http" . | nindent 6 }}
    first lines of server { }  {{ include "woow.authguard.server" . | nindent 6 }}
    ConfigMap data key         authguard.js: | {{ include "woow.authguard.js" . | nindent 4 }}
    pod: mount that key at /etc/nginx/njs/authguard.js (subPath, read-only)
*/ -}}

{{- define "woow.authguard.enabled" -}}
{{- $g := (.Values.authProxy.guard | default dict) -}}
{{- if hasKey $g "enabled" -}}{{- if $g.enabled -}}1{{- end -}}{{- else -}}1{{- end -}}
{{- end -}}

{{- /* guard.headers.enabled — default on */ -}}
{{- define "woow.authguard.headersEnabled" -}}
{{- $g := (.Values.authProxy.guard | default dict) -}}
{{- $h := ($g.headers | default dict) -}}
{{- if hasKey $h "enabled" -}}{{- if $h.enabled -}}1{{- end -}}{{- else -}}1{{- end -}}
{{- end -}}

{{- define "woow.authguard.main" -}}
{{- if include "woow.authguard.enabled" . }}
load_module modules/ngx_http_js_module.so;
{{- end }}
{{- end -}}

{{- define "woow.authguard.http" -}}
{{- $g := (.Values.authProxy.guard | default dict) -}}
{{- /* server_tokens off is independent of the lockout: it only removes the version string. */ -}}
server_tokens off;

# The visitor's address behind the tunnel: Cloudflare overwrites CF-Connecting-IP; $remote_addr
# is only the tunnel's last hop. Used by the lockout (njs does the same lookup) and, where a chart
# says so, as the X-Forwarded-For handed to an app that rate-limits on it.
map $http_cf_connecting_ip $woow_client_ip { default $http_cf_connecting_ip; "" $remote_addr; }
{{- if include "woow.authguard.enabled" . }}

# authproxy-guard: failed-login lockout state (njs shared dict, RAM, per pod).
js_shared_dict_zone zone=authguard:{{ $g.sharedDictSize | default "1m" }} timeout=1h type=number evict;
js_import authguard from /etc/nginx/njs/authguard.js;
js_set $authguard_locked authguard.locked;
# Failures are counted in the LOG phase (js_header_filter is location-only, and a chart has
# several locations): the final status is known there, and the log line is thrown away.
# Only requests that can matter are evaluated: every 401, and every success that carried an
# Authorization header (it resets the counter of that client).
js_set $authguard_record authguard.record;
log_format authguard '$authguard_record';
map "$status:$http_authorization" $authguard_watch { default 0; "~^401:" 1; "~^[23][0-9][0-9]:." 1; }
access_log /dev/null authguard if=$authguard_watch;
{{- end }}
{{- if include "woow.authguard.headersEnabled" . }}

# Security headers, filled in only when the upstream did not set its own (no duplicates,
# the app's own policy always wins). Empty value = add_header emits nothing.
map $upstream_http_strict_transport_security $woow_h_hsts { default ""; "" {{ (($g.headers | default dict).hsts | default "max-age=15552000") | quote }}; }
map $upstream_http_x_content_type_options $woow_h_nosniff { default ""; "" "nosniff"; }
map $upstream_http_x_frame_options $woow_h_xfo { default ""; "" {{ (($g.headers | default dict).frameOptions | default "SAMEORIGIN") | quote }}; }
map $upstream_http_content_security_policy $woow_h_csp { default ""; "" {{ (($g.headers | default dict).contentSecurityPolicy | default "frame-ancestors 'self'") | quote }}; }
map $upstream_http_referrer_policy $woow_h_referrer { default ""; "" {{ (($g.headers | default dict).referrerPolicy | default "strict-origin-when-cross-origin") | quote }}; }
map $upstream_http_permissions_policy $woow_h_permissions { default ""; "" {{ (($g.headers | default dict).permissionsPolicy | default "geolocation=(), payment=(), usb=()") | quote }}; }
{{- end }}
{{- end -}}

{{- /* The header block, shared by the server and by the 429 page (add_header does not
       inherit into a block that sets its own). */ -}}
{{- define "woow.authguard.headerLines" -}}
{{- if include "woow.authguard.headersEnabled" . }}
add_header Strict-Transport-Security $woow_h_hsts always;
add_header X-Content-Type-Options $woow_h_nosniff always;
add_header X-Frame-Options $woow_h_xfo always;
add_header Content-Security-Policy $woow_h_csp always;
add_header Referrer-Policy $woow_h_referrer always;
add_header Permissions-Policy $woow_h_permissions always;
{{- end }}
{{- end -}}

{{- /* Put this in every location whose answer proves the Basic credentials were checked:
       a location with auth_basic enabled that hands the request on (proxy_pass — NOT one that
       `return`s, which runs in the rewrite phase before auth_basic), or one whose upstream
       enforces Basic itself (the ttyd console). njs reads it in the log phase. */ -}}
{{- define "woow.authguard.verified" -}}
{{- if include "woow.authguard.enabled" . }}
set $woow_auth_verified 1;
{{- end }}
{{- end -}}

{{- define "woow.authguard.server" -}}
{{- $g := (.Values.authProxy.guard | default dict) -}}
# ── authproxy-guard (AI-FIX-SEC-1, #1457) ─────────────────────────────────────
proxy_hide_header X-Powered-By;
{{- include "woow.authguard.headerLines" . | nindent 0 }}
{{- if include "woow.authguard.enabled" . }}
# Locked client → 429 before any auth is evaluated (a correct password does not get in
# while locked, otherwise the lock would not slow guessing down).
if ($authguard_locked) { return 429; }
error_page 429 @woow_locked;
location @woow_locked {
  {{- include "woow.authguard.headerLines" . | nindent 2 }}
  add_header Retry-After {{ $g.lockSeconds | default 300 | quote }} always;
  add_header Cache-Control "no-store, no-transform" always;
  default_type text/plain;
  return 429 "Too many failed login attempts. Try again later.\n";
}
{{- end }}
{{- end -}}

{{- /* The njs file. Thresholds come from values (defaults here). `guard.loginPaths` are
       exact request paths whose POST 401 counts as a wrong login even without a Basic header
       (an app with its own login form, e.g. Hermes /auth/password-login). */ -}}
{{- define "woow.authguard.js" -}}
{{- $g := (.Values.authProxy.guard | default dict) -}}
// authproxy-guard failed-login lockout (AI-FIX-SEC-1, #1457). Rendered from
// shared/authproxy-guard/chart/_authproxy-guard.tpl — do not edit in the chart.
var MAX_FAIL = {{ int ($g.maxFailures | default 10) }};
var WINDOW_MS = {{ mul (int ($g.windowSeconds | default 120)) 1000 }};
var LOCK_MS = {{ mul (int ($g.lockSeconds | default 300)) 1000 }};
var LOGIN_PATHS = {{ ($g.loginPaths | default list) | toJson }};

function clientKey(r) {
  var ip = r.headersIn['CF-Connecting-IP'];
  if (!ip || ip.length > 45 || !/^[0-9A-Fa-f:.]+$/.test(ip)) {
    ip = r.remoteAddress;
  }
  return String(ip);
}

function zone() {
  return ngx.shared.authguard;
}

// js_set: "1" while this client is locked out, "" otherwise. Fails open: a bug here must
// never take the tenant's entrance down.
function locked(r) {
  try {
    return zone().get('lock:' + clientKey(r)) ? '1' : '';
  } catch (e) {
    r.error('authguard.locked: ' + e);
    return '';
  }
}

function isFailedLogin(r) {
  if (r.status !== 401) {
    return false;
  }
  var challenge = r.variables.sent_http_www_authenticate || '';
  // a Basic attempt that was answered with a Basic challenge (nginx's auth_basic, or an app
  // that asks for Basic, e.g. a web terminal) — a Bearer token or garbage scheme is not a password guess
  if (/^\s*basic/i.test(r.headersIn['Authorization'] || '') && /^\s*basic/i.test(challenge)) {
    return true;
  }
  return r.method === 'POST' && LOGIN_PATHS.indexOf(r.variables.uri) !== -1;
}

// js_set evaluated by the access_log in authguard's log_format (log phase, final status),
// for every response of the server, also the ones nginx makes itself (the auth_basic 401).
// Returns "" — the log line itself is discarded.
function record(r) {
  try {
    if (r.status === 401 && isFailedLogin(r)) {
      var key = clientKey(r);
      var n = zone().incr('fail:' + key, 1, 0, WINDOW_MS);
      if (n >= MAX_FAIL) {
        zone().set('lock:' + key, 1, LOCK_MS);
        zone().delete('fail:' + key);
        r.warn('authguard: ' + key + ' locked for ' + (LOCK_MS / 1000) + ' s after ' + n + ' failed logins');
      }
    } else if (r.status < 400 && /^\s*basic/i.test(r.headersIn['Authorization'] || '') && r.variables.woow_auth_verified === '1') {
      // the Basic credentials worked: forget earlier typos. Three conditions, all needed:
      //  - Basic only — a Bearer token (an MCP client, say) must not reset a password guesser;
      //  - a status < 400 — the request was let through;
      //  - the location said it verified the credentials ($woow_auth_verified). A location that
      //    does not (auth_basic off, a redirect, /api/health) answers 2xx/3xx to ANY Authorization
      //    header; without this condition a guesser clears his own counter every ninth guess.
      zone().delete('fail:' + clientKey(r));
    }
  } catch (e) {
    r.error('authguard.record: ' + e);
  }
  return '';
}

export default { locked, record };
{{- end -}}
