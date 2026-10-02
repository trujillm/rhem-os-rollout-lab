#!/usr/bin/env bash
# Late-bind enrollment config onto the EC2 bootc device, approve the enrollment
# request with fleet=os-rollout-test, and apply the Fleet pinned to the currently
# booted digest (no OS change yet).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib.sh"

SSH_KEY_PATH="${HOME}/.ssh/rhem-os-rollout-lab"
FLEET_LABEL="fleet=os-rollout-test"

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

# Run a remote command with sudo -S (image A has no NOPASSWD wheel).
remote_sudo() {
  local cmd="$1"
  printf '%s\n' "$EC2_SSH_PASSWORD" | ssh_base "$DEVICE_SSH" "sudo -S bash -lc $(printf '%q' "$cmd")" 2>/dev/null
}

booted_digest_ref() {
  local json image digest
  json="$(remote_sudo 'bootc status --format=json 2>/dev/null || bootc status --json 2>/dev/null')"
  [[ -n "$json" ]] || die "could not read bootc status JSON from $DEVICE_SSH"
  image="$(printf '%s' "$json" | python3 -c '
import json,sys
raw=sys.stdin.read()
d=json.loads(raw[raw.find("{"):])
booted=(d.get("status") or d).get("booted") or {}
img=booted.get("image") or {}
inner=img.get("image") if isinstance(img.get("image"), dict) else {}
ref=inner.get("image") or (img.get("image") if isinstance(img.get("image"), str) else None) or ""
digest=img.get("imageDigest") or ""
print(ref)
print(digest)
')"
  digest="$(printf '%s\n' "$image" | sed -n '2p')"
  image="$(printf '%s\n' "$image" | sed -n '1p')"
  [[ -n "$image" && -n "$digest" ]] || die "failed to parse booted image/digest from bootc status"
  # Prefer repo@digest over tag so enroll does not trigger a tag-moving rollout.
  local repo="${image%%:*}"
  [[ "$image" == *"@"* ]] && repo="${image%%@*}"
  echo "${repo}@${digest}"
}

apply_fleet_baseline() {
  # Omit os.image at enroll time. Pinning the booted digest still triggers an agent
  # prefetch against Quay; private repos return unauthorized and the device goes
  # OutOfDate. Test 1 (rollout scripts) will set a digest-pinned os.image later.
  local src="$ROOT/fleet/fleet-${FLEET_NAME}.yaml"
  local tmp
  [[ -f "$src" ]] || die "missing fleet manifest $src"
  tmp="$(mktemp)"
  python3 - "$src" "$tmp" <<'PY'
import sys, yaml
src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    doc = yaml.safe_load(f)
spec = doc.setdefault("spec", {}).setdefault("template", {}).setdefault("spec", {})
spec.pop("os", None)
# Ensure stable empty collections from the repo template.
spec.setdefault("applications", [])
spec.setdefault("config", [])
spec.setdefault("systemd", {"matchPatterns": []})
with open(dst, "w") as f:
    yaml.safe_dump(doc, f, sort_keys=False)
PY
  grep -q REPLACE_ "$tmp" && die "fleet YAML still contains REPLACE_ placeholder"
  echo "applying Fleet/$FLEET_NAME without os.image (baseline; digest pin deferred to Test 1)"
  flightctl apply -f "$tmp"
  rm -f "$tmp"
}

install_agent_config() {
  local cfg="$1"
  echo "installing enrollment config on $DEVICE_SSH:/etc/flightctl/config.yaml"
  # Stream file over SSH; avoid putting secrets on the argv of remote processes longer than needed.
  ssh_base "$DEVICE_SSH" "cat > /tmp/flightctl-config.yaml" <"$cfg"
  remote_sudo 'install -d -m 0755 /etc/flightctl && install -m 0600 /tmp/flightctl-config.yaml /etc/flightctl/config.yaml && rm -f /tmp/flightctl-config.yaml && systemctl restart flightctl-agent'
}

wait_enrollment_request() {
  local tries=0 er name
  echo "waiting for EnrollmentRequest from device (alias=${DEVICE_ALIAS})..." >&2
  while ((tries < 60)); do
    er="$(flightctl get enrollmentrequests -o json 2>/dev/null || true)"
    name="$(
      printf '%s' "$er" | DEVICE_ALIAS="$DEVICE_ALIAS" python3 -c '
import json,sys,os
alias=os.environ.get("DEVICE_ALIAS","")
try:
  d=json.load(sys.stdin)
except Exception:
  sys.exit(0)
pending=[]
for it in d.get("items") or []:
  st=(it.get("status") or {}).get("approval") or {}
  if st.get("approved") is True:
    continue
  labels=((it.get("metadata") or {}).get("labels") or {})
  pending.append((it["metadata"]["name"], labels))
for name, labels in pending:
  if alias and labels.get("alias") == alias:
    print(name); raise SystemExit
if pending:
  print(pending[0][0])
'
    )"
    if [[ -n "$name" ]]; then
      echo "$name"
      return 0
    fi
    tries=$((tries + 1))
    sleep 5
  done
  die "no pending EnrollmentRequest appeared after ${tries} tries — check agent journal on device"
}

