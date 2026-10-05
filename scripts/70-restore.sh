#!/usr/bin/env bash
# Restore: point Fleet os.image back at the known-good digest (A/A′), confirm the device
# converges, then two opt-in decommission steps (both default OFF, never run silently):
#   DELETE_FLEET=1   — after restore is confirmed, delete Fleet/$FLEET_NAME from the hub.
#   TERMINATE_EC2=1  — terminate the EC2 device via aws (requires INSTANCE_ID from config/env,
#                      re-confirmed against the live instance's Name tag before terminating).
# Always prints a reminder that cluster teardown (`openshift-install destroy`) is a separate,
# operator-owned step outside this repo. Evidence under results/restore-<ts>/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib.sh"

SSH_KEY_PATH="${HOME}/.ssh/rhem-os-rollout-lab"
ROLLOUT_TIMEOUT_SEC="${ROLLOUT_TIMEOUT_SEC:-900}" # 15m — target is already known-good, expect fast converge
POLL_INTERVAL_SEC="${POLL_INTERVAL_SEC:-30}"
# Opt-in only. Never decommission by default.
TERMINATE_EC2="${TERMINATE_EC2:-0}"
DELETE_FLEET="${DELETE_FLEET:-0}"

# --- hub/device helpers (same patterns as scripts/40-rollout-good.sh) -----------------------

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

booted_digest() {
  local json
  json="$(remote_sudo 'bootc status --format=json 2>/dev/null || bootc status --json 2>/dev/null')"
  [[ -n "$json" ]] || return 1
  printf '%s' "$json" | python3 -c '
import json,sys
raw=sys.stdin.read()
d=json.loads(raw[raw.find("{"):])
booted=(d.get("status") or d).get("booted") or {}
img=booted.get("image") or {}
digest=img.get("imageDigest") or ""
print(digest)
'
}

repo_of() {
  local ref="$1"
  if [[ "$ref" == *"@"* ]]; then
    echo "${ref%%@*}"
  else
    echo "${ref%%:*}"
  fi
}

digest_of_ref() {
  local ref="$1" dig attempt=1
  while ((attempt <= 5)); do
    if dig="$(skopeo inspect --authfile "$AUTHFILE" --format '{{.Digest}}' "docker://$ref" 2>/dev/null)"; then
      [[ -n "$dig" ]] && { echo "$dig"; return 0; }
    fi
    echo "warn: skopeo inspect $ref failed (attempt $attempt/5); retrying..." >&2
    sleep $((attempt * 3))
    attempt=$((attempt + 1))
  done
  die "skopeo inspect failed for $ref after retries"
}

apply_fleet_image() {
  local image_ref="$1"
  local src="$ROOT/fleet/fleet-${FLEET_NAME}.yaml"
  local tmp
  [[ -f "$src" ]] || die "missing fleet manifest $src"
  tmp="$(mktemp)"
  IMAGE_REF="$image_ref" python3 - "$src" "$tmp" <<'PY'
import os, sys, yaml
src, dst = sys.argv[1], sys.argv[2]
image = os.environ["IMAGE_REF"]
with open(src) as f:
    doc = yaml.safe_load(f)
spec = doc.setdefault("spec", {}).setdefault("template", {}).setdefault("spec", {})
spec["os"] = {"image": image}
spec.setdefault("applications", [])
spec.setdefault("config", [])
spec.setdefault("systemd", {"matchPatterns": []})
with open(dst, "w") as f:
    yaml.safe_dump(doc, f, sort_keys=False)
PY
  grep -q REPLACE_ "$tmp" && die "fleet YAML still contains REPLACE_ placeholder"
  echo "applying Fleet/$FLEET_NAME with os.image=$image_ref"
  flightctl apply -f "$tmp" | tee "$OUT/hub/fleet-apply.txt"
  cp "$tmp" "$OUT/hub/fleet-applied.yaml"
  rm -f "$tmp"
}

