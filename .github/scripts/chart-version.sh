#!/usr/bin/env bash
# Single source of truth for the release version.
#
# The chart version and the image tag are deliberately ONE number
# (see README "Versioning"). Every job that needs it calls this script so
# the workflow and the release preflight can never drift apart.
set -Eeuo pipefail

chart_file=${1:-chart/Chart.yaml}

if [[ ! -f "$chart_file" ]]; then
  echo "chart-version: ${chart_file} not found" >&2
  exit 1
fi

version=$(sed -n 's/^version:[[:space:]]*["'"'"']\{0,1\}\([0-9A-Za-z.+-]\{1,\}\)["'"'"']\{0,1\}[[:space:]]*$/\1/p' "$chart_file" | head -n 1)

if [[ -z "$version" ]]; then
  echo "chart-version: no 'version:' key in ${chart_file}" >&2
  exit 1
fi

# "latest" is forbidden everywhere in this repository: an immutable release
# cannot be built on a moving tag.
if [[ "$version" == "latest" ]]; then
  echo "chart-version: 'latest' is not a releasable version" >&2
  exit 1
fi

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "chart-version: '${version}' is not a bare MAJOR.MINOR.PATCH version" >&2
  exit 1
fi

printf '%s\n' "$version"
