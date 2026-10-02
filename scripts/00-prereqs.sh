#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib.sh"

export PATH="${HOME}/.local/bin:${PATH}"

load_env

RESULTS_DIR="$ROOT/results"
mkdir -p "$RESULTS_DIR"
OUT="$RESULTS_DIR/prereqs-$(ts).txt"

hard_fail=0
log() { echo "$*" | tee -a "$OUT"; }
record() {
  local id="$1" status="$2" msg="$3"
  log "[${id}] ${status}: ${msg}"
}

: >"$OUT"
log "=== prerequisites $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

env_ok() {
  local v="$1"
  [[ -n "${!v:-}" ]] && [[ "${!v}" != *REPLACE_ME* ]]
}

# --- P1–P4: operator CLIs ---
for id_cmd in P1:oc P2:flightctl P3:aws P4:podman; do
  id="${id_cmd%%:*}"
  cmd="${id_cmd##*:}"
  if command -v "$cmd" >/dev/null 2>&1; then
    record "$id" PASS "$cmd on PATH ($(command -v "$cmd"))"
  else
    record "$id" FAIL "missing command: $cmd"
    hard_fail=$((hard_fail + 1))
  fi
done

# --- P5: hub env ---
hub_vars=(KUBECONFIG RHEM_CHART_VERSION FLIGHTCTL_API FLIGHTCTL_AGENT_API OCP_APPS_DOMAIN)
hub_missing=()
for v in "${hub_vars[@]}"; do
  [[ -n "${!v:-}" ]] || hub_missing+=("$v")
