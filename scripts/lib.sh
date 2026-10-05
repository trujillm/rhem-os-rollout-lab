#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { echo "error: $*" >&2; exit 1; }

ts() { date -u +%Y%m%dT%H%M%SZ; }

load_env() {
  [[ -f "$ROOT/config/env" ]] || die "missing $ROOT/config/env — copy from config/env.example"
  # shellcheck disable=SC1091
  set -a; source "$ROOT/config/env"; set +a
}

require_env() {
  local v
  for v in "$@"; do
    [[ -n "${!v:-}" ]] || die "set $v in config/env"
  done
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null || die "missing command: $c"
  done
}

# update_env KEY VALUE — set/replace `export KEY=VALUE` in config/env (creates the line if
# missing). Used by scripts that discover AWS/AMI identifiers at runtime. Never touches
# config/env.example.
update_env() {
  local key="$1" value="$2" file="$ROOT/config/env"
  [[ -f "$file" ]] || die "missing $file — copy from config/env.example"
  if grep -qE "^export ${key}=" "$file"; then
    sed -i.bak -E "s|^export ${key}=.*|export ${key}=${value}|" "$file" && rm -f "${file}.bak"
  else
    printf 'export %s=%s\n' "$key" "$value" >>"$file"
  fi
  export "$key=$value"
}

# resolve_device — print RHEM device metadata.name for this lab device.
# Prefers exact DEVICE_NAME; falls back to label match on alias, then fleet.
# Requires flightctl session + DEVICE_NAME + FLEET_NAME (DEVICE_ALIAS optional).
resolve_device() {
  require_env DEVICE_NAME FLEET_NAME
  if flightctl get "device/${DEVICE_NAME}" -o name >/dev/null 2>&1; then
    echo "$DEVICE_NAME"
    return 0
  fi
  local alias="${DEVICE_ALIAS:-$DEVICE_NAME}"
  flightctl get devices -o json \
    | ALIAS="$alias" FLEET_NAME="$FLEET_NAME" python3 -c '
import json, sys, os
alias = os.environ.get("ALIAS", "")
fleet = os.environ["FLEET_NAME"]
data = json.load(sys.stdin)
for it in data.get("items") or []:
    labels = ((it.get("metadata") or {}).get("labels") or {})
    if (alias and labels.get("alias") == alias) or labels.get("fleet") == fleet:
        print(it["metadata"]["name"])
        break
'
}
