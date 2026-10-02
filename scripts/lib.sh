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
