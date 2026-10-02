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
