#!/usr/bin/env bash
# Build an AWS AMI from image A ($OS_IMAGE_GOOD) via bootc-image-builder ("bib") and register it
# in $AWS_REGION. See infra/ec2/README.md for the full design/rationale — in short:
#
#   - Image A has no cloud-init, so SSH access is baked into the image at build time via bib's
#     config.toml (ssh key + password for the %wheel sudo requirement), not via EC2 key-pair
#     metadata injection. See infra/ec2/README.md §1.
#   - BUILD_MODE=cluster (default): bib runs as a privileged pod on the OpenShift hub's x86_64
#     nodes — same arch as image A, no cross-arch disk tooling. See §3.
#   - BUILD_MODE=local: experimental fallback via this laptop's arm64 podman machine. See §3.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib.sh"

load_env
require_env OS_IMAGE_GOOD AWS_REGION
require_cmd aws

BUILD_MODE="${BUILD_MODE:-cluster}"
AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
AMI_NAME="${AMI_NAME:-rhem-os-rollout-good-$(ts)}"
BIB_IMAGE="${BIB_IMAGE:-registry.redhat.io/rhel10/bootc-image-builder:latest}"
BIB_S3_BUCKET="${BIB_S3_BUCKET:-matrujil-rhem-os-rollout-bib-${AWS_ACCOUNT_ID}}"
VMIMPORT_POLICY_NAME="matrujil-rhem-os-rollout-lab"

SSH_KEY_PATH="${HOME}/.ssh/rhem-os-rollout-lab"
RESULTS_DIR="$ROOT/results/bib-ami-$(ts)"
mkdir -p "$RESULTS_DIR"

# --- SSH key baked into the image + used by scripts/20-provision-ec2.sh ----------------------
ensure_ssh_key() {
  if [[ -f "$SSH_KEY_PATH" && -f "${SSH_KEY_PATH}.pub" ]]; then
    echo "ssh key: reusing $SSH_KEY_PATH"
    return
  fi
  mkdir -p "$(dirname "$SSH_KEY_PATH")"
  ssh-keygen -t ed25519 -N "" -C "rhem-os-rollout-lab" -f "$SSH_KEY_PATH" >/dev/null
  chmod 600 "$SSH_KEY_PATH"
  echo "ssh key: generated $SSH_KEY_PATH"
}

# --- sudo password for the baked-in user (wheel requires one on this image) ------------------
ensure_sudo_password() {
  if [[ -n "${EC2_SSH_PASSWORD:-}" && "${EC2_SSH_PASSWORD}" != REPLACE_ME ]]; then
    return
  fi
  local pw
  pw="$(openssl rand -base64 30 | tr -dc 'A-Za-z0-9' | head -c 24)"
  update_env EC2_SSH_PASSWORD "$pw"
  echo "sudo password: generated and stored in config/env (EC2_SSH_PASSWORD, not committed)"
}

# --- S3 staging bucket for bib's AWS upload + vmimport inline policy scoped to it ------------
ensure_s3_bucket() {
  if aws s3api head-bucket --bucket "$BIB_S3_BUCKET" --region "$AWS_REGION" 2>/dev/null; then
    echo "s3 bucket: reusing $BIB_S3_BUCKET"
    return
  fi
  echo "s3 bucket: creating $BIB_S3_BUCKET in $AWS_REGION"
  aws s3api create-bucket --bucket "$BIB_S3_BUCKET" --region "$AWS_REGION" \
    --create-bucket-configuration "LocationConstraint=${AWS_REGION}" >/dev/null
  aws s3api put-bucket-lifecycle-configuration --bucket "$BIB_S3_BUCKET" --lifecycle-configuration '{
    "Rules": [{"ID": "expire-bib-staging", "Status": "Enabled", "Filter": {}, "Expiration": {"Days": 7}}]
  }'
}

