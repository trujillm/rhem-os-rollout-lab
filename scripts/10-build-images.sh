#!/usr/bin/env bash
# Build and push image/Containerfile.good and image/Containerfile.bad, then record their
# digests. Called by `make build-images`.
#
# BUILD_MODE=local (default): plain `podman build --platform linux/amd64` on this machine.
# Works for the flightctl-agent install (vendored repo, no entitlement needed) but greenboot /
# flightctl-greenboot come from RHEL AppStream and need an entitled build host: either
# `subscription-manager register` locally (point ENTITLEMENT_CERT/ENTITLEMENT_KEY at the
# resulting /etc/pki/entitlement/*.pem pair), or BUILD_MODE=cluster below.
#
# BUILD_MODE=cluster: this lab's actual build path. This laptop is Darwin with an arm64 podman
# machine and no RHEL subscription — neither the right CPU arch nor an entitled build host for
# greenboot. The OpenShift cluster in KUBECONFIG has both: its nodes are x86_64, and OpenShift
# auto-syncs a managed entitlement secret (openshift-config-managed/etc-pki-entitlement) from the
# cluster's own Red Hat subscription. This mode spins up a short-lived privileged pod on that
# cluster, builds both images there with buildah (entitlement certs mounted only as BuildKit-style
# `--secret`s, never baked into a layer — see image/Containerfile.good), pushes them, and tears
# the namespace back down. Nothing from this run is committed: the registry auth file content and
# entitlement certs only ever live in an ephemeral namespace deleted at the end.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib.sh"

load_env
require_env OS_IMAGE_REPO OS_IMAGE_GOOD OS_IMAGE_BAD
require_cmd podman skopeo

BUILD_MODE="${BUILD_MODE:-local}"
RESULTS_DIR="$ROOT/results"
mkdir -p "$RESULTS_DIR"
OUT="$RESULTS_DIR/image-digests-$(ts).txt"

digest_of() {
  skopeo inspect --format '{{.Digest}}' "docker://$1"
}

record_digests() {
  {
    echo "built_at_utc=$(ts)"
    echo "build_mode=$BUILD_MODE"
    echo "OS_IMAGE_GOOD=$OS_IMAGE_GOOD"
    echo "OS_IMAGE_GOOD_DIGEST=$(digest_of "$OS_IMAGE_GOOD")"
    echo "OS_IMAGE_BAD=$OS_IMAGE_BAD"
    echo "OS_IMAGE_BAD_DIGEST=$(digest_of "$OS_IMAGE_BAD")"
  } | tee "$OUT"
}

# --- BUILD_MODE=local ---------------------------------------------------------------------
build_local() {
  local secret_args=()
  if [[ -n "${ENTITLEMENT_CERT:-}" && -n "${ENTITLEMENT_KEY:-}" ]]; then
    secret_args=(--secret "id=entitlement_cert,src=${ENTITLEMENT_CERT}" --secret "id=entitlement_key,src=${ENTITLEMENT_KEY}")
  else
    echo "warn: ENTITLEMENT_CERT/ENTITLEMENT_KEY not set — the entitled dnf step in" \
         "Containerfile.good (greenboot/greenboot-default-health-checks) will fail unless this" \
         "host is subscription-manager registered with those repos already enabled." >&2
  fi

  podman build --platform linux/amd64 "${secret_args[@]+"${secret_args[@]}"}" \
    -t "$OS_IMAGE_GOOD" -f "$ROOT/image/Containerfile.good" "$ROOT/image"
  podman push "$OS_IMAGE_GOOD"

  podman build --platform linux/amd64 \
    --build-arg "BASE=$OS_IMAGE_GOOD" \
    -t "$OS_IMAGE_BAD" -f "$ROOT/image/Containerfile.bad" "$ROOT/image"
  podman push "$OS_IMAGE_BAD"
}

# --- BUILD_MODE=cluster ---------------------------------------------------------------------
build_cluster() {
  require_cmd oc
  # Not `local`: the EXIT trap below runs after this function returns, in the script's top-level
  # scope, so it needs a global to see the namespace name.
  CLUSTER_BUILD_NS="os-rollout-build"
  local ns="$CLUSTER_BUILD_NS"
  local authfile="${REGISTRY_AUTH_FILE:-$HOME/.config/containers/auth.json}"
  [[ -f "$authfile" ]] || die "no registry auth file at $authfile (podman login quay.io / registry.redhat.io first)"

  cleanup() { oc delete namespace "$CLUSTER_BUILD_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
  trap cleanup EXIT

  oc delete namespace "$ns" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  oc create namespace "$ns"
  oc adm policy add-scc-to-user privileged -z default -n "$ns" >/dev/null

  # Copy the cluster's managed entitlement secret into the build namespace (secrets don't cross
  # namespaces by reference) and a throwaway secret for registry push/pull auth.
  # oc create (not apply): the entitlement cert bundle is large enough that kubectl apply's
  # last-applied-configuration annotation would exceed the 262144-byte annotation limit.
  oc get secret etc-pki-entitlement -n openshift-config-managed -o json \
    | python3 -c "import json,sys; d=json.load(sys.stdin); d['metadata']={'name':'etc-pki-entitlement'}; print(json.dumps(d))" \
    | oc create -n "$ns" -f -
  oc create secret generic registry-auth -n "$ns" --from-file="auth.json=$authfile"

  oc run buildah --image=quay.io/buildah/stable -n "$ns" \
    --overrides='{"spec":{"securityContext":{"runAsUser":0},"containers":[{"name":"buildah","image":"quay.io/buildah/stable","command":["sleep","infinity"],"securityContext":{"privileged":true},"volumeMounts":[{"name":"entitlement","mountPath":"/etc/pki/entitlement-src"},{"name":"regauth","mountPath":"/run/secrets/registry"}]}],"volumes":[{"name":"entitlement","secret":{"secretName":"etc-pki-entitlement"}},{"name":"regauth","secret":{"secretName":"registry-auth"}}]}}'
  oc wait --for=condition=Ready pod/buildah -n "$ns" --timeout=120s

  oc exec -n "$ns" buildah -- mkdir -p /workspace/image
  oc cp "$ROOT/image/." "$ns/buildah:/workspace/image"

  local remote_script
  remote_script="$(cat <<'REMOTE'
set -euo pipefail
cd /workspace/image
AUTH=/run/secrets/registry/auth.json
buildah bud --authfile "$AUTH" \
  --secret id=entitlement_cert,src=/etc/pki/entitlement-src/entitlement.pem \
  --secret id=entitlement_key,src=/etc/pki/entitlement-src/entitlement-key.pem \
  -t "$OS_IMAGE_GOOD" -f Containerfile.good .
buildah push --authfile "$AUTH" "$OS_IMAGE_GOOD" "docker://$OS_IMAGE_GOOD"
buildah bud --authfile "$AUTH" --build-arg "BASE=$OS_IMAGE_GOOD" \
  -t "$OS_IMAGE_BAD" -f Containerfile.bad .
buildah push --authfile "$AUTH" "$OS_IMAGE_BAD" "docker://$OS_IMAGE_BAD"
REMOTE
)"
  oc exec -n "$ns" buildah -- env "OS_IMAGE_GOOD=$OS_IMAGE_GOOD" "OS_IMAGE_BAD=$OS_IMAGE_BAD" \
    bash -c "$remote_script"
}

case "$BUILD_MODE" in
  local)   build_local ;;
  cluster) build_cluster ;;
  *)       die "unknown BUILD_MODE: $BUILD_MODE (expected local|cluster)" ;;
esac

record_digests
echo "digests saved to $OUT"