device_status_fields() {
  local dev="$1"
  flightctl get "device/${dev}" -o json | python3 -c '
import json,sys
d=json.load(sys.stdin)
st=d.get("status") or {}
summary=((st.get("summary") or {}).get("status")) or ""
updated=((st.get("updated") or {}).get("status")) or ""
osimg=((st.get("os") or {}).get("image")) or ""
osdig=((st.get("os") or {}).get("imageDigest")) or ""
rv=((st.get("config") or {}).get("renderedVersion")) if isinstance(st.get("config"), dict) else ""
print(summary)
print(updated)
print(osdig)
print(osimg)
print(rv)
print(((st.get("updated") or {}).get("info")) or "")
print(((st.get("summary") or {}).get("info")) or "")
'
}

collect_snapshot() {
  local phase="$1" # before|after
  local dir="$OUT/$phase"
  mkdir -p "$dir/hub" "$dir/device"
  flightctl get "device/${DEV}" -o yaml >"$dir/hub/device.yaml" 2>"$dir/hub/device.err" || true
  flightctl get "device/${DEV}" -o json >"$dir/hub/device.json" 2>"$dir/hub/device.json.err" || true
  flightctl get "fleet/${FLEET_NAME}" -o yaml >"$dir/hub/fleet.yaml" 2>"$dir/hub/fleet.err" || true
  remote_sudo 'bootc status' >"$dir/device/bootc-status.txt" 2>&1 || true
  remote_sudo 'bootc status --format=json 2>/dev/null || bootc status --json 2>/dev/null || true' \
    >"$dir/device/bootc-status.json" 2>&1 || true
  remote_sudo 'test -f /etc/rhem-os-rollout-test/GOOD && echo GOOD; test -f /etc/rhem-os-rollout-test/A-PRIME && echo -n "A-PRIME="; cat /etc/rhem-os-rollout-test/A-PRIME 2>/dev/null; test -f /etc/rhem-os-rollout-test/FAIL && echo FAIL || true' \
    >"$dir/device/lab-markers.txt" 2>&1 || true
  {
    echo "phase=$phase"
    echo "collected_at_utc=$(ts)"
    device_status_fields "$DEV" | {
      read -r summary; read -r updated; read -r osdig; read -r osimg; read -r rv; read -r uinfo; read -r sinfo
      echo "summary.status=$summary"
      echo "updated.status=$updated"
      echo "os.imageDigest=$osdig"
      echo "os.image=$osimg"
      echo "renderedVersion=$rv"
      echo "updated.info=$uinfo"
      echo "summary.info=$sinfo"
    }
  } | tee "$dir/snapshot.env"
}

wait_for_restore() {
  local deadline=$((SECONDS + ROLLOUT_TIMEOUT_SEC))
  local summary updated osdig bootc_dig poll=0
  echo "polling device/${DEV} for Online + UpToDate + digest=$TARGET_DIGEST (timeout ${ROLLOUT_TIMEOUT_SEC}s)..."
  while ((SECONDS < deadline)); do
    poll=$((poll + 1))
    local summary="" updated="" osdig="" osimg="" rv="" uinfo="" sinfo=""
    {
      IFS= read -r summary
      IFS= read -r updated
      IFS= read -r osdig
      IFS= read -r osimg
      IFS= read -r rv
      IFS= read -r uinfo
      IFS= read -r sinfo
    } < <(device_status_fields "$DEV")
    echo "[poll $poll $(ts)] summary=$summary updated=$updated os.digest=$osdig info=$uinfo" | tee -a "$OUT/poll.log"
    if [[ "$summary" == "Online" && "$updated" == "UpToDate" && "$osdig" == "$TARGET_DIGEST" ]]; then
      bootc_dig="$(booted_digest || true)"
      echo "[poll $poll] hub matched; bootc booted=$bootc_dig" | tee -a "$OUT/poll.log"
      if [[ "$bootc_dig" == "$TARGET_DIGEST" ]]; then
        echo "restore converged" | tee -a "$OUT/poll.log"
        return 0
      fi
    fi
    sleep "$POLL_INTERVAL_SEC"
  done
  echo "TIMEOUT after ${ROLLOUT_TIMEOUT_SEC}s — last summary=$summary updated=$updated os.digest=$osdig" | tee -a "$OUT/poll.log"
  return 1
}