ensure_vmimport_policy() {
  echo "vmimport role: ensuring scoped access to $BIB_S3_BUCKET (policy: $VMIMPORT_POLICY_NAME)"
  aws iam put-role-policy --role-name vmimport --policy-name "$VMIMPORT_POLICY_NAME" --policy-document "$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetBucketLocation", "s3:GetObject", "s3:ListBucket", "s3:PutObject"],
      "Resource": ["arn:aws:s3:::${BIB_S3_BUCKET}", "arn:aws:s3:::${BIB_S3_BUCKET}/*"]
    },
    {
      "Effect": "Allow",
      "Action": ["ec2:ModifySnapshotAttribute", "ec2:CopySnapshot", "ec2:RegisterImage", "ec2:Describe*"],
      "Resource": "*"
    }
  ]
}
JSON
)"
}

write_config_toml() {
  local out="$1"
  cat >"$out" <<TOML
[[customizations.user]]
name = "ec2-user"
groups = ["wheel"]
key = "$(cat "${SSH_KEY_PATH}.pub")"
password = "${EC2_SSH_PASSWORD}"
TOML
}

# --- BUILD_MODE=cluster: privileged pod on the OpenShift hub ---------------------------------
build_cluster() {
  require_cmd oc
  # Not `local`: the EXIT trap below runs after this function returns, in the script's top-level
  # scope, so it needs a global to see the namespace name (see scripts/10-build-images.sh for the
  # same lesson learned in Task 6).
  CLUSTER_BIB_NS="os-rollout-bib"
  local ns="$CLUSTER_BIB_NS"
  local authfile="${REGISTRY_AUTH_FILE:-$HOME/.config/containers/auth.json}"
  [[ -f "$authfile" ]] || die "no registry auth file at $authfile (podman login registry.redhat.io first)"

  cleanup() { oc delete namespace "$CLUSTER_BIB_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
  trap cleanup EXIT

  oc delete namespace "$ns" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  oc create namespace "$ns"
  oc adm policy add-scc-to-user privileged -z default -n "$ns" >/dev/null

  # kubelet needs this to pull bib's own pod image (registry.redhat.io/rhel10/bootc-image-builder).
  oc create secret generic rhel-registry-pull -n "$ns" \
    --type=kubernetes.io/dockerconfigjson --from-file=".dockerconfigjson=$authfile"
  oc secrets link default rhel-registry-pull --for=pull -n "$ns"

  # The init container's `podman pull` needs the same creds (quay.io too, for $OS_IMAGE_GOOD —
  # it is NOT a public repo, see infra/ec2/README.md §2) in authfile form, separately from the
  # dockerconfigjson secret above (different consumer, different format expectation).
  oc create secret generic registry-authfile -n "$ns" --from-file="auth.json=$authfile"

  # bib's AWS uploader loads a named shared-config profile; env-vars-only produced
  # "failed to get shared config profile, default" — needs a real ~/.aws/credentials file.
  local aws_creds_file="$RESULTS_DIR/aws-credentials"
  cat >"$aws_creds_file" <<AWSCRED
[default]
aws_access_key_id = $(aws configure get aws_access_key_id --profile "${AWS_PROFILE:-default}")
aws_secret_access_key = $(aws configure get aws_secret_access_key --profile "${AWS_PROFILE:-default}")
AWSCRED
  oc create secret generic aws-creds-file -n "$ns" --from-file="credentials=$aws_creds_file"
  shred -u "$aws_creds_file" 2>/dev/null || rm -f "$aws_creds_file"

  local cfg="$RESULTS_DIR/config.toml"
  write_config_toml "$cfg"
  oc create configmap bib-config -n "$ns" --from-file="config.toml=$cfg"

  cat >"$RESULTS_DIR/bib-pod.yaml" <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: bib
  namespace: ${ns}
spec:
  restartPolicy: Never
  securityContext:
    seLinuxOptions: { type: spc_t }
  initContainers:
    - name: init-storage
      image: ${BIB_IMAGE}
      securityContext:
        privileged: true
        seLinuxOptions: { type: spc_t }
      command: ["sh", "-c", "mkdir -p /var/lib/containers/storage/overlay && podman --root /var/lib/containers/storage pull --authfile=/tmp/auth.json ${OS_IMAGE_GOOD}"]
      volumeMounts:
        - { name: containers-storage, mountPath: /var/lib/containers/storage }
        - { name: registry-authfile, mountPath: /tmp/auth.json, subPath: auth.json, readOnly: true }
  containers:
    - name: bib
      image: ${BIB_IMAGE}
      securityContext:
        privileged: true
        seLinuxOptions: { type: spc_t }
      env:
        - { name: AWS_PROFILE, value: default }
      args:
        - "--type=ami"
        - "--config=/config.toml"
        - "--aws-ami-name=${AMI_NAME}"
        - "--aws-bucket=${BIB_S3_BUCKET}"
        - "--aws-region=${AWS_REGION}"
        - "${OS_IMAGE_GOOD}"
      volumeMounts:
        - { name: config, mountPath: /config.toml, subPath: config.toml, readOnly: true }
        - { name: output, mountPath: /output }
        - { name: store, mountPath: /store }
        - { name: containers-storage, mountPath: /var/lib/containers/storage }
        - { name: awscreds, mountPath: /root/.aws, readOnly: true }
  volumes:
    - { name: config, configMap: { name: bib-config } }
    - { name: output, emptyDir: {} }
    - { name: store, emptyDir: {} }
    - { name: containers-storage, emptyDir: {} }
    - { name: registry-authfile, secret: { secretName: registry-authfile } }
    - { name: awscreds, secret: { secretName: aws-creds-file } }
YAML
  oc apply -f "$RESULTS_DIR/bib-pod.yaml"

  echo "waiting for pod/bib (this can take 10-20 minutes)..."
  if ! oc wait --for=jsonpath='{.status.phase}'=Succeeded pod/bib -n "$ns" --timeout=1800s 2>&1 \
      | tee "$RESULTS_DIR/wait.log"; then
    oc logs pod/bib -n "$ns" >"$RESULTS_DIR/bib-pod.log" 2>&1 || true
    die "bib pod did not succeed — see $RESULTS_DIR/bib-pod.log and $RESULTS_DIR/wait.log"
  fi
  oc logs pod/bib -n "$ns" >"$RESULTS_DIR/bib-pod.log" 2>&1 || true
}

# --- BUILD_MODE=local: experimental, this laptop's arm64 podman machine ----------------------
build_local() {
  require_cmd podman
  local cfg="$RESULTS_DIR/config.toml"
  write_config_toml "$cfg"
  mkdir -p "$RESULTS_DIR/output"

  podman run --rm --privileged --pull=newer \
    --security-opt label=type:unconfined_t \
    --platform linux/amd64 \
    -v "$cfg:/config.toml:ro" \
    -v "$RESULTS_DIR/output:/output" \
    -v "$HOME/.aws:/root/.aws:ro" \
    --env AWS_PROFILE="${AWS_PROFILE:-default}" \
    "$BIB_IMAGE" \
    --type ami \
    --config /config.toml \
    --aws-ami-name "$AMI_NAME" \
    --aws-bucket "$BIB_S3_BUCKET" \
    --aws-region "$AWS_REGION" \
    "$OS_IMAGE_GOOD" \
    2>&1 | tee "$RESULTS_DIR/bib-local.log"
}

ensure_ssh_key
ensure_sudo_password
ensure_s3_bucket
ensure_vmimport_policy

case "$BUILD_MODE" in
  cluster) build_cluster ;;
  local)   build_local ;;
  *)       die "unknown BUILD_MODE: $BUILD_MODE (expected cluster|local)" ;;
esac

echo "resolving AMI_ID for name=$AMI_NAME in $AWS_REGION ..."
AMI_ID=""
for _ in $(seq 1 20); do
  AMI_ID="$(aws ec2 describe-images --owners self --region "$AWS_REGION" \
    --filters "Name=name,Values=${AMI_NAME}" --query 'Images[0].ImageId' --output text 2>/dev/null || true)"
  [[ -n "$AMI_ID" && "$AMI_ID" != "None" ]] && break
  sleep 15
done
[[ -n "$AMI_ID" && "$AMI_ID" != "None" ]] || die "AMI not found by name=$AMI_NAME after build — check $RESULTS_DIR logs"

update_env AMI_ID "$AMI_ID"
echo "AMI_ID=${AMI_ID}"
echo "stored in config/env (local, not committed). config/env.example keeps AMI_ID=REPLACE_ME."
