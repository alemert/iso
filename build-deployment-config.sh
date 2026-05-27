#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./build-deployment-config.sh -h <host> [-b <bios|efi>] [-c <config-dir>] [-o <output-dir>]

Examples:
  ./build-deployment-config.sh -h kubi03
  ./build-deployment-config.sh -h kubi03 -b bios
  ./build-deployment-config.sh -h kubi03 -c ./etc -o ./etc/deploy/kubi03

Expected files:
  <config-dir>/base/user-data.yml (or .yaml)
  <config-dir>/base/meta-data.yml (or .yaml)
  Optional: <config-dir>/boot/user-data.bios.yml / user-data.efi.yml (or .yaml)
  Preferred host files:
    <config-dir>/hosts/<host>/user-data.yml (or .yaml)
    <config-dir>/hosts/<host>/meta-data.yml (or .yaml)
  Backward compatible host file:
    <config-dir>/hosts/<host>.yml (or .yaml)

Host file format:
  Preferred (split files):
    hosts/<host>/user-data.yml   # plain user-data override doc
    hosts/<host>/meta-data.yml   # plain meta-data override doc

  Legacy (single file):
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
BOOT_MODE=""
CONFIG_DIR="./etc"
OUTPUT_DIR=""

while getopts ":h:b:c:o:" opt; do
  case "$opt" in
    h) HOST="$OPTARG" ;;
    b) BOOT_MODE="$OPTARG" ;;
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

pick_yaml_file() {
  local path_no_ext="$1"
  if [[ -f "$path_no_ext.yml" ]]; then
    echo "$path_no_ext.yml"
    return 0
  fi
  if [[ -f "$path_no_ext.yaml" ]]; then
    echo "$path_no_ext.yaml"
    return 0
  fi
  return 1
}

USER_BASE="$(pick_yaml_file "$CONFIG_DIR/base/user-data" || true)"
META_BASE="$(pick_yaml_file "$CONFIG_DIR/base/meta-data" || true)"

USER_BOOT_FILE=""
if [[ -n "$BOOT_MODE" ]]; then
  if [[ "$BOOT_MODE" != "bios" && "$BOOT_MODE" != "efi" ]]; then
    echo "Error: invalid boot mode '$BOOT_MODE'. Expected 'bios' or 'efi'." >&2
    exit 1
  fi
  USER_BOOT_FILE="$(pick_yaml_file "$CONFIG_DIR/boot/user-data.$BOOT_MODE" || true)"
fi

HOST_USER_FILE=""
HOST_META_FILE=""
HOST_LEGACY_FILE=""

HOST_DIR="$CONFIG_DIR/hosts/$HOST"
if [[ -d "$HOST_DIR" ]]; then
  HOST_USER_FILE="$(pick_yaml_file "$HOST_DIR/user-data" || true)"
  HOST_META_FILE="$(pick_yaml_file "$HOST_DIR/meta-data" || true)"
  if [[ -z "$HOST_USER_FILE" && -f "$HOST_DIR/user-data" ]]; then
    HOST_USER_FILE="$HOST_DIR/user-data"
  fi
  if [[ -z "$HOST_META_FILE" && -f "$HOST_DIR/meta-data" ]]; then
    HOST_META_FILE="$HOST_DIR/meta-data"
  fi
fi

HOST_LEGACY_FILE="$(pick_yaml_file "$CONFIG_DIR/hosts/$HOST" || true)"

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$CONFIG_DIR/deploy/$HOST"
fi

if [[ -z "$USER_BASE" || ! -f "$USER_BASE" ]]; then
  echo "Error: missing base user-data file: $CONFIG_DIR/base/user-data.yml(.yaml)" >&2
  exit 1
fi

if [[ -z "$META_BASE" || ! -f "$META_BASE" ]]; then
  echo "Error: missing base meta-data file: $CONFIG_DIR/base/meta-data.yml(.yaml)" >&2
  exit 1
fi

