# EC2 bootc recovery runbook

Use this when the **lab EC2 device** (`os-rollout-test-01`) is unhealthy during Test 1 or Test 2. This lab device is **not** an OpenShift control-plane or worker node.

## Scope (read first)

| In scope | Out of scope |
| --- | --- |
| The single test EC2 instance tagged for this lab | OpenShift masters/workers on `matrujil-rhem` |
| bootc rollback / rebuild from known-good image A | `oc debug node`, draining workers, or enrolling cluster nodes in flightctl |
| Terminate and relaunch EC2 from a good AMI | `openshift-install destroy` (cluster teardown is separate) |

**Never** SSH to OpenShift node instances to “fix” the device under test. **Never** enroll OpenShift nodes as flightctl devices for this Fleet.

## Prerequisites

- `config/env` loaded locally (`DEVICE_SSH`, `AWS_REGION`, `AWS_PROFILE`, instance/AMI IDs if recorded).
- Operator access: SSH key and/or AWS SSM Session Manager on the instance.
- Known-good bootc image **A** (AMI or OCI digest) documented in your local env / `results/`.

## 1. Reach the device

### SSH (preferred when key and SG allow)

```bash
# From repo root after sourcing config/env
ssh -o StrictHostKeyChecking=accept-new "$DEVICE_SSH"
```

### AWS SSM Session Manager (when SSH is blocked)

```bash
aws ssm start-session --target "$INSTANCE_ID" --region "$AWS_REGION"
# Or discover instance:
aws ec2 describe-instances --region "$AWS_REGION" \
  --filters "Name=tag:Name,Values=os-rollout-test-01" \
  --query 'Reservations[].Instances[].InstanceId' --output text
```

## 2. Inspect bootc state

On the **EC2 device**:

```bash
sudo bootc status
sudo bootc status --format=json | jq .   # if jq installed
journalctl -u greenboot -b --no-pager | tail -100
journalctl -u flightctl-agent -b --no-pager | tail -100
```

Note: staged vs booted deployment, whether a rollback deployment exists, and any greenboot failure.

## 3. Roll back to the previous deployment

When a new image failed health checks but bootc retained the previous deployment:

```bash
sudo bootc rollback
# Reboot is usually required for the rollback to take effect
sudo systemctl reboot
```

After reboot, SSH/SSM back in and confirm:

```bash
sudo bootc status
```

Expected: booted deployment matches known-good **A** (digest/ref recorded in evidence).

If `bootc rollback` is unavailable or does not restore **A**, treat the instance as unrecoverable (step 4).

## 4. Unrecoverable instance — terminate and relaunch

When the disk/boot state is unknown, rollback fails, or the instance is wedged:

1. **Stop using this instance** for evidence; note instance ID and time in `results/`.
2. Terminate (from laptop):

   ```bash
   aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"
   ```

3. Relaunch from the **last known-good AMI** (built from image A):

   ```bash
   # Use scripts/20-provision-ec2.sh when available, or:
   aws ec2 run-instances --image-id "$AMI_ID" --instance-type "$EC2_INSTANCE_TYPE" \
     --key-name "$EC2_KEY_NAME" --subnet-id "$EC2_SUBNET_ID" \
     --security-group-ids "$EC2_SG_ID" --region "$AWS_REGION" \
     --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=os-rollout-test-01}]'
   ```

4. Update `DEVICE_SSH` / `INSTANCE_ID` in local `config/env`.
5. Re-run enroll/verify scripts (`make enroll`, `make verify`) before resuming Fleet tests.

## 5. Hub-side checks (laptop)

Do **not** change OpenShift nodes. Confirm the management plane is healthy:

```bash
oc get clusterversion
oc -n flightctl get pods,route
flightctl get devices
flightctl get device/os-rollout-test-01 -o yaml   # after re-enroll
```

## 6. When to escalate vs rebuild

| Situation | Action |
| --- | --- |
| Single bad rollout, previous deployment present | `bootc rollback` + reboot |
| greenboot failed on image B, auto-rollback observed | Collect evidence; stay on A |
| bootc corrupt, no rollback target, endless crash loop | Terminate + relaunch from good AMI |
| Uncertain image/digest on disk | Terminate + relaunch (cleanest evidence) |

## 7. After recovery

- Point Fleet `spec.os.image` back to digest-pinned **A** if needed (`flightctl apply`).
- Run `make collect-results` (when script exists) before repeating Test 1 or Test 2.
- Record PASS/FAIL/BLOCKED in lab notes; do not commit secrets or instance-specific IDs to git.
