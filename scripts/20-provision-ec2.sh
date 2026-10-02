#!/usr/bin/env bash
# Provision the lab's single EC2 bootc device from $AMI_ID (scripts/15-build-ami.sh) and verify
# SSH + `bootc status`. See infra/ec2/README.md §1 for why SSH access depends on the AMI's baked-in
# config.toml user ("ec2-user"), not on the EC2 key pair's metadata injection (image A has no
# cloud-init). Discovers/creates whatever config/env is missing: default VPC subnet, security
# group, EC2 key pair — never overwrites values already set.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib.sh"

load_env
require_env AMI_ID AWS_REGION EC2_INSTANCE_TYPE DEVICE_NAME
require_cmd aws ssh

[[ "$AMI_ID" != REPLACE_ME ]] || die "AMI_ID is REPLACE_ME — run scripts/15-build-ami.sh first"

SSH_KEY_PATH="${HOME}/.ssh/rhem-os-rollout-lab"
REGION_FLAGS=(--region "$AWS_REGION")

# --- key pair: must match the public key baked into the AMI (infra/ec2/README.md §1) ---------
ensure_key_pair() {
  if [[ -n "${EC2_KEY_NAME:-}" && "$EC2_KEY_NAME" != REPLACE_ME ]] \
      && aws ec2 describe-key-pairs "${REGION_FLAGS[@]}" --key-names "$EC2_KEY_NAME" >/dev/null 2>&1; then
    echo "key pair: reusing $EC2_KEY_NAME"
    return
  fi
  [[ -f "${SSH_KEY_PATH}.pub" ]] || die "missing ${SSH_KEY_PATH}.pub — run scripts/15-build-ami.sh first"
  local name="rhem-os-rollout-lab"
  if ! aws ec2 describe-key-pairs "${REGION_FLAGS[@]}" --key-names "$name" >/dev/null 2>&1; then
    echo "key pair: importing $name from ${SSH_KEY_PATH}.pub"
    aws ec2 import-key-pair "${REGION_FLAGS[@]}" --key-name "$name" \
      --public-key-material "fileb://${SSH_KEY_PATH}.pub" >/dev/null
  else
    echo "key pair: $name already registered in AWS"
  fi
  update_env EC2_KEY_NAME "$name"
}

# --- default VPC subnet ----------------------------------------------------------------------
ensure_subnet() {
  if [[ -n "${EC2_SUBNET_ID:-}" && "$EC2_SUBNET_ID" != REPLACE_ME ]]; then
    echo "subnet: reusing $EC2_SUBNET_ID"
    return
  fi
  local subnet
  subnet="$(aws ec2 describe-subnets "${REGION_FLAGS[@]}" \
    --filters Name=default-for-az,Values=true \
    --query 'Subnets[0].SubnetId' --output text)"
  [[ -n "$subnet" && "$subnet" != "None" ]] || die "no default-for-az subnet found in $AWS_REGION"
  echo "subnet: discovered default subnet $subnet"
  update_env EC2_SUBNET_ID "$subnet"
}