if [[ -n "$BOOT_MODE" && ( -z "$USER_BOOT_FILE" || ! -f "$USER_BOOT_FILE" ) ]]; then
  echo "Error: missing boot override file: $CONFIG_DIR/boot/user-data.$BOOT_MODE.yml(.yaml)" >&2
  exit 1
fi

if [[ -z "$HOST_USER_FILE" && -z "$HOST_LEGACY_FILE" ]]; then
  echo "Error: missing host user-data override file for '$HOST'." >&2
  echo "  Expected one of:" >&2
  echo "    $CONFIG_DIR/hosts/$HOST/user-data.yml(.yaml)" >&2
  echo "    $CONFIG_DIR/hosts/$HOST.yml(.yaml) with top-level key 'user-data'" >&2
  exit 1
fi

if [[ -z "$HOST_META_FILE" && -z "$HOST_LEGACY_FILE" ]]; then
  echo "Error: missing host meta-data override file for '$HOST'." >&2
  echo "  Expected one of:" >&2
  echo "    $CONFIG_DIR/hosts/$HOST/meta-data.yml(.yaml)" >&2
  echo "    $CONFIG_DIR/hosts/$HOST.yml(.yaml) with top-level key 'meta-data'" >&2
  exit 1
fi

# Example OUTPUT_DIR: ./etc/deploy/kubi03
mkdir -p "$OUTPUT_DIR"

TMP_USER="$(mktemp)"
TMP_META="$(mktemp)"
TMP_EMPTY="$(mktemp)"
trap 'rm -f "$TMP_USER" "$TMP_META" "$TMP_EMPTY"' EXIT

echo '{}' > "$TMP_EMPTY"

