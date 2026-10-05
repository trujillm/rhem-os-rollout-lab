#!/usr/bin/env bash
# Test 1 — known-good OS rollout: install private-registry pull auth on the device,
# optionally build a visible A′ marker bump, apply Fleet os.image digest pin, poll
# until Online/UpToDate + bootc agree. Evidence under results/test1-<ts>/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib.sh"

SSH_KEY_PATH="${HOME}/.ssh/rhem-os-rollout-lab"
ROLLOUT_TIMEOUT_SEC="${ROLLOUT_TIMEOUT_SEC:-2700}" # 45m
POLL_INTERVAL_SEC="${POLL_INTERVAL_SEC:-30}"
# BUILD_APRIME=auto|1|0 — auto builds A′ when device already runs OS_IMAGE_GOOD digest.
BUILD_APRIME="${BUILD_APRIME:-auto}"

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
  # Strip tag or @digest → repository path
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

# Install Quay (etc.) pull credentials for bootc at /etc/ostree/auth.json.
# Source: REGISTRY_AUTH_FILE or ~/.config/containers/auth.json (never committed).
install_device_pull_auth() {
  local authfile="${REGISTRY_AUTH_FILE:-$HOME/.config/containers/auth.json}"
  [[ -f "$authfile" ]] || die "missing registry auth file at $authfile (podman login quay.io first)"
  AUTHFILE="$authfile"
  echo "installing pull auth on device → /etc/ostree/auth.json (from local authfile; secrets not logged)"
  ssh_base "$DEVICE_SSH" "cat > /tmp/ostree-auth.json" <"$authfile"
  remote_sudo 'install -d -m 0755 /etc/ostree && install -m 0600 /tmp/ostree-auth.json /etc/ostree/auth.json && rm -f /tmp/ostree-auth.json && ls -la /etc/ostree/auth.json'
  # Prove the device can authenticate to the private repo without printing creds.
  remote_sudo "skopeo inspect --authfile /etc/ostree/auth.json --format '{{.Digest}}' docker://${OS_IMAGE_GOOD} >/tmp/skopeo-probe.out 2>/tmp/skopeo-probe.err; cat /tmp/skopeo-probe.out; echo ---; tail -5 /tmp/skopeo-probe.err" \
    | tee "$OUT/device/pull-auth-probe.txt"
  if ! grep -q '^sha256:' "$OUT/device/pull-auth-probe.txt"; then
    echo "BLOCKED: device cannot pull $OS_IMAGE_GOOD with installed auth — see pull-auth-probe.txt" | tee -a "$OUT/result.txt"
    return 1
  fi
  echo "PASS: device can inspect $OS_IMAGE_GOOD with /etc/ostree/auth.json" | tee -a "$OUT/result.txt"
}