# --- security group: SSH from operator IP, egress 443 (+53 for DNS, see infra/ec2/README.md) -
ensure_security_group() {
  if [[ -n "${EC2_SG_ID:-}" && "$EC2_SG_ID" != REPLACE_ME ]] \
      && aws ec2 describe-security-groups "${REGION_FLAGS[@]}" --group-ids "$EC2_SG_ID" >/dev/null 2>&1; then
    echo "security group: reusing $EC2_SG_ID"
    return
  fi
  local name="rhem-os-rollout-lab-ssh"
  local vpc_id
  vpc_id="$(aws ec2 describe-subnets "${REGION_FLAGS[@]}" --subnet-ids "$EC2_SUBNET_ID" \
    --query 'Subnets[0].VpcId' --output text)"

  local sg_id
  sg_id="$(aws ec2 describe-security-groups "${REGION_FLAGS[@]}" \
    --filters "Name=group-name,Values=${name}" "Name=vpc-id,Values=${vpc_id}" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"

  local my_ip
  my_ip="$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')"
  [[ -n "$my_ip" ]] || die "could not determine operator public IP (curl checkip.amazonaws.com failed)"

  if [[ -z "$sg_id" || "$sg_id" == "None" ]]; then
    echo "security group: creating $name in $vpc_id"
    sg_id="$(aws ec2 create-security-group "${REGION_FLAGS[@]}" \
      --group-name "$name" --description "rhem-os-rollout-lab: SSH from operator, egress 443/53" \
      --vpc-id "$vpc_id" --query 'GroupId' --output text)"
    # Default egress-all rule from create-security-group is removed so only 443/53 remain.
    aws ec2 revoke-security-group-egress "${REGION_FLAGS[@]}" --group-id "$sg_id" \
      --ip-permissions 'IpProtocol=-1,IpRanges=[{CidrIp=0.0.0.0/0}]' >/dev/null 2>&1 || true
  else
    echo "security group: reusing existing $name ($sg_id)"
  fi

  # Idempotent: ignore "already exists" so re-runs (e.g. operator IP changed) are safe.
  aws ec2 authorize-security-group-ingress "${REGION_FLAGS[@]}" --group-id "$sg_id" \
    --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${my_ip}/32,Description=operator}]" \
    >/dev/null 2>&1 || true
  for proto_port in tcp:443 udp:53 tcp:53; do
    local proto="${proto_port%%:*}" port="${proto_port##*:}"
    aws ec2 authorize-security-group-egress "${REGION_FLAGS[@]}" --group-id "$sg_id" \
      --ip-permissions "IpProtocol=${proto},FromPort=${port},ToPort=${port},IpRanges=[{CidrIp=0.0.0.0/0}]" \
      >/dev/null 2>&1 || true
  done

  update_env EC2_SG_ID "$sg_id"
}

launch_instance() {
  if [[ -n "${INSTANCE_ID:-}" && "$INSTANCE_ID" != REPLACE_ME ]] \
      && aws ec2 describe-instances "${REGION_FLAGS[@]}" --instance-ids "$INSTANCE_ID" \
         --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null \
         | grep -qE '^(pending|running)$'; then
    echo "instance: reusing running $INSTANCE_ID"
    return
  fi
  echo "instance: launching $EC2_INSTANCE_TYPE from $AMI_ID"
  INSTANCE_ID="$(aws ec2 run-instances "${REGION_FLAGS[@]}" \
    --image-id "$AMI_ID" --instance-type "$EC2_INSTANCE_TYPE" \
    --key-name "$EC2_KEY_NAME" --subnet-id "$EC2_SUBNET_ID" \
    --security-group-ids "$EC2_SG_ID" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${DEVICE_NAME}}]" \
    --query 'Instances[0].InstanceId' --output text)"
  update_env INSTANCE_ID "$INSTANCE_ID"
}

wait_and_report() {
  echo "waiting for $INSTANCE_ID to pass instance-status-ok (can take a few minutes)..."
  aws ec2 wait instance-status-ok "${REGION_FLAGS[@]}" --instance-ids "$INSTANCE_ID"

  local public_ip
  public_ip="$(aws ec2 describe-instances "${REGION_FLAGS[@]}" --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
  [[ -n "$public_ip" && "$public_ip" != "None" ]] || die "instance has no public IP — check subnet MapPublicIpOnLaunch"

  update_env DEVICE_SSH "ec2-user@${public_ip}"
  echo "INSTANCE_ID=${INSTANCE_ID}"
  echo "public IP=${public_ip}"
  echo "DEVICE_SSH=ec2-user@${public_ip} written to config/env — run: source config/env"
}

verify_bootc_status() {
  echo "verifying SSH + bootc status on ${DEVICE_SSH} ..."
  local tries=0
  until ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
      "$DEVICE_SSH" true 2>/dev/null; do
    tries=$((tries + 1))
    [[ "$tries" -lt 20 ]] || die "SSH to $DEVICE_SSH did not come up after $tries tries"
    sleep 15
  done

  local out
  out="$(printf '%s\n' "$EC2_SSH_PASSWORD" | ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=accept-new \
    "$DEVICE_SSH" 'sudo -S bootc status' 2>&1)"
  echo "$out"
  if echo "$out" | grep -qi 'booted'; then
    echo "bootc status: OK (image-mode deployment present)"
  else
    die "bootc status did not report a booted deployment — see output above"
  fi
}

ensure_key_pair
ensure_subnet
ensure_security_group
launch_instance
wait_and_report
verify_bootc_status