normalize_doc() {
  local src="$1"
  local top_key="$2"
  local out="$3"

  if [[ -z "$src" || ! -f "$src" ]]; then
    cp "$TMP_EMPTY" "$out"
    return 0
  fi

  # If a top-level section exists (legacy combined file), extract it.
  # Otherwise, use the file as-is (preferred split-file format).
  if [[ "$(yq eval ".\"$top_key\" == null" "$src")" == "false" ]]; then
    yq eval ".\"$top_key\"" "$src" > "$out"
  elif [[ -n "$HOST_LEGACY_FILE" && "$src" == "$HOST_LEGACY_FILE" ]]; then
    echo "Error: host file '$HOST_LEGACY_FILE' must contain top-level key '$top_key'." >&2
    exit 1
  else
    cp "$src" "$out"
  fi
}

normalize_doc "${HOST_USER_FILE:-$HOST_LEGACY_FILE}" "user-data" "$TMP_USER"
normalize_doc "${HOST_META_FILE:-$HOST_LEGACY_FILE}" "meta-data" "$TMP_META"

has_value() {
  local needle="$1"
  shift || true

  local value
  for value in "$@"; do
    if [[ "$value" == "$needle" ]]; then
      return 0
    fi
  done

  return 1
}

reorder_storage_config() {
  local file="$1"
  local count

  count="$(yq eval '.autoinstall.storage.config | length' "$file")"
  if [[ "$count" == "null" || "$count" -eq 0 ]]; then
    return 0
  fi

  local -a all_ids=()
  local -a pending_indices=()
  local -a sorted_indices=()
  local -a resolved_ids=()
  local idx id dep progress unresolved
  local item_type item_size item_device other_idx other_type other_device

  for ((idx = 0; idx < count; idx++)); do
    pending_indices+=("$idx")
    id="$(yq eval ".autoinstall.storage.config[$idx].id // \"\"" "$file")"
    if [[ -n "$id" ]]; then
      all_ids+=("$id")
    fi
  done

  while [[ ${#pending_indices[@]} -gt 0 ]]; do
    progress=0
    local -a next_pending=()

    for idx in "${pending_indices[@]}"; do
      unresolved=0

      for dep in \
        "$(yq eval ".autoinstall.storage.config[$idx].device // \"\"" "$file")" \
        "$(yq eval ".autoinstall.storage.config[$idx].volume // \"\"" "$file")" \
        "$(yq eval ".autoinstall.storage.config[$idx].volgroup // \"\"" "$file")"; do
        if [[ -n "$dep" ]] && has_value "$dep" "${all_ids[@]}" && ! has_value "$dep" "${resolved_ids[@]}"; then
          unresolved=1
          break
        fi
      done

      if [[ "$unresolved" -eq 0 ]]; then
        while IFS= read -r dep; do
          if [[ -n "$dep" ]] && has_value "$dep" "${all_ids[@]}" && ! has_value "$dep" "${resolved_ids[@]}"; then
            unresolved=1
            break
          fi
        done < <(yq eval ".autoinstall.storage.config[$idx].devices[]" "$file" 2>/dev/null || true)
      fi

      if [[ "$unresolved" -eq 0 ]]; then
        item_type="$(yq eval ".autoinstall.storage.config[$idx].type // \"\"" "$file")"
        item_size="$(yq eval ".autoinstall.storage.config[$idx].size // \"\"" "$file")"
        item_device="$(yq eval ".autoinstall.storage.config[$idx].device // \"\"" "$file")"

        # curtin requires size -1 partition to be the last partition on that disk.
        if [[ "$item_type" == "partition" && "$item_size" == "-1" && -n "$item_device" ]]; then
          for other_idx in "${pending_indices[@]}"; do
            if [[ "$other_idx" == "$idx" ]]; then
              continue
            fi

            other_type="$(yq eval ".autoinstall.storage.config[$other_idx].type // \"\"" "$file")"
            other_device="$(yq eval ".autoinstall.storage.config[$other_idx].device // \"\"" "$file")"

            if [[ "$other_type" == "partition" && "$other_device" == "$item_device" ]]; then
              unresolved=1
              break
            fi
          done
        fi
      fi

      if [[ "$unresolved" -eq 0 ]]; then
        sorted_indices+=("$idx")
        id="$(yq eval ".autoinstall.storage.config[$idx].id // \"\"" "$file")"
        if [[ -n "$id" ]]; then
          resolved_ids+=("$id")
        fi
        progress=1
      else
        next_pending+=("$idx")
      fi
    done

    if [[ "$progress" -eq 0 ]]; then
      sorted_indices+=("${pending_indices[@]}")
      break
    fi

    pending_indices=("${next_pending[@]}")
  done

  local reorder_expr='.autoinstall.storage.config = ['
  for idx in "${sorted_indices[@]}"; do
    reorder_expr+=".autoinstall.storage.config[$idx], "
  done
  reorder_expr="${reorder_expr%, } ]"

  local tmp_out
  tmp_out="$(mktemp)"
  yq eval "$reorder_expr" "$file" > "$tmp_out"
  mv "$tmp_out" "$file"
}

OUT_USER="$OUTPUT_DIR/user-data"
OUT_META="$OUTPUT_DIR/meta-data"

# Build final user-data by writing the cloud-init header first,
# then merging base user-data, optional boot-mode overrides,
# and host overrides from left to right (later wins).
# The whole grouped block is redirected once to $OUT_USER.
# Example with three inputs:
#   input 0: ./etc/base/user-data.yml
#   input 1: ./etc/boot/user-data.bios.yml
#   input 2: ./etc/hosts/kubi03/user-data.yml
USER_MERGE_FILES=("$USER_BASE")
if [[ -n "$USER_BOOT_FILE" ]]; then
  USER_MERGE_FILES+=("$USER_BOOT_FILE")
fi
USER_MERGE_FILES+=("$TMP_USER")

{
  echo "#cloud-config"
  yq eval-all '
    . as $doc ireduce ({};
      . as $acc
      | ($acc * $doc)
      | .autoinstall.storage.config = (($doc.autoinstall.storage.config // []) + ($acc.autoinstall.storage.config // []))
    )
  ' "${USER_MERGE_FILES[@]}"
} > "$OUT_USER"

reorder_storage_config "$OUT_USER"

yq eval-all '. as $doc ireduce ({}; . * $doc)' "$META_BASE" "$TMP_META" > "$OUT_META"

echo "Generated deployment config for host '$HOST':"
echo "  $OUT_USER"
echo "  $OUT_META"