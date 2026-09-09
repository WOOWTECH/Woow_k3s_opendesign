#!/usr/bin/env bash
# Fail-closed release preflight.
#
# Refuses to publish unless BOTH release targets are provably absent from GHCR:
#   ghcr.io/woowtech/woow-k3s-opendesign:<version>   (container image)
#   ghcr.io/woowtech/charts/opendesign:<version>     (packaged Helm chart, OCI)
#
# Published version tags are immutable. Recovering a partial release means
# bumping chart/Chart.yaml and cutting a new matching tag -- never overwriting.
set -Eeuo pipefail

cd "$(dirname "$0")/../.."

if [[ "${GITHUB_REF_TYPE:-}" != "tag" ]]; then
  echo "Release preflight may only run for a tag ref" >&2
  exit 1
fi

version=$(./.github/scripts/chart-version.sh chart/Chart.yaml)
expected="v${version}"
if [[ -z "$version" || "${GITHUB_REF_NAME:-}" != "$expected" ]]; then
  echo "Release tag ${GITHUB_REF_NAME:-<unset>} does not match chart/Chart.yaml version ${expected}" >&2
  exit 1
fi

registry_api=${GHCR_REGISTRY_API:-https://ghcr.io}
token_api=${GHCR_TOKEN_API:-https://ghcr.io/token}
token_service=${GHCR_TOKEN_SERVICE:-ghcr.io}
if [[ -z "${GHCR_ACTOR:-}" || -z "${GHCR_TOKEN:-}" ]]; then
  echo "GHCR read credentials are required; refusing to publish" >&2
  exit 1
fi
accept='application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json'

repositories=(
  woowtech/woow-k3s-opendesign
  woowtech/charts/opendesign
)

for repository in "${repositories[@]}"; do
  if ! token_json=$(curl --fail --silent --show-error --location --get \
    --user "${GHCR_ACTOR}:${GHCR_TOKEN}" \
    --data-urlencode "service=${token_service}" \
    --data-urlencode "scope=repository:${repository}:pull" \
    "$token_api"); then
    echo "Unable to obtain a registry token for ${repository}; refusing to publish" >&2
    exit 1
  fi
  if ! token=$(python3 -c 'import json,sys; body=json.load(sys.stdin); value=body.get("token") or body.get("access_token"); assert value; print(value)' <<<"$token_json"); then
    echo "Registry returned no usable token for ${repository}; refusing to publish" >&2
    exit 1
  fi
  # GHCR's HTTP/2 HEAD response advertises a manifest Content-Length but sends
  # no body; some runner curl builds report error 18 before exposing the 404.
  # A bounded GET avoids that protocol mismatch and the manifest is only KBs.
  if ! status=$(curl --silent --show-error --location --output /dev/null --write-out '%{http_code}' \
    --request GET \
    --header "Authorization: Bearer ${token}" \
    --header "Accept: ${accept}" \
    "${registry_api}/v2/${repository}/manifests/${version}"); then
    echo "Unable to query ${repository}:${version}; refusing to publish" >&2
    exit 1
  fi
  case "$status" in
    404)
      echo "Release target is unused: ghcr.io/${repository}:${version}"
      ;;
    200)
      echo "Release target already exists and is immutable: ghcr.io/${repository}:${version}" >&2
      exit 1
      ;;
    *)
      echo "Registry returned HTTP ${status} for ${repository}:${version}; refusing to publish" >&2
      exit 1
      ;;
  esac
done
