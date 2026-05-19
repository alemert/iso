#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./build-deployment-config.sh -h <host> [-c <config-dir>] [-o <output-dir>]

Examples:
  ./build-deployment-config.sh -h kubi03
  ./build-deployment-config.sh -h kubi03 -c ./etc -o ./etc/deploy/kubi03

Expected files:
  <config-dir>/user-data.base.yml
  <config-dir>/meta-data.base.yml
  <config-dir>/hosts/<host>.yml

Host file format:
  user-data:
    ... YAML override for user-data base ...
  meta-data:
    ... YAML override for meta-data base ...
EOF
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command '$cmd' not found." >&2
    exit 1
  fi
}

HOST=""
CONFIG_DIR="./etc"
OUTPUT_DIR=""

while getopts ":h:c:o:" opt; do
  case "$opt" in
    h) HOST="$OPTARG" ;;
    c) CONFIG_DIR="$OPTARG" ;;
    o) OUTPUT_DIR="$OPTARG" ;;
    *)
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$HOST" ]]; then
  usage
  exit 1
fi

require_cmd yq

USER_BASE="$CONFIG_DIR/user-data.base.yml"
META_BASE="$CONFIG_DIR/meta-data.base.yml"
HOST_FILE="$CONFIG_DIR/hosts/$HOST.yml"

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$CONFIG_DIR/deploy/$HOST"
fi

if [[ ! -f "$USER_BASE" ]]; then
  echo "Error: missing base user-data file: $USER_BASE" >&2
  exit 1
fi

if [[ ! -f "$META_BASE" ]]; then
  echo "Error: missing base meta-data file: $META_BASE" >&2
  exit 1
fi

if [[ ! -f "$HOST_FILE" ]]; then
  echo "Error: missing host override file: $HOST_FILE" >&2
  exit 1
fi

# Example OUTPUT_DIR: ./etc/deploy/kubi03
mkdir -p "$OUTPUT_DIR"

TMP_USER="$(mktemp)"
TMP_META="$(mktemp)"
trap 'rm -f "$TMP_USER" "$TMP_META"' EXIT

if [[ "$(yq eval '."user-data" == null' "$HOST_FILE")" == "true" ]]; then
  echo "Error: host file must contain top-level key 'user-data'." >&2
  exit 1
fi

if [[ "$(yq eval '."meta-data" == null' "$HOST_FILE")" == "true" ]]; then
  echo "Error: host file must contain top-level key 'meta-data'." >&2
  exit 1
fi

yq eval '."user-data"' "$HOST_FILE" > "$TMP_USER"
yq eval '."meta-data"' "$HOST_FILE" > "$TMP_META"

OUT_USER="$OUTPUT_DIR/user-data"
OUT_META="$OUTPUT_DIR/meta-data"

# Build final user-data by writing the cloud-init header first,
# then merging base user-data (fileIndex 0) with host overrides (fileIndex 1).
# The whole grouped block is redirected once to $OUT_USER.
# Sample with real files:
#   input 0: ./etc/user-data.base.yml
#   input 1: ./etc/hosts/kubi03.yml ("user-data" section only)
#   output : ./etc/deploy/kubi03/user-data
# input 1 overrides keys in input 0
{
  echo "#cloud-config"
  yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$USER_BASE" "$TMP_USER"
} > "$OUT_USER"

yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$META_BASE" "$TMP_META" > "$OUT_META"

echo "Generated deployment config for host '$HOST':"
echo "  $OUT_USER"
echo "  $OUT_META"