write_verdict() {
  local verdict="$1" reason="$2"
  {
    echo "verdict=$verdict"
    echo "reason=$reason"
    echo "target_digest=${TARGET_DIGEST:-}"
    echo "device=${DEV:-}"
    echo "alias=${DEVICE_ALIAS:-}"
    echo "fleet_deleted=${FLEET_DELETED:-0}"
    echo "ec2_terminated=${EC2_TERMINATED:-0}"
    echo "finished_at_utc=$(ts)"
  } | tee "$OUT/verdict.env"
  echo "$verdict: $reason" | tee -a "$OUT/result.txt"
}

print_cluster_destroy_reminder() {
  local cluster_dir="…/matrujil-rhem"
  if [[ -n "${KUBECONFIG:-}" ]]; then
    cluster_dir="$(cd "$(dirname "$KUBECONFIG")/.." && pwd 2>/dev/null)" || cluster_dir="…/matrujil-rhem"
  fi
  cat <<EOF | tee -a "$OUT/result.txt"

REMINDER (operator-owned, not run by this script):
  Cluster teardown for the RHEM hub is a separate step outside this repo:
    openshift-install destroy cluster --dir ${cluster_dir}
EOF
}

maybe_delete_fleet() {
  FLEET_DELETED=0
  [[ "$DELETE_FLEET" == "1" ]] || return 0
  echo "DELETE_FLEET=1 — decommissioning Fleet/$FLEET_NAME (device already restored to $TARGET_DIGEST)" \
    | tee -a "$OUT/result.txt"
  flightctl delete "fleet/${FLEET_NAME}" | tee "$OUT/hub/fleet-delete.txt"
  FLEET_DELETED=1
}

maybe_terminate_ec2() {
  EC2_TERMINATED=0
  [[ "$TERMINATE_EC2" == "1" ]] || return 0
  require_cmd aws
  require_env INSTANCE_ID AWS_REGION
  [[ "$INSTANCE_ID" != *REPLACE_ME* ]] || die "TERMINATE_EC2=1 but INSTANCE_ID is still a placeholder in config/env"

  echo "TERMINATE_EC2=1 — confirming instance $INSTANCE_ID before terminating" | tee -a "$OUT/result.txt"
  local name_tag
  name_tag="$(aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[].Instances[].Tags[?Key==`Name`].Value' --output text 2>"$OUT/hub/ec2-describe.err" \
    | tee "$OUT/hub/ec2-describe-name-tag.txt")" || die "aws ec2 describe-instances failed for $INSTANCE_ID (see $OUT/hub/ec2-describe.err)"
  [[ "$name_tag" == "${DEVICE_ALIAS:-$DEVICE_NAME}" ]] \
    || die "refusing to terminate $INSTANCE_ID: Name tag '$name_tag' != expected '${DEVICE_ALIAS:-$DEVICE_NAME}'"

  aws ec2 terminate-instances --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" \
    | tee "$OUT/hub/ec2-terminate.json"
  EC2_TERMINATED=1
  echo "terminated EC2 instance $INSTANCE_ID (Name=$name_tag)" | tee -a "$OUT/result.txt"
}