approve_enrollment() {
  local er_name="$1"
  echo "approving enrollmentrequest/${er_name} with -l ${FLEET_LABEL} -l alias=${DEVICE_ALIAS}"
  flightctl approve "enrollmentrequest/${er_name}" \
    -l "$FLEET_LABEL" \
    -l "alias=${DEVICE_ALIAS}"
}

find_device_by_alias() {
  flightctl get devices -o json 2>/dev/null \
    | DEVICE_ALIAS="$DEVICE_ALIAS" FLEET_NAME="$FLEET_NAME" python3 -c '
import json,sys,os
alias=os.environ.get("DEVICE_ALIAS","")
fleet=os.environ.get("FLEET_NAME","os-rollout-test")
d=json.load(sys.stdin)
for it in d.get("items") or []:
  labels=((it.get("metadata") or {}).get("labels") or {})
  if (alias and labels.get("alias")==alias) or labels.get("fleet")==fleet:
    print(it["metadata"]["name"]); break
' || true
}

resolve_device_name() {
  local tries=0 name
  while ((tries < 36)); do
    name="$(find_device_by_alias)"
    if [[ -n "$name" ]]; then
      echo "$name"
      return 0
    fi
    tries=$((tries + 1))
    sleep 5
  done
  die "enrolled device with alias=${DEVICE_ALIAS} not found in inventory"
}

wait_device_online() {
  local dev="$1" tries=0 status
  echo "waiting for device/${dev} Online..."
  while ((tries < 36)); do
    status="$(flightctl get "device/${dev}" -o json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
print((((d.get("status") or {}).get("summary") or {}).get("status")) or "")
' || true)"
    if [[ "$status" == "Online" ]]; then
      echo "device/${dev} status.summary.status=Online"
      return 0
    fi
    tries=$((tries + 1))
    sleep 5
  done
  flightctl get "device/${dev}" -o yaml || true
  die "device/${dev} did not become Online (last summary.status=${status:-empty})"
}

main() {
  load_env
  require_env KUBECONFIG FLIGHTCTL_API FLIGHTCTL_AGENT_API DEVICE_NAME DEVICE_SSH \
    EC2_SSH_PASSWORD FLEET_NAME
  require_cmd flightctl oc ssh python3
  [[ -f "$SSH_KEY_PATH" ]] || die "missing SSH key $SSH_KEY_PATH"
  [[ "$DEVICE_SSH" != *REPLACE_ME* ]] || die "DEVICE_SSH still placeholder"

  # Human-readable lab identity stays as alias; RHEM 1.3 device metadata.name is an
  # agent-generated base32 hash and cannot be chosen (see RHEM Managing devices docs).
  if [[ -z "${DEVICE_ALIAS:-}" ]]; then
    # Prefer a non-hash DEVICE_NAME (first enroll); otherwise keep a stable lab alias.
    if [[ "$DEVICE_NAME" == os-rollout-test-* && ${#DEVICE_NAME} -lt 40 ]]; then
      DEVICE_ALIAS="$DEVICE_NAME"
    else
      DEVICE_ALIAS="os-rollout-test-01"
    fi
  fi
  update_env DEVICE_ALIAS "$DEVICE_ALIAS"

  flightctl_login

  # Idempotent path: already enrolled with fleet label.
  if existing="$(find_device_by_alias)" && [[ -n "$existing" ]]; then
    local labs
    labs="$(flightctl get "device/${existing}" -o json | python3 -c '
import json,sys
d=json.load(sys.stdin)
labs=((d.get("metadata") or {}).get("labels") or {})
print(labs.get("fleet",""))
')"
    if [[ "$labs" == "$FLEET_NAME" ]]; then
      update_env DEVICE_NAME "$existing"
      echo "device/${existing} already enrolled with fleet=${FLEET_NAME} — ensuring Online"
      wait_device_online "$existing"
      echo "enroll complete (idempotent):"
      flightctl get "device/${existing}" -o yaml | head -40
      return 0
    fi
  fi

  local er_name real_name work
  # Still record the booted digest for evidence/operators; do not apply it to Fleet yet.
  echo "booted digest-pinned ref (not applied at enroll): $(booted_digest_ref)"
  apply_fleet_baseline

  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT

  echo "requesting enrollment certificate (CSR name prefix=${DEVICE_ALIAS})..."
  flightctl certificate request \
    -n "$DEVICE_ALIAS" \
    --signer=flightctl.io/enrollment \
    --expiration=365d \
    --output=embedded \
    -d "$work" \
    >"$work/config.yaml" 2>"$work/certificate-request.log"

  # Ensure agent proposes fleet + alias even before CLI approve merge.
  {
    echo
    echo "default-labels:"
    echo "  alias: ${DEVICE_ALIAS}"
    echo "  fleet: ${FLEET_NAME}"
  } >>"$work/config.yaml"

  install_agent_config "$work/config.yaml"

  er_name="$(wait_enrollment_request)"
  approve_enrollment "$er_name"

  real_name="$(resolve_device_name)"
  update_env DEVICE_NAME "$real_name"
  echo "DEVICE_NAME=${real_name} (alias=${DEVICE_ALIAS}) written to config/env"

  wait_device_online "$real_name"

  echo "enroll complete:"
  flightctl get "device/${real_name}" -o yaml | head -60
}

main "$@"
