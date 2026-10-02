#!/usr/bin/env bash
# Collect hub (flightctl) JSON/YAML and optional SSH device evidence into results/<label>-<ts>/.
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  echo "usage: $0 <label>" >&2
  echo "  label: short name for this pack (e.g. pre-rollout, post-good, post-failure)" >&2
  exit 1
}

oc_bearer_token() {
  local token pwfile api
  token="$(oc whoami -t 2>/dev/null || true)"
  if [[ -n "$token" ]]; then
    echo "$token"
    return 0
  fi
  pwfile="$(dirname "${KUBECONFIG}")/kubeadmin-password"
  [[ -f "$pwfile" ]] || return 1
  api="$(oc whoami --show-server 2>/dev/null || true)"
  [[ -n "$api" ]] || return 1
  oc login "$api" -u kubeadmin -p "$(<"$pwfile")" --insecure-skip-tls-verify >/dev/null 2>&1 || return 1
  oc whoami -t 2>/dev/null || true
}

flightctl_login() {
  local token
  token="$(oc_bearer_token || true)"
  [[ -n "$token" ]] || die "no OpenShift bearer token (oc login or kubeadmin-password beside KUBECONFIG)"
  flightctl login "$FLIGHTCTL_API" --token "$token" --insecure-skip-tls-verify >/dev/null
}

collect_hub() {
  local hub="$OUT/hub"
  mkdir -p "$hub"

  flightctl version >"$hub/flightctl-version.txt" 2>&1 || true
  flightctl get fleets -o json >"$hub/fleets.json" 2>"$hub/fleets.err" || true
  flightctl get fleet/"$FLEET_NAME" -o yaml >"$hub/fleet-${FLEET_NAME}.yaml" 2>"$hub/fleet-${FLEET_NAME}.err" || true
  flightctl get devices -o json >"$hub/devices.json" 2>"$hub/devices.err" || true
  flightctl get device/"$DEVICE_NAME" -o yaml >"$hub/device-${DEVICE_NAME}.yaml" 2>"$hub/device-${DEVICE_NAME}.err" || true
  flightctl get device/"$DEVICE_NAME" -o json --summary >"$hub/device-${DEVICE_NAME}-summary.json" 2>"$hub/device-${DEVICE_NAME}-summary.err" || true
}

collect_device_ssh() {
  local dev="$OUT/device"
  mkdir -p "$dev"

  if [[ -z "${DEVICE_SSH:-}" ]] || [[ "$DEVICE_SSH" == *REPLACE_ME* ]]; then
    echo "DEVICE_SSH unset or placeholder — skipped device SSH collection" >"$dev/README-skipped.txt"
    return 0
  fi

  local ssh_opts=(-o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new)
  if ! ssh "${ssh_opts[@]}" "$DEVICE_SSH" true 2>"$dev/ssh-connect.err"; then
    echo "SSH to $DEVICE_SSH failed — see ssh-connect.err" >"$dev/README-skipped.txt"
    return 0
  fi

  ssh "${ssh_opts[@]}" "$DEVICE_SSH" 'sudo bootc status' >"$dev/bootc-status.txt" 2>&1 || true
  ssh "${ssh_opts[@]}" "$DEVICE_SSH" 'sudo bootc status --format=json 2>/dev/null || sudo bootc status --json 2>/dev/null || true' >"$dev/bootc-status.json" 2>&1 || true
  ssh "${ssh_opts[@]}" "$DEVICE_SSH" 'rpm -q flightctl-agent greenboot flightctl-greenboot 2>/dev/null || true' >"$dev/rpm-versions.txt" 2>&1 || true
  ssh "${ssh_opts[@]}" "$DEVICE_SSH" 'journalctl -u flightctl-agent -b --no-pager | tail -200' >"$dev/journal-flightctl-agent.txt" 2>&1 || true
  ssh "${ssh_opts[@]}" "$DEVICE_SSH" 'journalctl -u greenboot -b --no-pager | tail -200' >"$dev/journal-greenboot.txt" 2>&1 || true
  ssh "${ssh_opts[@]}" "$DEVICE_SSH" 'test -f /etc/rhem-os-rollout-test/GOOD && echo GOOD || true; test -f /etc/rhem-os-rollout-test/FAIL && echo FAIL || true' >"$dev/lab-markers.txt" 2>&1 || true
}

write_meta() {
  mkdir -p "$OUT"
  {
    echo "collected_at_utc=$(ts)"
    echo "label=$LABEL"
    echo "FLEET_NAME=$FLEET_NAME"
    echo "DEVICE_NAME=$DEVICE_NAME"
    echo "FLIGHTCTL_API=$FLIGHTCTL_API"
    echo "OS_IMAGE_GOOD=${OS_IMAGE_GOOD:-}"
    echo "OS_IMAGE_BAD=${OS_IMAGE_BAD:-}"
    echo "OS_IMAGE_REPO=${OS_IMAGE_REPO:-}"
  } >"$OUT/meta.env"
}

main() {
  [[ $# -ge 1 ]] || usage
  LABEL="$1"

  load_env
  require_env FLEET_NAME DEVICE_NAME FLIGHTCTL_API
  require_cmd flightctl oc ssh

  OUT="$ROOT/results/${LABEL}-$(ts)"
  write_meta
  flightctl_login
  collect_hub
  collect_device_ssh

  echo "$OUT"
}

main "$@"
