# RHEM OS Rollout & Recovery Lab — Design

**Date:** 2026-10-01  
**Repo:** [trujillm/rhem-os-rollout-lab](https://github.com/trujillm/rhem-os-rollout-lab) (public)  
**Status:** Approved in design review; implementation plan ready

## 1. Goal

Validate whether Red Hat Edge Manager (RHEM / flightctl 1.3) can:

1. Roll out an OS image through Fleet configuration (`spec.os.image`).
2. Report device and Fleet state during that rollout.
3. Correctly reflect recovery when a new image fails OS health validation (bootc + greenboot), **if** those prerequisites are present.

Separate responsibility:

| Layer | Owns |
|---|---|
| **RHEM** | Desired OS image via Fleet, orchestration, device/Fleet status reporting |
| **OS** | bootc stage/switch/reboot, greenboot health, automatic rollback |
| **App/config** | Deliberate failure mechanism used only for Test 2 |

This is investigation/validation. PASS / FAIL / BLOCKED are all valid outcomes. Do **not** implement missing product rollback features.

## 2. Why not Fury

The original Option B reused the HP ZGX Fury demo (SNO + micro-VMs + demo Fleets). That stack is heavy (GPU, ROS, flywheel, twelve robots) and requires Tailscale access this operator does not have.

**Decision:** Replace Fury Option B with a lean **AWS OpenShift + one EC2 bootc device** lab. Reference [RHPhysicalAI/hp-roscon-flywheel](https://github.com/RHPhysicalAI/hp-roscon-flywheel) for patterns only; do not bind this lab to that repository.

## 3. Architecture

```text
[Laptop]  oc / flightctl / aws / ssh
    |
    v
[matrujil-rhem OpenShift 4.22]     us-east-2  (ipi_installs lab profile)
    namespace flightctl → RHEM 1.3
    routes: flightctl API + agent-api
    |
    |  Fleet/os-rollout-test   (flightctl apply; no demo GitOps)
    |  selector: fleet=os-rollout-test
    |  template.spec.os.image = <oci bootc digest>
    v
[1× EC2 bootc]  os-rollout-test-01
    flightctl-agent + bootc + greenboot(+flightctl-greenboot)
    known-good image A  <-->  controlled-fail image B
```

### Components

| Piece | Choice |
|---|---|
| Management plane | Existing/installing OpenShift cluster `matrujil-rhem` under `/Users/matrujil/Documents/ipi_installs/matrujil-rhem` |
| RHEM | Install 1.3 into `flightctl`; disable image builder and unused demo sync |
| Device | Separate small EC2 (e.g. `m6i.large`), same region |
| OS images | Two bootc OCI images (x86_64), pushed to a registry the operator controls (Quay preferred) |
| Fleet apply | `flightctl apply` from this repo — not ResourceSync of flywheel `gitops/rhem/` |
| Evidence | `results/` dumps (gitignored) |

### Explicitly out of scope

- Fury host, Tailscale, libvirt micro-VMs, GPUs, ROS, ACT, flywheel, Kafka, MinIO, OpenShift AI
- OpenShift Virtualization / KubeVirt for the device
- Implementing greenboot into any demo golden image
- New rollback mechanisms beyond stock bootc/greenboot
- Secrets in git

## 4. Repository

- **Name:** `rhem-os-rollout-lab`
- **Owner:** `trujillm`
- **Visibility:** public
- **Purpose:** Lab harness only — adjust freely without contaminating the flywheel demo repo

### Planned layout

```text
README.md
Makefile
config/env.example
config/recovery-runbook.md
docs/design.md
fleet/fleet-os-rollout-test.yaml
image/Containerfile.good
image/Containerfile.bad
image/greenboot/
scripts/00-prereqs.sh
scripts/10-build-images.sh
scripts/20-provision-ec2.sh
scripts/30-enroll-approve.sh
scripts/40-rollout-good.sh
scripts/50-rollout-failure.sh
scripts/60-collect-evidence.sh
scripts/70-restore.sh
infra/ec2/                  # minimal launch notes or IaC later
results/.gitkeep
.gitignore                  # results/, config/env, secrets
```

## 5. Hub (RHEM on matrujil-rhem)

1. Wait until cluster is Available (`oc get clusterversion`).
2. Install RHEM / flightctl **1.3** into namespace `flightctl` via the supported OpenShift path (OperatorHub / `redhat-rhem` chart).
3. Keep the management plane lean: no flywheel Argo apps, no demo ResourceSync.
4. Operator login must use a **real user token** (`oc login` → `oc whoami -t` → `flightctl login`), not a ServiceAccount token.
5. EC2 must reach the **agent-api** route over a stable HTTPS endpoint. Laptop `oc port-forward` is for operator CLI troubleshooting only — not for the agent.

## 6. Device and images (EC2)

### EC2

- Region: `us-east-2` (same as hub).
- Size: small (target `m6i.large` unless disk/CPU proves insufficient for bootc).
- Access: SSH from laptop and/or SSM Session Manager.
- Egress: HTTPS to agent-api and container registry.
- Identity: enroll as device `os-rollout-test-01` with labels matching Fleet selector.

### Images

- **A (known-good):** RHEL image-mode (bootc) base + flightctl-agent + greenboot / flightctl-greenboot + healthy marker.
- **B (controlled-fail):** Same lineage as A, plus a greenboot **required** check that fails deterministically (e.g. presence of `/etc/rhem-os-rollout-test/FAIL`).
- Digest-pin image refs in Fleet and in evidence.
- First boot of the EC2 must be image-mode on **A** (AMI/disk derived from A, or equivalent bootc-first path). Avoid “stock RHEL then maybe bootc later” as the primary path — that muddies package-mode vs image-mode evidence.

### Test 2 feasibility gate

Before inducing failure, verify on the live agent build whether:

- Custom `required.d` checks still trigger rollback, **or**
- Only flightctl-shipped greenboot checks matter.

If neither can safely induce failure → mark Test 2 **BLOCKED**; do not invent a custom rollback mechanism.

## 7. Tests

### Test 1 — Successful OS rollout

Preconditions: hub reachable, device enrolled, image A pullable, device can reboot safely.

Action: set Fleet `spec.os.image` to digest A (or A→A' if already on A for a visible transition), apply, wait through stage/reboot.

**PASS:** Device runs A; RHEM Online + UpToDate (or documented live enums); bootc agrees.  
**FAIL:** Spec accepted but bootc/RHEM disagree, or never reaches A.  
**BLOCKED:** API/agent/registry/reboot path missing.

### Test 2 — Health failure and recovery

Gate: greenboot wired, previous deployment retained, console/SSH recovery documented.

Action: point Fleet at B; observe health failure and automatic rollback to A (or execute recovery runbook).

**PASS:** Auto-rollback to A; RHEM reports non-success for B distinctly.  
**FAIL:** Mis-reporting or no rollback when health failed.  
**BLOCKED:** Missing greenboot path or unsafe to induce failure.

### Evidence

Central collector dumps flightctl JSON, bootc status, package versions, agent/greenboot journals, UTC timestamps. Fill a responsibility matrix from evidence only.

### Restore / teardown

1. Return device to known-good A (or decommission).
2. Delete test Fleet after device is safe.
3. Terminate EC2.
4. Optionally uninstall RHEM; cluster destroy remains an `ipi_installs` / `openshift-install destroy` operation outside this repo.

## 8. Prerequisites (fill during Phase 1)

Hard gates include: RHEM ~1.3, operator login, hub reachable, bootc EC2 creatable and enrolled, registry pull, reboot path, Test-2-only greenboot/recovery gates, test Fleet isolated from any other workloads on the hub.

## 9. Risks

| Risk | Mitigation |
|---|---|
| Secrets in public repo | `config/env` gitignored; examples only; never commit kubeconfig/pull-secret |
| Agent cannot reach API | Prove agent-api reachability from EC2 before enroll |
| Custom greenboot checks disabled by product | Feasibility probe before Test 2 |
| Bricked EC2 | Recovery runbook + terminate/rebuild from A |
| Confusing OpenShift nodes with the device under test | Never enroll masters/workers as the OS-rollout subject |

## 10. Done when

1. Prerequisites table filled against this AWS lab.
2. Test 1 executed or BLOCKED with evidence.
3. Test 2 executed only if safe; otherwise BLOCKED with gap.
4. RHEM vs OS vs app/config recorded separately.
5. Environment restored / EC2 terminated as appropriate.
6. Jira-style result: PASS / FAIL / BLOCKED with expected vs observed.

## 11. Decisions log

| Decision | Choice |
|---|---|
| Drop Fury Option B | Yes |
| Hub | AWS OpenShift `matrujil-rhem` |
| Device | Separate EC2 bootc (not KubeVirt) |
| New repo | `trujillm/rhem-os-rollout-lab` public |
| Fleet delivery | `flightctl apply` from this repo |
| Image failure mechanism | Greenboot required check on image B (if product honors it) |