main() {
  load_env
  require_env KUBECONFIG FLIGHTCTL_API DEVICE_NAME DEVICE_SSH EC2_SSH_PASSWORD \
    FLEET_NAME OS_IMAGE_GOOD OS_IMAGE_REPO
  require_cmd flightctl oc ssh python3 skopeo
  [[ -f "$SSH_KEY_PATH" ]] || die "missing SSH key $SSH_KEY_PATH"
  [[ "$DEVICE_SSH" != *REPLACE_ME* ]] || die "DEVICE_SSH still placeholder"

  OUT="$ROOT/results/restore-$(ts)"
  mkdir -p "$OUT/hub" "$OUT/device"
  {
    echo "collected_at_utc=$(ts)"
    echo "test=restore"
    echo "DEVICE_NAME=$DEVICE_NAME"
    echo "DEVICE_ALIAS=${DEVICE_ALIAS:-}"
    echo "FLEET_NAME=$FLEET_NAME"
    echo "OS_IMAGE_GOOD=$OS_IMAGE_GOOD"
    echo "TERMINATE_EC2=$TERMINATE_EC2"
    echo "DELETE_FLEET=$DELETE_FLEET"
  } >"$OUT/meta.env"
  : >"$OUT/result.txt"

  flightctl_login

  DEV="$(resolve_device)"
  [[ -n "$DEV" ]] || die "could not resolve enrolled device"
  echo "resolved device: $DEV (alias=${DEVICE_ALIAS:-})"

  if ! ssh_base "$DEVICE_SSH" true 2>"$OUT/device/ssh-connect.err"; then
    write_verdict BLOCKED "SSH to $DEVICE_SSH failed"
    print_cluster_destroy_reminder
    exit 2
  fi

  AUTHFILE="${REGISTRY_AUTH_FILE:-$HOME/.config/containers/auth.json}"
  [[ -f "$AUTHFILE" ]] || die "missing registry auth file at $AUTHFILE (podman login quay.io first)"

  # Explicit pin wins (operator override to a recorded-good digest); else resolve :good tag.
  if [[ -n "${OS_IMAGE_TARGET:-}" ]]; then
    TARGET_REF="$OS_IMAGE_TARGET"
    if [[ "$TARGET_REF" == *"@"* ]]; then
      TARGET_DIGEST="${TARGET_REF##*@}"
    else
      TARGET_DIGEST="$(digest_of_ref "$TARGET_REF")"
      TARGET_REF="$(repo_of "$TARGET_REF")@${TARGET_DIGEST}"
    fi
    echo "using OS_IMAGE_TARGET=$TARGET_REF" | tee -a "$OUT/result.txt"
  else
    TARGET_DIGEST="$(digest_of_ref "$OS_IMAGE_GOOD")"
    TARGET_REF="$(repo_of "$OS_IMAGE_GOOD")@${TARGET_DIGEST}"
    echo "using current :good tag digest as restore target: $TARGET_REF" | tee -a "$OUT/result.txt"
  fi

  collect_snapshot before

  apply_fleet_image "$TARGET_REF"

  if ! wait_for_restore; then
    collect_snapshot after
    write_verdict FAIL "restore did not reach Online+UpToDate on $TARGET_DIGEST within ${ROLLOUT_TIMEOUT_SEC}s"
    print_cluster_destroy_reminder
    echo "evidence: $OUT"
    exit 1
  fi

  collect_snapshot after
  local after_bootc
  after_bootc="$(booted_digest)"
  if [[ "$after_bootc" != "$TARGET_DIGEST" ]]; then
    write_verdict FAIL "hub UpToDate but bootc digest=$after_bootc != $TARGET_DIGEST"
    print_cluster_destroy_reminder
    echo "evidence: $OUT"
    exit 1
  fi

  maybe_delete_fleet
  maybe_terminate_ec2
  write_verdict PASS "device Online+UpToDate on known-good digest $TARGET_DIGEST; bootc agrees (fleet_deleted=$FLEET_DELETED ec2_terminated=$EC2_TERMINATED)"
  print_cluster_destroy_reminder
  echo "evidence: $OUT"
}

main "$@"
