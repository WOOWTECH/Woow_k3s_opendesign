#!/bin/sh
# Test-only: run in the daemon container (uid 1001). Registers project <id> with the daemon and writes the files the
# protection checks read through MCP read_file. Every file that must NOT be returned carries the marker.
#   sh make_project.sh <project-uuid> <big-file-bytes>
set -eu
id=$1
big=$2
m=woow-e2e-secret-marker
curl -sf -X POST -H 'Content-Type: application/json' -d "{\"id\":\"$id\",\"name\":\"e2e protections\"}" \
  http://127.0.0.1:7457/api/projects >/dev/null
d=/app/.od/projects/$id
mkdir -p "$d"
cd "$d"
printf '<html><body>woow-e2e-page</body></html>\n' > index.html
printf 'SECRET=%s\n' "$m" > .env
printf -- '-----BEGIN PRIVATE KEY-----\n%s\n-----END PRIVATE KEY-----\n' "$m" > server.pem
printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\n%s\n-----END OPENSSH PRIVATE KEY-----\n' "$m" > id_rsa
{ printf '%s\n' "$m"; head -c "$big" /dev/zero | tr '\0' a; } > big.txt
{ printf '\211PNG\r\n\032\n%s' "$m"; head -c 4096 /dev/urandom; } > image.png
ls -la