# Thin A′ layer: FROM current good + visible marker file. Uses ephemeral cluster buildah
# (same pattern as scripts/10-build-images.sh BUILD_MODE=cluster). Pushes :good (new digest).
build_aprime() {
  local ns="os-rollout-aprime" marker tag_ref digest digest_before
  marker="A-PRIME-$(ts)"
  tag_ref="$OS_IMAGE_GOOD"
  echo "building A′ marker bump ($marker) via cluster buildah → $tag_ref"

  digest_before="$(digest_of_ref "$tag_ref")"

  cleanup_aprime() { oc delete namespace "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
  trap cleanup_aprime EXIT

  oc delete namespace "$ns" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  oc create namespace "$ns" || die "oc create namespace $ns failed"
  oc adm policy add-scc-to-user privileged -z default -n "$ns" >/dev/null \
    || die "oc adm policy add-scc-to-user failed in $ns"
  oc create secret generic registry-auth -n "$ns" --from-file="auth.json=$AUTHFILE" \
    || die "oc create secret registry-auth failed in $ns"

  oc run buildah --image=quay.io/buildah/stable -n "$ns" \
    --overrides='{"spec":{"securityContext":{"runAsUser":0},"containers":[{"name":"buildah","image":"quay.io/buildah/stable","command":["sleep","infinity"],"securityContext":{"privileged":true},"volumeMounts":[{"name":"regauth","mountPath":"/run/secrets/registry"}]}],"volumes":[{"name":"regauth","secret":{"secretName":"registry-auth"}}]}}' \
    || die "oc run buildah failed in $ns"
  oc wait --for=condition=Ready pod/buildah -n "$ns" --timeout=180s \
    || die "buildah pod did not become Ready in $ns"

  # Env BASE/TAG/MARKER expand inside the remote bash -c (heredoc is single-quoted).
  local remote_script
  remote_script="$(cat <<'REMOTE'
set -euo pipefail
AUTH=/run/secrets/registry/auth.json
CTR=$(buildah from --authfile "$AUTH" "$BASE")
buildah run "$CTR" -- mkdir -p /etc/rhem-os-rollout-test
buildah run "$CTR" -- sh -c "printf '%s\n' \"$MARKER\" > /etc/rhem-os-rollout-test/A-PRIME"
buildah run "$CTR" -- touch /etc/rhem-os-rollout-test/GOOD
buildah commit "$CTR" "$TAG"
buildah push --authfile "$AUTH" "$TAG" "docker://$TAG"
buildah rm "$CTR" >/dev/null
REMOTE
)"
  oc exec -n "$ns" buildah -- env "BASE=$tag_ref" "TAG=$tag_ref" "MARKER=$marker" \
    bash -c "$remote_script" || die "cluster buildah A′ build/push failed in $ns"

  digest="$(digest_of_ref "$tag_ref")"
  if [[ "$digest" == "$digest_before" ]]; then
    die "A′ build did not change $tag_ref digest (still $digest)"
  fi
  echo "A′ pushed: $tag_ref@$digest (marker=$marker)" | tee "$OUT/aprime.txt"
  TARGET_REF="$(repo_of "$tag_ref")@${digest}"
  TARGET_DIGEST="$digest"
  TARGET_KIND="A-prime"
  A_PRIME_MARKER="$marker"

  cleanup_aprime
  trap - EXIT
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
  local phase="$1" # before|during|after
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

wait_for_rollout() {
  local deadline=$((SECONDS + ROLLOUT_TIMEOUT_SEC))
  local summary updated osdig bootc_dig poll=0
  echo "polling device/${DEV} for Online + UpToDate + digest=$TARGET_DIGEST (timeout ${ROLLOUT_TIMEOUT_SEC}s)..."
  while ((SECONDS < deadline)); do
    poll=$((poll + 1))
    # bash 3.2 (macOS /bin/bash) has no mapfile — read lines manually.
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
        echo "rollout converged" | tee -a "$OUT/poll.log"
        return 0
      fi
    fi
    # Capture a mid-rollout snapshot once when we first see activity.
    if [[ "$updated" != "UpToDate" || "$osdig" == "$TARGET_DIGEST" ]] && [[ ! -f "$OUT/during/snapshot.env" ]]; then
      collect_snapshot during || true
    fi
    sleep "$POLL_INTERVAL_SEC"
  done
  collect_snapshot during || true
  echo "TIMEOUT after ${ROLLOUT_TIMEOUT_SEC}s — last summary=$summary updated=$updated os.digest=$osdig" | tee -a "$OUT/poll.log"
  return 1
}

write_verdict() {
  local verdict="$1" reason="$2"
  {
    echo "verdict=$verdict"
    echo "reason=$reason"
    echo "target_kind=${TARGET_KIND:-}"
    echo "target_ref=${TARGET_REF:-}"
    echo "target_digest=${TARGET_DIGEST:-}"
    echo "device=$DEV"
    echo "alias=${DEVICE_ALIAS:-}"
    echo "finished_at_utc=$(ts)"
  } | tee "$OUT/verdict.env"
  echo "$verdict: $reason" | tee -a "$OUT/result.txt"
}

main() {
  load_env
  require_env KUBECONFIG FLIGHTCTL_API DEVICE_NAME DEVICE_SSH EC2_SSH_PASSWORD \
    FLEET_NAME OS_IMAGE_GOOD OS_IMAGE_REPO
  require_cmd flightctl oc ssh python3 skopeo
  [[ -f "$SSH_KEY_PATH" ]] || die "missing SSH key $SSH_KEY_PATH"
  [[ "$DEVICE_SSH" != *REPLACE_ME* ]] || die "DEVICE_SSH still placeholder"

  OUT="$ROOT/results/test1-$(ts)"
  mkdir -p "$OUT/hub" "$OUT/device"
  {
    echo "collected_at_utc=$(ts)"
    echo "test=1"
    echo "DEVICE_NAME=$DEVICE_NAME"
    echo "DEVICE_ALIAS=${DEVICE_ALIAS:-}"
    echo "FLEET_NAME=$FLEET_NAME"
    echo "OS_IMAGE_GOOD=$OS_IMAGE_GOOD"
    echo "ROLLOUT_TIMEOUT_SEC=$ROLLOUT_TIMEOUT_SEC"
    echo "BUILD_APRIME=$BUILD_APRIME"
  } >"$OUT/meta.env"
  : >"$OUT/result.txt"

  flightctl_login

  DEV="$(resolve_device)"
  [[ -n "$DEV" ]] || die "could not resolve enrolled device"
  update_env DEVICE_NAME "$DEV"
  echo "resolved device: $DEV (alias=${DEVICE_ALIAS:-})"

  if ! ssh_base "$DEVICE_SSH" true 2>"$OUT/device/ssh-connect.err"; then
    write_verdict BLOCKED "SSH to $DEVICE_SSH failed"
    exit 2
  fi

  AUTHFILE="${REGISTRY_AUTH_FILE:-$HOME/.config/containers/auth.json}"
  if ! install_device_pull_auth; then
    write_verdict BLOCKED "device registry pull auth not usable"
    exit 2
  fi

  local booted good_digest
  booted="$(booted_digest)" || die "could not read booted digest"
  echo "booted=$booted" | tee -a "$OUT/result.txt"

  # Explicit pin wins (resume / operator override). Else resolve :good tag digest.
  if [[ -n "${OS_IMAGE_TARGET:-}" ]]; then
    TARGET_REF="$OS_IMAGE_TARGET"
    if [[ "$TARGET_REF" == *"@"* ]]; then
      TARGET_DIGEST="${TARGET_REF##*@}"
    else
      TARGET_DIGEST="$(digest_of_ref "$TARGET_REF")"
      TARGET_REF="$(repo_of "$TARGET_REF")@${TARGET_DIGEST}"
    fi
    TARGET_KIND="${TARGET_KIND:-A-explicit}"
    echo "using OS_IMAGE_TARGET=$TARGET_REF" | tee -a "$OUT/result.txt"
  else
    good_digest="$(digest_of_ref "$OS_IMAGE_GOOD")"
    echo "good_tag_digest=$good_digest" | tee -a "$OUT/result.txt"
    TARGET_KIND="A"
    TARGET_DIGEST="$good_digest"
    TARGET_REF="$(repo_of "$OS_IMAGE_GOOD")@${good_digest}"

    local do_aprime=0
    case "$BUILD_APRIME" in
      1|yes|true) do_aprime=1 ;;
      0|no|false) do_aprime=0 ;;
      auto)
        if [[ "$booted" == "$good_digest" ]]; then
          do_aprime=1
        fi
        ;;
      *) die "BUILD_APRIME must be auto|1|0 (got $BUILD_APRIME)" ;;
    esac

    if ((do_aprime)); then
      echo "device already on good digest — building A′ for visible Test 1 transition"
      if ! build_aprime; then
        echo "WARN: A′ build failed; falling back to same-digest A pin" | tee -a "$OUT/result.txt"
        TARGET_KIND="A-same-digest"
        TARGET_DIGEST="$good_digest"
        TARGET_REF="$(repo_of "$OS_IMAGE_GOOD")@${good_digest}"
      fi
    else
      echo "using existing good digest as target (BUILD_APRIME=$BUILD_APRIME)"
    fi
  fi

  echo "TARGET_REF=$TARGET_REF TARGET_KIND=$TARGET_KIND" | tee -a "$OUT/result.txt"
  {
    echo "target_kind=$TARGET_KIND"
    echo "target_ref=$TARGET_REF"
    echo "target_digest=$TARGET_DIGEST"
    echo "aprime_marker=${A_PRIME_MARKER:-}"
    echo "booted_before=$booted"
  } >"$OUT/target.env"

  collect_snapshot before

  # If already on target and Fleet will only pin same digest, still apply + verify.
  apply_fleet_image "$TARGET_REF"

  if wait_for_rollout; then
    collect_snapshot after
    local after_bootc after_marker
    after_bootc="$(booted_digest)"
    after_marker="$(remote_sudo 'test -f /etc/rhem-os-rollout-test/A-PRIME && cat /etc/rhem-os-rollout-test/A-PRIME || echo none')"
    after_marker="${after_marker//$'\r'/}"
    after_marker="${after_marker//$'\n'/}"
    if [[ "$after_bootc" == "$TARGET_DIGEST" ]]; then
      if [[ "$TARGET_KIND" == "A-prime" ]]; then
        [[ -n "${A_PRIME_MARKER:-}" ]] || die "A-prime target missing A_PRIME_MARKER"
        if [[ "$after_marker" != "$A_PRIME_MARKER" ]]; then
          write_verdict FAIL "A-prime marker mismatch: device=$after_marker expected=$A_PRIME_MARKER"
          echo "evidence: $OUT"
          exit 1
        fi
      fi
      write_verdict PASS "device Online+UpToDate on $TARGET_DIGEST; bootc agrees (kind=$TARGET_KIND marker=${after_marker})"
      echo "evidence: $OUT"
      exit 0
    fi
    write_verdict FAIL "hub UpToDate but bootc digest=$after_bootc != $TARGET_DIGEST"
    echo "evidence: $OUT"
    exit 1
  fi

  collect_snapshot after
  # Distinguish unauthorized/registry vs generic timeout from agent journal.
  if grep -qiE 'unauthorized|denied|authentication required' \
      "$OUT/after/device/journal-flightctl-agent.txt" \
      "$OUT/during/device/journal-flightctl-agent.txt" 2>/dev/null; then
    write_verdict BLOCKED "rollout did not converge; agent journal shows registry auth failure"
    exit 2
  fi
  write_verdict FAIL "rollout did not reach Online+UpToDate on $TARGET_DIGEST within ${ROLLOUT_TIMEOUT_SEC}s"
  echo "evidence: $OUT"
  exit 1
}

main "$@"