done
if ((${#hub_missing[@]} == 0)); then
  record P5 PASS "hub env vars set (KUBECONFIG, RHEM_CHART_VERSION, FLIGHTCTL_*, OCP_APPS_DOMAIN)"
else
  record P5 FAIL "missing: ${hub_missing[*]}"
  hard_fail=$((hard_fail + 1))
fi

# --- P6: cluster Available ---
if command -v oc >/dev/null 2>&1 && [[ -n "${KUBECONFIG:-}" ]]; then
  cv_status="$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"
  if [[ "$cv_status" == "True" ]]; then
    record P6 PASS "ClusterVersion Available=True"
  else
    record P6 FAIL "ClusterVersion not Available (status=${cv_status:-unknown})"
    hard_fail=$((hard_fail + 1))
  fi
else
  record P6 FAIL "oc or KUBECONFIG unavailable"
  hard_fail=$((hard_fail + 1))
fi

# --- P7: RHEM pods ---
if command -v oc >/dev/null 2>&1; then
  if ! oc get namespace flightctl >/dev/null 2>&1; then
    record P7 FAIL "namespace flightctl missing"
    hard_fail=$((hard_fail + 1))
  else
    not_ready="$(oc -n flightctl get pods --no-headers 2>/dev/null | awk '$3!="Running" && $3!="Completed" && $3!="Succeeded" {print $1}' | tr '\n' ' ')"
    if [[ -z "${not_ready// }" ]]; then
      record P7 PASS "all flightctl pods Running or Completed"
    else
      record P7 FAIL "pods not ready: ${not_ready}"
      hard_fail=$((hard_fail + 1))
    fi
  fi
else
  record P7 FAIL "oc not available"
  hard_fail=$((hard_fail + 1))
fi

# --- P8: routes ---
if command -v oc >/dev/null 2>&1 && oc get namespace flightctl >/dev/null 2>&1; then
  routes_ok=1
  for r in flightctl-api flightctl-agent-api; do
    if ! oc -n flightctl get route "$r" >/dev/null 2>&1; then
      routes_ok=0
      record P8 FAIL "missing route flightctl/$r"
      hard_fail=$((hard_fail + 1))
      break
    fi
  done
  if [[ "$routes_ok" == 1 ]]; then
    record P8 PASS "routes flightctl-api and flightctl-agent-api present"
  fi
else
  record P8 FAIL "cannot inspect flightctl routes"
  hard_fail=$((hard_fail + 1))
fi

# --- P9: flightctl login + fleets ---
oc_bearer_token() {
  local token
  token="$(oc whoami -t 2>/dev/null || true)"
  if [[ -n "$token" ]]; then
    echo "$token"
    return 0
  fi
  local pwfile
  pwfile="$(dirname "${KUBECONFIG}")/kubeadmin-password"
  [[ -f "$pwfile" ]] || return 1
  local api
  api="$(oc whoami --show-server 2>/dev/null || true)"
  [[ -n "$api" ]] || return 1
  oc login "$api" -u kubeadmin -p "$(<"$pwfile")" --insecure-skip-tls-verify >/dev/null 2>&1 || return 1
  oc whoami -t 2>/dev/null || true
}

if command -v flightctl >/dev/null 2>&1 && command -v oc >/dev/null 2>&1; then
  token="$(oc_bearer_token || true)"
  if [[ -z "$token" ]]; then
    record P9 FAIL "no bearer token (oc login or kubeadmin-password beside kubeconfig)"
    hard_fail=$((hard_fail + 1))
  elif flightctl login "$FLIGHTCTL_API" --token "$token" --insecure-skip-tls-verify >/dev/null 2>&1 \
    && flightctl get fleets >/dev/null 2>&1; then
    record P9 PASS "flightctl login and get fleets succeeded"
  else
    record P9 FAIL "flightctl login or get fleets failed"
    hard_fail=$((hard_fail + 1))
  fi
else
  record P9 FAIL "flightctl or oc not available"
  hard_fail=$((hard_fail + 1))
fi

# --- P10: OS image registry env ---
if env_ok OS_IMAGE_REPO && env_ok OS_IMAGE_GOOD && env_ok OS_IMAGE_BAD; then
  record P10 PASS "OS_IMAGE_REPO/GOOD/BAD set (no REPLACE_ME)"
else
  record P10 FAIL "set OS_IMAGE_* in config/env (replace REPLACE_ME)"
  hard_fail=$((hard_fail + 1))
fi

# --- P11: AWS identity ---
if command -v aws >/dev/null 2>&1; then
  if aws sts get-caller-identity --region "${AWS_REGION:-us-east-2}" >/dev/null 2>&1; then
    arn="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || echo unknown)"
    record P11 PASS "AWS caller identity OK (${arn})"
  else
    record P11 FAIL "aws sts get-caller-identity failed (profile ${AWS_PROFILE:-default})"
    hard_fail=$((hard_fail + 1))
  fi
else
  record P11 FAIL "aws CLI missing"
  hard_fail=$((hard_fail + 1))
fi

# --- P12: EC2 provision env (pending until operator fills) ---
ec2_vars=(EC2_KEY_NAME EC2_SUBNET_ID EC2_SG_ID DEVICE_SSH)
ec2_pending=()
for v in "${ec2_vars[@]}"; do
  env_ok "$v" || ec2_pending+=("$v")
done
if ((${#ec2_pending[@]} == 0)); then
  record P12 PASS "EC2/DEVICE_SSH env ready for provision"
else
  record P12 PENDING "fill after provision: ${ec2_pending[*]}"
fi

# --- P13: worker capacity proxy (flightctl-kv schedules) ---
if command -v oc >/dev/null 2>&1 && oc -n flightctl get deployment flightctl-kv >/dev/null 2>&1; then
  kv_ready="$(oc -n flightctl get deployment flightctl-kv -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  if [[ "${kv_ready:-0}" -ge 1 ]]; then
    record P13 PASS "flightctl-kv ready (worker headroom; see hub/README.md)"
  else
    record P13 FAIL "flightctl-kv not ready — workers need ~m6i.xlarge headroom (hub/README.md)"
    hard_fail=$((hard_fail + 1))
  fi
else
  record P13 FAIL "deployment flightctl-kv not found"
  hard_fail=$((hard_fail + 1))
fi

# --- P14–P18: device / Test 2 (pending until EC2 exists) ---
record P14 PENDING "EC2 bootc device provisioned — run make provision"
record P15 PENDING "device enrolled with fleet=${FLEET_NAME:-os-rollout-test}"
record P16 PENDING "device Online in RHEM"
record P17 PENDING "bootc image-mode on device (image A)"
record P18 PENDING "greenboot / Test 2 feasibility on device"

# --- P19: recovery runbook ---
if [[ -f "$ROOT/config/recovery-runbook.md" ]]; then
  record P19 PASS "config/recovery-runbook.md present"
else
  record P19 FAIL "missing config/recovery-runbook.md"
  hard_fail=$((hard_fail + 1))
fi

log "=== summary: hard_fail=${hard_fail} (see ${OUT}) ==="
exit "$hard_fail"
