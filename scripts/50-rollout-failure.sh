#!/usr/bin/env bash
# Test 2 — gated failure/recovery: before touching Fleet, run a non-destructive feasibility
# probe for custom greenboot required.d checks (docs/design.md § Test 2 feasibility gate). Only
# if the gate passes (file/env TEST2_GATE=pass, or the live probe itself passes) does this script
# apply image B, poll through greenboot's max boot attempts expecting auto-rollback to A, and
# collect RHEM/bootc evidence. If the gate fails, writes BLOCKED with evidence and does not point
# Fleet at B — investigation only, no invented rollback mechanism. Evidence under
# results/test2-<ts>/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib.sh"

SSH_KEY_PATH="${HOME}/.ssh/rhem-os-rollout-lab"
ROLLOUT_TIMEOUT_SEC="${ROLLOUT_TIMEOUT_SEC:-2700}" # 45m — enough for a few greenboot boot attempts
POLL_INTERVAL_SEC="${POLL_INTERVAL_SEC:-30}"
PROBE_SCRIPT_NAME="50-rollout-failure-probe.sh"

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

resolve_device() {
  if flightctl get "device/${DEVICE_NAME}" -o name >/dev/null 2>&1; then
    echo "$DEVICE_NAME"
    return 0
  fi
  local alias="${DEVICE_ALIAS:-$DEVICE_NAME}"
  flightctl get devices -o json | ALIAS="$alias" python3 -c '
import json,sys,os
alias=os.environ["ALIAS"]
d=json.load(sys.stdin)
for it in d.get("items") or []:
  labels=((it.get("metadata") or {}).get("labels") or {})
  if labels.get("alias")==alias or labels.get("fleet")=="os-rollout-test":
    print(it["metadata"]["name"]); break
'
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

install_device_pull_auth() {
  local authfile="${REGISTRY_AUTH_FILE:-$HOME/.config/containers/auth.json}"
  [[ -f "$authfile" ]] || die "missing registry auth file at $authfile (podman login quay.io first)"
  AUTHFILE="$authfile"
  echo "installing pull auth on device → /etc/ostree/auth.json (from local authfile; secrets not logged)"
  ssh_base "$DEVICE_SSH" "cat > /tmp/ostree-auth.json" <"$authfile"
  remote_sudo 'install -d -m 0755 /etc/ostree && install -m 0600 /tmp/ostree-auth.json /etc/ostree/auth.json && rm -f /tmp/ostree-auth.json && ls -la /etc/ostree/auth.json'
  remote_sudo "skopeo inspect --authfile /etc/ostree/auth.json --format '{{.Digest}}' docker://${OS_IMAGE_BAD} >/tmp/skopeo-probe.out 2>/tmp/skopeo-probe.err; cat /tmp/skopeo-probe.out; echo ---; tail -5 /tmp/skopeo-probe.err" \
    | tee "$OUT/device/pull-auth-probe.txt"
  if ! grep -q '^sha256:' "$OUT/device/pull-auth-probe.txt"; then
    echo "BLOCKED: device cannot pull $OS_IMAGE_BAD with installed auth — see pull-auth-probe.txt" | tee -a "$OUT/result.txt"
    return 1
  fi
  echo "PASS: device can inspect $OS_IMAGE_BAD with /etc/ostree/auth.json" | tee -a "$OUT/result.txt"
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
  remote_sudo 'journalctl -u flightctl-agent -b --no-pager | tail -200' \
    >"$dir/device/journal-flightctl-agent.txt" 2>&1 || true
  remote_sudo 'journalctl -u greenboot-healthcheck -b --no-pager | tail -200' \
    >"$dir/device/journal-greenboot.txt" 2>&1 || true
  remote_sudo 'grub2-editenv - list 2>&1' >"$dir/device/grubenv.txt" 2>&1 || true
  remote_sudo 'test -f /etc/rhem-os-rollout-test/FAIL && echo FAIL; test -f /etc/rhem-os-rollout-test/GOOD && echo GOOD || true' \
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

write_verdict() {
  local verdict="$1" reason="$2"
  {
    echo "verdict=$verdict"
    echo "reason=$reason"
    echo "device=${DEV:-}"
    echo "alias=${DEVICE_ALIAS:-}"
    echo "pre_failure_digest=${PRE_FAILURE_DIGEST:-}"
    echo "target_digest=${TARGET_DIGEST:-}"
    echo "finished_at_utc=$(ts)"
  } | tee "$OUT/verdict.env"
  echo "$verdict: $reason" | tee -a "$OUT/result.txt"
}

# --- Step 1: feasibility probe ---------------------------------------------------------------
# Non-destructive: stages a harmless required.d script (always exits 0) on the device, triggers
# flightctl's own `flightctl-configure-greenboot.service` (the same unit that runs, ordered
# Before=greenboot-healthcheck.service, on every real boot), and checks whether the probe script
# got written into greenboot.conf's DISABLED_HEALTHCHECKS before greenboot would ever evaluate
# it. This is exactly the fate image B's /etc/greenboot/check/required.d/99-rhem-os-rollout-fail.sh
# would face on first boot of B — so the probe answers the design's feasibility question without
# ever pointing Fleet at B. No reboot; conf + probe script are restored/removed afterward.
feasibility_probe() {
  local conf="/etc/greenboot/greenboot.conf"
  local probe_path="/etc/greenboot/check/required.d/${PROBE_SCRIPT_NAME}"
  mkdir -p "$OUT/probe"

  cleanup_probe() {
    remote_sudo "rm -f $probe_path" 2>/dev/null || true
    remote_sudo "if test -f ${conf}.task10-probe.bak; then mv -f ${conf}.task10-probe.bak $conf; fi" \
      2>/dev/null || true
  }
  trap cleanup_probe EXIT

  remote_sudo "cat $conf" >"$OUT/probe/greenboot-conf-before.txt" 2>&1 || true
  remote_sudo "cp -a $conf ${conf}.task10-probe.bak"
  remote_sudo "printf '#!/bin/bash\nexit 0\n' > $probe_path && chmod 755 $probe_path"
  remote_sudo 'systemctl restart flightctl-configure-greenboot.service' \
    >"$OUT/probe/configure-greenboot-restart.txt" 2>&1 || true
  remote_sudo "systemctl status flightctl-configure-greenboot.service --no-pager" \
    >"$OUT/probe/configure-greenboot-status.txt" 2>&1 || true
  remote_sudo "cat $conf" >"$OUT/probe/greenboot-conf-after.txt" 2>&1 || true
  remote_sudo "ls -la /etc/greenboot/check/required.d/" >"$OUT/probe/required-d-listing.txt" 2>&1 || true

  cleanup_probe
  trap - EXIT
  remote_sudo "cat $conf" >"$OUT/probe/greenboot-conf-restored.txt" 2>&1 || true

  if grep -q "$PROBE_SCRIPT_NAME" "$OUT/probe/greenboot-conf-after.txt" 2>/dev/null; then
    echo "blocked"
  else
    echo "pass"
  fi
}

# --- Step 2: gated failure induction (only runs if gate == pass) -----------------------------
# Expect bootc/greenboot to auto-rollback the booted deployment to the pre-failure digest (A)
# after image B's greenboot required check fails; "max boots" = greenboot.conf's
# GREENBOOT_MAX_BOOT_ATTEMPTS, enforced by greenboot itself, not by this script.
#
# Design §7 PASS also requires RHEM to report distinct non-success for the B attempt (RHEM 1.3
# live enums: status.updated.status and status.os.imageDigest from flightctl get device -o json).
rhem_reports_b_non_success() {
  local updated="${HUB_UPDATED_AT_ROLLBACK:-}"
  local osdig="${HUB_OSDIG_AT_ROLLBACK:-}"
  if [[ -z "$updated" ]]; then
    echo "missing hub status.updated.status at rollback detection"
    return 1
  fi
  if [[ "$updated" == "UpToDate" ]]; then
    echo "hub updated.status=UpToDate (expected OutOfDate while fleet still targets B after rollback)"
    return 1
  fi
  if [[ "$updated" != "OutOfDate" ]]; then
    echo "hub updated.status=$updated (expected OutOfDate on this RHEM 1.3 build)"
    return 1
  fi
  if [[ -n "$TARGET_DIGEST" && -n "$osdig" && "$osdig" == "$TARGET_DIGEST" ]]; then
    echo "hub os.imageDigest still reports B ($TARGET_DIGEST) despite bootc rollback to A"
    return 1
  fi
  return 0
}

wait_for_rollback() {
  local deadline=$((SECONDS + ROLLOUT_TIMEOUT_SEC))
  local poll=0
  echo "polling device/${DEV}: expect bootc booted digest to return to $PRE_FAILURE_DIGEST (auto-rollback) after greenboot failure on $TARGET_DIGEST (timeout ${ROLLOUT_TIMEOUT_SEC}s)" \
    | tee -a "$OUT/poll.log"
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
    local bootc_dig
    bootc_dig="$(booted_digest || true)"
    echo "[poll $poll $(ts)] hub: summary=$summary updated=$updated os.digest=$osdig info=$uinfo | bootc.booted=$bootc_dig" \
      | tee -a "$OUT/poll.log"
    if [[ "$bootc_dig" == "$PRE_FAILURE_DIGEST" ]]; then
      HUB_SUMMARY_AT_ROLLBACK="$summary"
      HUB_UPDATED_AT_ROLLBACK="$updated"
      HUB_OSDIG_AT_ROLLBACK="$osdig"
      HUB_INFO_AT_ROLLBACK="updated.status=$updated summary.status=$summary os.imageDigest=$osdig updated.info=$uinfo summary.info=$sinfo"
      echo "[poll $poll] bootc rolled back to pre-failure digest; hub $HUB_INFO_AT_ROLLBACK" | tee -a "$OUT/poll.log"
      return 0
    fi
    sleep "$POLL_INTERVAL_SEC"
  done
  return 1
}

main() {
  load_env
  require_env KUBECONFIG FLIGHTCTL_API DEVICE_NAME DEVICE_SSH EC2_SSH_PASSWORD \
    FLEET_NAME OS_IMAGE_BAD OS_IMAGE_REPO
  require_cmd flightctl oc ssh python3 skopeo
  [[ -f "$SSH_KEY_PATH" ]] || die "missing SSH key $SSH_KEY_PATH"
  [[ "$DEVICE_SSH" != *REPLACE_ME* ]] || die "DEVICE_SSH still placeholder"

  OUT="$ROOT/results/test2-$(ts)"
  mkdir -p "$OUT/hub" "$OUT/device" "$OUT/probe"
  {
    echo "collected_at_utc=$(ts)"
    echo "test=2"
    echo "DEVICE_NAME=$DEVICE_NAME"
    echo "DEVICE_ALIAS=${DEVICE_ALIAS:-}"
    echo "FLEET_NAME=$FLEET_NAME"
    echo "OS_IMAGE_BAD=$OS_IMAGE_BAD"
    echo "ROLLOUT_TIMEOUT_SEC=$ROLLOUT_TIMEOUT_SEC"
    echo "TEST2_GATE_env=${TEST2_GATE:-unset}"
  } >"$OUT/meta.env"
  : >"$OUT/result.txt"

  flightctl_login

  DEV="$(resolve_device)"
  [[ -n "$DEV" ]] || die "could not resolve enrolled device"
  echo "resolved device: $DEV (alias=${DEVICE_ALIAS:-})"

  if ! ssh_base "$DEVICE_SSH" true 2>"$OUT/device/ssh-connect.err"; then
    write_verdict BLOCKED "SSH to $DEVICE_SSH failed"
    exit 2
  fi

  collect_snapshot before

  # --- gate ---
  local gate_result gate_reason
  if [[ "${TEST2_GATE:-}" == "pass" ]]; then
    gate_result=pass
    gate_reason="operator override: TEST2_GATE=pass (config/env or shell env); live probe skipped"
    echo "$gate_reason"
  elif [[ "${TEST2_GATE:-}" == "blocked" ]]; then
    gate_result=blocked
    gate_reason="operator override: TEST2_GATE=blocked"
    echo "$gate_reason"
  else
    gate_result="$(feasibility_probe)"
    if [[ "$gate_result" == pass ]]; then
      gate_reason="live probe: benign script placed in /etc/greenboot/check/required.d was NOT added to DISABLED_HEALTHCHECKS by flightctl-configure-greenboot.service — custom required.d checks appear to be evaluated by greenboot-healthcheck.service on this build"
    else
      gate_reason="live probe: flightctl-configure-greenboot.service (Before=greenboot-healthcheck.service) added the benign probe script to DISABLED_HEALTHCHECKS in /etc/greenboot/greenboot.conf before greenboot-healthcheck.service ran — custom required.d checks are disabled by product automation on this build; only flightctl-shipped checks (20_check_flightctl_agent.sh, DNS, watchdog) can trigger rollback. Image B's 99-rhem-os-rollout-fail.sh would face the same fate and never execute. See $OUT/probe/."
    fi
  fi

  { echo "TEST2_GATE=$gate_result"; echo "reason=$gate_reason"; } | tee "$OUT/gate.env"

  if [[ "$gate_result" != pass ]]; then
    write_verdict BLOCKED "$gate_reason"
    echo "not pointing Fleet at image B (gate=$gate_result) — see $OUT/probe/ and $OUT/gate.env"
    exit 2
  fi

  # --- gated section: only reached when gate_result=pass -----------------------------------
  echo "TEST2_GATE=pass — proceeding to apply image B" | tee -a "$OUT/result.txt"

  AUTHFILE="${REGISTRY_AUTH_FILE:-$HOME/.config/containers/auth.json}"
  if ! install_device_pull_auth; then
    write_verdict BLOCKED "device registry pull auth not usable for $OS_IMAGE_BAD"
    exit 2
  fi

  PRE_FAILURE_DIGEST="$(booted_digest)" || die "could not read booted digest"
  echo "pre_failure_digest=$PRE_FAILURE_DIGEST" | tee -a "$OUT/result.txt"

  TARGET_DIGEST="$(digest_of_ref "$OS_IMAGE_BAD")"
  TARGET_REF="$(repo_of "$OS_IMAGE_BAD")@${TARGET_DIGEST}"
  echo "TARGET_REF=$TARGET_REF (image B)" | tee -a "$OUT/result.txt"

  apply_fleet_image "$TARGET_REF"

  if wait_for_rollback; then
    collect_snapshot after
    local after_bootc
    after_bootc="$(booted_digest)"
    if [[ "$after_bootc" == "$PRE_FAILURE_DIGEST" ]]; then
      local rhem_gate_msg
      if ! rhem_gate_msg="$(rhem_reports_b_non_success)"; then
        write_verdict FAIL "bootc rolled back to $PRE_FAILURE_DIGEST but RHEM did not report distinct non-success for B: $rhem_gate_msg (${HUB_INFO_AT_ROLLBACK:-})"
        echo "evidence: $OUT"
        exit 1
      fi
      write_verdict PASS "auto-rollback to pre-failure digest $PRE_FAILURE_DIGEST after greenboot failure on B ($TARGET_DIGEST); RHEM non-success for B: $rhem_gate_msg; hub ${HUB_INFO_AT_ROLLBACK:-}"
      echo "evidence: $OUT"
      exit 0
    fi
    write_verdict FAIL "rollback polling matched once but current bootc digest=$after_bootc != $PRE_FAILURE_DIGEST"
    echo "evidence: $OUT"
    exit 1
  fi

  collect_snapshot after
  write_verdict FAIL "no auto-rollback to $PRE_FAILURE_DIGEST observed within ${ROLLOUT_TIMEOUT_SEC}s after applying B ($TARGET_DIGEST)"
  echo "evidence: $OUT"
  exit 1
}

main "$@"
