#!/usr/bin/env bash
# Baseline verify after enroll: device Online, bootc status, greenboot RPMs,
# agent-api reachability. Writes evidence under results/baseline-<ts>/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib.sh"

SSH_KEY_PATH="${HOME}/.ssh/rhem-os-rollout-lab"

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

ssh_base() {
  ssh -i "$SSH_KEY_PATH" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 "$@"
}

remote_sudo() {
  local cmd="$1"
  printf '%s\n' "$EC2_SSH_PASSWORD" | ssh_base "$DEVICE_SSH" "sudo -S bash -lc $(printf '%q' "$cmd")" 2>/dev/null
}

main() {
  load_env
  require_env KUBECONFIG FLIGHTCTL_API FLIGHTCTL_AGENT_API DEVICE_NAME DEVICE_SSH \
    EC2_SSH_PASSWORD FLEET_NAME
  require_cmd flightctl oc ssh python3 curl
  [[ -f "$SSH_KEY_PATH" ]] || die "missing SSH key $SSH_KEY_PATH"

  local OUT fail=0
  OUT="$ROOT/results/baseline-$(ts)"
  mkdir -p "$OUT/hub" "$OUT/device"
  {
    echo "collected_at_utc=$(ts)"
    echo "DEVICE_NAME=$DEVICE_NAME"
    echo "DEVICE_ALIAS=${DEVICE_ALIAS:-}"
    echo "FLEET_NAME=$FLEET_NAME"
    echo "FLIGHTCTL_API=$FLIGHTCTL_API"
    echo "FLIGHTCTL_AGENT_API=$FLIGHTCTL_AGENT_API"
    echo "DEVICE_SSH=$DEVICE_SSH"
  } >"$OUT/meta.env"

  flightctl_login

  local dev
  dev="$(resolve_device)"
  [[ -n "$dev" ]] || die "could not resolve enrolled device (DEVICE_NAME=${DEVICE_NAME})"
  echo "resolved device: $dev"

  flightctl get "device/${dev}" -o yaml >"$OUT/hub/device.yaml"
  flightctl get "device/${dev}" -o json >"$OUT/hub/device.json"
  flightctl get "fleet/${FLEET_NAME}" -o yaml >"$OUT/hub/fleet.yaml" 2>"$OUT/hub/fleet.err" || true
  flightctl get devices -o wide >"$OUT/hub/devices-wide.txt" 2>&1 || true

  local summary labels owner
  summary="$(python3 -c '
import json
d=json.load(open("'"$OUT/hub/device.json"'"))
print((((d.get("status") or {}).get("summary") or {}).get("status")) or "UNKNOWN")
')"
  labels="$(python3 -c '
import json
d=json.load(open("'"$OUT/hub/device.json"'"))
labs=((d.get("metadata") or {}).get("labels") or {})
print(",".join(f"{k}={v}" for k,v in sorted(labs.items())))
')"
  owner="$(python3 -c '
import json
d=json.load(open("'"$OUT/hub/device.json"'"))
print(((d.get("metadata") or {}).get("owner")) or "")
')"

  echo "summary.status=$summary" | tee "$OUT/hub/summary.txt"
  echo "labels=$labels" | tee -a "$OUT/hub/summary.txt"
  echo "owner=$owner" | tee -a "$OUT/hub/summary.txt"

  if [[ "$summary" != "Online" ]]; then
    echo "FAIL: device not Online (got $summary)" | tee -a "$OUT/verify.txt"
    fail=1
  else
    echo "PASS: device Online" | tee -a "$OUT/verify.txt"
  fi
  if [[ "$labels" != *"fleet=${FLEET_NAME}"* ]]; then
    echo "FAIL: missing fleet=${FLEET_NAME} label (labels=$labels)" | tee -a "$OUT/verify.txt"
    fail=1
  else
    echo "PASS: fleet=${FLEET_NAME} label present" | tee -a "$OUT/verify.txt"
  fi

  # Device SSH probes
  if ! ssh_base "$DEVICE_SSH" true 2>"$OUT/device/ssh-connect.err"; then
    echo "FAIL: SSH to $DEVICE_SSH" | tee -a "$OUT/verify.txt"
    fail=1
  else
    echo "PASS: SSH reachable" | tee -a "$OUT/verify.txt"
  fi

  remote_sudo 'bootc status' >"$OUT/device/bootc-status.txt" 2>&1 || true
  remote_sudo 'bootc status --format=json 2>/dev/null || bootc status --json 2>/dev/null || true' \
    >"$OUT/device/bootc-status.json" 2>&1 || true
  if grep -qi 'booted\|imageDigest\|ostree' "$OUT/device/bootc-status.txt" \
      || grep -q 'imageDigest\|booted' "$OUT/device/bootc-status.json"; then
    echo "PASS: bootc image-mode status present" | tee -a "$OUT/verify.txt"
  else
    echo "FAIL: bootc status missing/unexpected" | tee -a "$OUT/verify.txt"
    fail=1
  fi

  remote_sudo 'rpm -q flightctl-agent greenboot flightctl-greenboot 2>&1' \
    >"$OUT/device/rpm-versions.txt" 2>&1 || true
  if grep -q '^flightctl-agent-' "$OUT/device/rpm-versions.txt" \
      && grep -q '^greenboot-' "$OUT/device/rpm-versions.txt"; then
    echo "PASS: flightctl-agent + greenboot RPMs installed" | tee -a "$OUT/verify.txt"
  else
    echo "FAIL: expected RPMs missing — see rpm-versions.txt" | tee -a "$OUT/verify.txt"
    fail=1
  fi
  if grep -q '^flightctl-greenboot-' "$OUT/device/rpm-versions.txt"; then
    echo "PASS: flightctl-greenboot present (Test 2 gate input)" | tee -a "$OUT/verify.txt"
  else
    echo "WARN: flightctl-greenboot not installed — Test 2 may be blocked" | tee -a "$OUT/verify.txt"
  fi

  remote_sudo 'systemctl is-active flightctl-agent; journalctl -u flightctl-agent -b --no-pager | tail -120' \
    >"$OUT/device/journal-flightctl-agent.txt" 2>&1 || true

  # Agent-api is mTLS: anonymous curl proves TCP/TLS reachability (often exits with
  # "certificate required") but will not return a normal HTTP code.
  remote_sudo "curl -k -v --connect-timeout 10 --max-time 15 ${FLIGHTCTL_AGENT_API}/ 2>&1 | tail -40" \
    >"$OUT/device/agent-api-curl.txt" 2>&1 || true
  if grep -qiE 'Connected to|certificate required|SSL certificate verify result|HTTP/' \
      "$OUT/device/agent-api-curl.txt"; then
    echo "PASS: device can reach agent-api (mTLS endpoint reachable)" | tee -a "$OUT/verify.txt"
  elif grep -qiE 'Enrollment approved|Bootstrap complete|New spec version' \
      "$OUT/device/journal-flightctl-agent.txt"; then
    echo "PASS: agent journal shows hub communication" | tee -a "$OUT/verify.txt"
  else
    echo "FAIL: agent-api not clearly reachable — see agent-api-curl.txt" | tee -a "$OUT/verify.txt"
    fail=1
  fi

  remote_sudo 'test -f /etc/rhem-os-rollout-test/GOOD && echo GOOD; test -f /etc/rhem-os-rollout-test/FAIL && echo FAIL || true' \
    >"$OUT/device/lab-markers.txt" 2>&1 || true

  echo "evidence: $OUT"
  if ((fail)); then
    echo "verify FAILED — see $OUT/verify.txt" >&2
    exit 1
  fi
  echo "verify PASSED"
  echo "$OUT"
}

main "$@"
