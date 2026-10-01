# RHEM OS Rollout Lab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a lean AWS lab that installs RHEM 1.3 on `matrujil-rhem`, enrolls one EC2 bootc device, and produces evidence for OS image rollout (Test 1) and health-failure recovery (Test 2, gated).

**Architecture:** OpenShift hub `matrujil-rhem` runs RHEM via Helm (`redhat-rhem`). One EC2 instance boots from a bootc-derived AMI built from image A. Fleet `os-rollout-test` is applied with `flightctl apply` and points `spec.os.image` at digest-pinned OCI bootc images A/B in a registry the operator controls.

**Tech Stack:** OpenShift 4.22.5, Helm `redhat-rhem` 1.3.0, flightctl CLI 1.3.0, RHEL 10 bootc, greenboot/flightctl-greenboot, AWS EC2 (`us-east-2`), podman/bootc-image-builder, bash + Make.

## Global Constraints

- Investigation only — do not implement missing product rollback features; mark gaps BLOCKED.
- Never commit secrets (`config/env`, kubeconfigs, pull secrets, passwords).
- Never enroll OpenShift masters/workers as the OS-rollout device.
- Do not use Fury, GPU, ROS, ACT, or flywheel stacks.
- Pin RHEM chart to **1.3.0** (matches design; 1.3.1 exists but stay on 1.3.0 unless install fails).
- Storage class: **`gp3-csi`**. Apps domain: **`apps.matrujil-rhem.kni.syseng.devcluster.openshift.com`**.
- Fleet delivery: **`flightctl apply` only** (no demo ResourceSync).
- Test 2 only after greenboot feasibility gate passes.
- Conventional Commits; ask before pushing if unclear — default push to `main` for this public lab repo after each task when the operator said to move forward.

---

## File map

| Path | Responsibility |
|---|---|
| `config/env.example` | Non-secret variable names/defaults |
| `config/env` | Local secrets/overrides (gitignored) |
| `config/recovery-runbook.md` | Manual EC2/bootc recovery before Test 2 |
| `hub/rhem-values.yaml` | Helm values for `redhat-rhem` on matrujil-rhem |
| `hub/install-rhem.sh` | Idempotent Helm install + wait |
| `fleet/fleet-os-rollout-test.yaml` | Test Fleet (os.image filled by rollout scripts) |
| `image/Containerfile.good` | Known-good bootc image A |
| `image/Containerfile.bad` | Controlled-fail image B |
| `image/greenboot/99-rhem-os-rollout-fail.sh` | Required check used only on B |
| `infra/ec2/README.md` | AMI import + launch notes |
| `scripts/lib.sh` | Shared helpers (die, require_env, ts) |
| `scripts/00-prereqs.sh` … `70-restore.sh` | Operator workflow |
| `Makefile` | Thin targets wrapping scripts |
| `docs/prerequisites.md` | Filled P1–P19 table |
| `docs/results-template.md` | Jira-style PASS/FAIL/BLOCKED template |
| `results/` | Evidence dumps (gitignored) |

---

### Task 1: Scaffold config, Makefile, and shared lib

**Files:**
- Create: `config/env.example`
- Create: `scripts/lib.sh`
- Create: `Makefile`
- Modify: `README.md`
- Create: `docs/prerequisites.md` (empty table to fill later)

**Interfaces:**
- Consumes: nothing
- Produces: `require_env VAR`, `die MSG`, `ts`, `load_env` in `scripts/lib.sh`; Make targets that call scripts

- [ ] **Step 1: Create `config/env.example`**

```bash
# Copy to config/env and fill. Never commit config/env.

# OpenShift / RHEM
export KUBECONFIG=/Users/matrujil/Documents/ipi_installs/matrujil-rhem/auth/kubeconfig
export RHEM_CHART_VERSION=1.3.0
export FLIGHTCTL_API=https://api.flightctl.apps.matrujil-rhem.kni.syseng.devcluster.openshift.com
export FLIGHTCTL_AGENT_API=https://agent-api.flightctl.apps.matrujil-rhem.kni.syseng.devcluster.openshift.com
export OCP_APPS_DOMAIN=apps.matrujil-rhem.kni.syseng.devcluster.openshift.com

# Registry for bootc OS images (operator-controlled Quay repo)
export OS_IMAGE_REPO=quay.io/REPLACE_ME/rhem-os-rollout-lab
export OS_IMAGE_GOOD=${OS_IMAGE_REPO}:good
export OS_IMAGE_BAD=${OS_IMAGE_REPO}:bad

# Device / AWS
export AWS_REGION=us-east-2
export AWS_PROFILE=default
export EC2_INSTANCE_TYPE=m6i.large
export EC2_KEY_NAME=REPLACE_ME
export EC2_SUBNET_ID=REPLACE_ME
export EC2_SG_ID=REPLACE_ME
export DEVICE_NAME=os-rollout-test-01
export DEVICE_SSH=ec2-user@REPLACE_ME_PUBLIC_IP
export FLEET_NAME=os-rollout-test
```

- [ ] **Step 2: Create `scripts/lib.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { echo "error: $*" >&2; exit 1; }

ts() { date -u +%Y%m%dT%H%M%SZ; }

load_env() {
  [[ -f "$ROOT/config/env" ]] || die "missing $ROOT/config/env — copy from config/env.example"
  # shellcheck disable=SC1091
  set -a; source "$ROOT/config/env"; set +a
}

require_env() {
  local v
  for v in "$@"; do
    [[ -n "${!v:-}" ]] || die "set $v in config/env"
  done
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null || die "missing command: $c"
  done
}
```

- [ ] **Step 3: Create `Makefile`**

```makefile
SHELL := /bin/bash
.PHONY: prerequisites install-rhem build-images ami provision enroll verify \
	rollout-good rollout-failure collect-results restore clean-docs

prerequisites:    ; ./scripts/00-prereqs.sh
install-rhem:     ; ./hub/install-rhem.sh
build-images:     ; ./scripts/10-build-images.sh
ami:              ; ./scripts/15-build-ami.sh
provision:        ; ./scripts/20-provision-ec2.sh
enroll:           ; ./scripts/30-enroll-approve.sh
verify:           ; ./scripts/35-verify.sh
rollout-good:     ; ./scripts/40-rollout-good.sh
rollout-failure:  ; ./scripts/50-rollout-failure.sh
collect-results:  ; ./scripts/60-collect-evidence.sh
restore:          ; ./scripts/70-restore.sh
```

- [ ] **Step 4: Update README with Make workflow pointer to `docs/design.md` and this plan**

- [ ] **Step 5: Commit**

```bash
git add config/env.example scripts/lib.sh Makefile README.md docs/prerequisites.md
git commit -m "chore: scaffold lab config and Make targets"
git push
```

---

### Task 2: Install flightctl CLI 1.3.0 on the laptop

**Files:**
- Create: `scripts/install-flightctl-cli.sh`

**Interfaces:**
- Consumes: none
- Produces: `~/.local/bin/flightctl` version client 1.3.0

- [ ] **Step 1: Write installer script**

```bash
#!/usr/bin/env bash
set -euo pipefail
VER=1.3.0
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) ARCH=amd64 ;;
  arm64|aarch64) ARCH=arm64 ;;
  *) echo "unsupported arch $ARCH" >&2; exit 1 ;;
esac
# Asset names follow flightctl GitHub releases; adjust if the release uses a different pattern.
DEST="${HOME}/.local/bin"
mkdir -p "$DEST"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
URL="https://github.com/flightctl/flightctl/releases/download/v${VER}/flightctl_${VER}_${OS}_${ARCH}.tar.gz"
# If tarball name differs, fall back to listing release assets and picking flightctl-* matching OS/ARCH.
curl -fsSL "$URL" -o "$TMP/flightctl.tgz" || {
  echo "direct URL failed; download the v${VER} flightctl binary for ${OS}/${ARCH} from" >&2
  echo "https://github.com/flightctl/flightctl/releases/tag/v${VER}" >&2
  exit 1
}
tar -xzf "$TMP/flightctl.tgz" -C "$TMP"
install -m 0755 "$TMP/flightctl" "$DEST/flightctl"
"$DEST/flightctl" version
```

- [ ] **Step 2: Run installer**

Run: `bash scripts/install-flightctl-cli.sh`  
Expected: client version prints `1.3.0` (server N/A until login)

- [ ] **Step 3: Commit**

```bash
git add scripts/install-flightctl-cli.sh
git commit -m "chore: add flightctl 1.3.0 CLI installer"
git push
```

---

### Task 3: Install RHEM 1.3.0 on matrujil-rhem

**Files:**
- Create: `hub/rhem-values.yaml`
- Create: `hub/install-rhem.sh`

**Interfaces:**
- Consumes: `KUBECONFIG`, cluster apps domain
- Produces: namespace `flightctl` with Routes `api.flightctl…`, `agent-api.flightctl…`, `ui.flightctl…`

- [ ] **Step 1: Write `hub/rhem-values.yaml`**

```yaml
global:
  enableOpenShiftExtensions: "true"
  enableMulticlusterExtensions: "false"
  generateCertificates: "builtin"
  routeExternalCertificate: "false"
  exposeServicesMethod: "route"
  baseDomain: flightctl.apps.matrujil-rhem.kni.syseng.devcluster.openshift.com
  storageClassName: gp3-csi
  auth:
    type: "openshift"
    insecureSkipTlsVerify: true
    openshift:
      createAdminUser: true
      authorizationUrl: https://oauth-openshift.apps.matrujil-rhem.kni.syseng.devcluster.openshift.com/oauth/authorize
      tokenUrl: https://oauth-openshift.apps.matrujil-rhem.kni.syseng.devcluster.openshift.com/oauth/token
ui:
  enabled: true
  auth:
    insecureSkipTlsVerify: true
clusterCli:
  image:
    image: registry.redhat.io/openshift4/ose-cli-rhel9
    tag: "v4.22"
imageBuilderApi:
  enabled: false
imageBuilderWorker:
  enabled: false
upgradeHooks:
  databaseMigrationDryRun: false
  scaleDown:
    condition: never
```

- [ ] **Step 2: Write `hub/install-rhem.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib.sh"
load_env
require_cmd helm oc
require_env KUBECONFIG RHEM_CHART_VERSION

helm repo add openshift-charts https://charts.openshift.io 2>/dev/null || true
helm repo update openshift-charts

oc create namespace flightctl --dry-run=client -o yaml | oc apply -f -
oc label namespace flightctl io.flightctl/instance=flightctl --overwrite

helm upgrade --install flightctl openshift-charts/redhat-rhem \
  --version "$RHEM_CHART_VERSION" \
  --namespace flightctl \
  --values "$ROOT/hub/rhem-values.yaml" \
  --wait --timeout 20m

oc -n flightctl get pods,route
echo "API:  $FLIGHTCTL_API"
echo "Agent:$FLIGHTCTL_AGENT_API"
```

- [ ] **Step 3: Run install**

Run: `make install-rhem` (after `cp config/env.example config/env` and editing paths)  
Expected: pods Ready; routes present; `helm list -n flightctl` shows `flightctl` chart `1.3.0`

- [ ] **Step 4: Operator login smoke**

```bash
export KUBECONFIG=$(mktemp)
oc login https://api.matrujil-rhem.kni.syseng.devcluster.openshift.com:6443 -u kubeadmin --insecure-skip-tls-verify
# password from /Users/matrujil/Documents/ipi_installs/matrujil-rhem/auth/kubeadmin-password
flightctl login "$FLIGHTCTL_API" --token "$(oc whoami -t)" --insecure-skip-tls-verify
flightctl version
flightctl get fleets
```

Expected: `flightctl get fleets` succeeds (empty list OK)

- [ ] **Step 5: Commit**

```bash
git add hub/rhem-values.yaml hub/install-rhem.sh
git commit -m "feat: add RHEM 1.3.0 Helm install for matrujil-rhem"
git push
```

---

### Task 4: Prerequisites script, recovery runbook, prerequisites table

**Files:**
- Create: `scripts/00-prereqs.sh`
- Create: `config/recovery-runbook.md`
- Modify: `docs/prerequisites.md`

**Interfaces:**
- Consumes: `load_env`, hub login
- Produces: printed gate results; filled markdown table; runbook operators can follow offline

- [ ] **Step 1: Write recovery runbook** covering: SSH/SSM to EC2; `sudo bootc status`; `sudo bootc rollback` / switch to previous deployment; if unrecoverable terminate EC2 and relaunch from good AMI; never touch OpenShift node machines.

- [ ] **Step 2: Write `scripts/00-prereqs.sh`** checking: `oc`/`flightctl`/`aws`/`podman` present; cluster Available; RHEM pods/routes; `flightctl get fleets`; registry env set; AWS identity. Exit non-zero on hard-gate failure. Append a timestamped snippet under `results/prereqs-$(ts).txt`.

- [ ] **Step 3: Run `make prerequisites` and fill `docs/prerequisites.md` P1–P19** with Pass/Fail/Pending. Mark Test-2-only rows Pending until device exists.

- [ ] **Step 4: Commit**

```bash
git add scripts/00-prereqs.sh config/recovery-runbook.md docs/prerequisites.md
git commit -m "docs: add recovery runbook and prerequisites checks"
git push
```

---

### Task 5: Fleet manifest + evidence collector

**Files:**
- Create: `fleet/fleet-os-rollout-test.yaml`
- Create: `scripts/60-collect-evidence.sh`
- Create: `docs/results-template.md`

**Interfaces:**
- Consumes: `FLEET_NAME`, `DEVICE_NAME`, `OS_IMAGE_*`
- Produces: applied Fleet object; `results/<label>-<ts>/` evidence packs

- [ ] **Step 1: Create Fleet YAML** (os.image left as placeholder comment; rollout scripts patch/apply)

```yaml
apiVersion: flightctl.io/v1alpha1
kind: Fleet
metadata:
  name: os-rollout-test
spec:
  selector:
    matchLabels:
      fleet: os-rollout-test
  template:
    metadata:
      labels:
        fleet: os-rollout-test
    spec:
      os:
        image: REPLACE_WITH_DIGEST_PINNED_REF
      config: []
      systemd:
        matchPatterns: []
```

Confirm kind/apiVersion against `flightctl apply --help` / live CRD if the chart uses a different group — adjust before apply.

- [ ] **Step 2: Write collector** dumping hub JSON + optional SSH device section into `results/$LABEL-$(ts)/`.

- [ ] **Step 3: Commit**

```bash
git add fleet/fleet-os-rollout-test.yaml scripts/60-collect-evidence.sh docs/results-template.md
git commit -m "feat: add test Fleet manifest and evidence collector"
git push
```

---

### Task 6: Bootc Containerfiles (good / bad)

**Files:**
- Create: `image/Containerfile.good`
- Create: `image/Containerfile.bad`
- Create: `image/greenboot/99-rhem-os-rollout-fail.sh`
- Create: `scripts/10-build-images.sh`

**Interfaces:**
- Consumes: `OS_IMAGE_GOOD`, `OS_IMAGE_BAD`, registry auth (local podman login; not in git)
- Produces: pushed digests printed to stdout and `results/image-digests-*.txt`

- [ ] **Step 1: Write fail check script**

```bash
#!/bin/bash
# Installed only on image B under /etc/greenboot/check/required.d/
set -euo pipefail
if [[ -e /etc/rhem-os-rollout-test/FAIL ]]; then
  echo "rhem-os-rollout-test: FAIL marker present" >&2
  exit 1
fi
exit 0
```

- [ ] **Step 2: Write `Containerfile.good`** based on `registry.redhat.io/rhel10/rhel-bootc:10.2` (or current 10.x tag available to the operator): install `flightctl-agent`, `greenboot`, `flightctl-greenboot` (exact package names as published for 1.3), mask `bootc-fetch-apply-updates.timer`, write `/etc/rhem-os-rollout-test/GOOD`, do **not** install the FAIL marker or fail script.

- [ ] **Step 3: Write `Containerfile.bad`** `FROM` the good image tag/digest locally or duplicate stages; `COPY` fail script to `/etc/greenboot/check/required.d/99-rhem-os-rollout-fail.sh` and `RUN touch /etc/rhem-os-rollout-test/FAIL && chmod 755 …/99-rhem-os-rollout-fail.sh`.

- [ ] **Step 4: Write `scripts/10-build-images.sh`** — `podman build` both, `podman push`, `skopeo inspect` digests, save digests to results.

- [ ] **Step 5: Operator fills Quay repo in `config/env`, `podman login quay.io`, run `make build-images`**

Expected: two digests printed; pullable from a throwaway machine.

- [ ] **Step 6: Commit Containerfiles/scripts only (no digests with credentials)**

```bash
git add image/ scripts/10-build-images.sh
git commit -m "feat: add good/bad bootc images and build script"
git push
```

---

### Task 7: AMI from image A + EC2 provision

**Files:**
- Create: `scripts/15-build-ami.sh`
- Create: `scripts/20-provision-ec2.sh`
- Create: `infra/ec2/README.md`

**Interfaces:**
- Consumes: good image ref, AWS creds, subnet/SG/key in `config/env`
- Produces: `AMI_ID` and `INSTANCE_ID` written into `config/env` (local) / printed for operator

- [ ] **Step 1: Document in `infra/ec2/README.md`** the bootc-image-builder → AMI path for AWS (privileged bib container with AWS credentials, config.toml for ami output, region `us-east-2`). Note RHSM/registry.redhat.io requirements.

- [ ] **Step 2: Write `scripts/15-build-ami.sh`** wrapping bib per README; on success print `AMI_ID=…` and instruct operator to set it in `config/env`.

- [ ] **Step 3: Write `scripts/20-provision-ec2.sh`** to:
  - create/reuse SG allowing SSH from operator IP and egress 443
  - `aws ec2 run-instances` with the AMI, `m6i.large`, key pair, tags `Name=os-rollout-test-01`
  - wait until status OK, print public DNS/IP, update operator to set `DEVICE_SSH`

- [ ] **Step 4: Run AMI build + provision** (operator present for RHSM/registry auth if prompted)

Expected: SSH works; on instance `sudo bootc status` shows image-mode deployment from A.

- [ ] **Step 5: Commit scripts/docs (not AMI IDs if they encode account specifics — AMI id in env.example as REPLACE_ME is fine)**

```bash
git add scripts/15-build-ami.sh scripts/20-provision-ec2.sh infra/ec2/README.md
git commit -m "feat: add bootc AMI build and EC2 provision scripts"
git push
```

---

### Task 8: Enroll, approve, verify baseline

**Files:**
- Create: `scripts/30-enroll-approve.sh`
- Create: `scripts/35-verify.sh`

**Interfaces:**
- Consumes: agent-api URL, device SSH, fleet labels
- Produces: device enrolled with `fleet=os-rollout-test`, Online in `flightctl get devices`

- [ ] **Step 1: Write enroll script** using `flightctl` enrollment flow for image-mode (generate enrollment config / CSR approval pattern for 1.3 — verify exact subcommands against `flightctl --help` on the installed CLI). Label device `fleet=os-rollout-test`. Apply Fleet with `os.image` set to current booted digest (no change yet) or omit os.image until Test 1 if API requires a value.

- [ ] **Step 2: Write verify script** — device Online; `bootc status` via SSH; rpm query greenboot packages; agent can reach agent-api (`curl -k` or journal); write `results/baseline-$(ts)/`.

- [ ] **Step 3: Run enroll + verify**

Expected: `flightctl get device/$DEVICE_NAME -o yaml` shows labels and Online.

- [ ] **Step 4: Update `docs/prerequisites.md` rows P4–P11, P14–P19 from evidence**

- [ ] **Step 5: Commit**

```bash
git add scripts/30-enroll-approve.sh scripts/35-verify.sh docs/prerequisites.md
git commit -m "feat: add device enroll/approve and baseline verify"
git push
```

---

### Task 9: Test 1 — known-good OS rollout

**Files:**
- Create: `scripts/40-rollout-good.sh`
- Create: `docs/test1-notes.md` (timeline filled during run)

**Interfaces:**
- Consumes: digest for image A (or A′ built with a visible marker bump if already on A)
- Produces: `results/test1-<ts>/` with before/during/after

- [ ] **Step 1: Write rollout-good script** — collect before; set Fleet `spec.os.image` to digest-pinned A (or A′); `flightctl apply`; poll device updated/summary until timeout (e.g. 45m); collect after; exit 0 only if bootc + RHEM agree.

- [ ] **Step 2: Execute `make rollout-good`**

Expected: PASS criteria from design §7 Test 1, or explicit FAIL/BLOCKED with evidence.

- [ ] **Step 3: Fill `docs/test1-notes.md` and commit notes (not raw secrets)**

```bash
git add scripts/40-rollout-good.sh docs/test1-notes.md
git commit -m "feat: add Test 1 known-good OS rollout script"
git push
```

---

### Task 10: Test 2 — failure/recovery (gated)

**Files:**
- Create: `scripts/50-rollout-failure.sh`
- Create: `docs/test2-notes.md`
- Modify: `docs/prerequisites.md` (P10–P15 gate decision)

**Interfaces:**
- Consumes: image B digest; recovery runbook; greenboot feasibility result
- Produces: PASS/FAIL/BLOCKED evidence under `results/test2-<ts>/`

- [ ] **Step 1: Feasibility probe on device** — confirm whether custom `required.d` runs; record in prerequisites. If not safe → script exits with message `BLOCKED` and writes notes; do not point Fleet at B.

- [ ] **Step 2: Write failure rollout script** — only proceeds if gate file/env `TEST2_GATE=pass`; applies image B; polls through max boots; expects rollback to A; collects RHEM enums.

- [ ] **Step 3: Execute or record BLOCKED**

- [ ] **Step 4: Commit**

```bash
git add scripts/50-rollout-failure.sh docs/test2-notes.md docs/prerequisites.md
git commit -m "feat: add gated Test 2 failure/recovery script"
git push
```

---

### Task 11: Restore, responsibility matrix, final result

**Files:**
- Create: `scripts/70-restore.sh`
- Create: `docs/responsibility-matrix.md`
- Create: `docs/result.md`
- Modify: `docs/design.md` status line to Implemented/Executed

**Interfaces:**
- Consumes: all prior evidence
- Produces: restored/terminated EC2; final PASS/FAIL/BLOCKED write-up

- [ ] **Step 1: Write restore script** — Fleet back to A or delete Fleet after decommission; optional `aws ec2 terminate-instances`; remind operator cluster destroy is `openshift-install destroy --dir …/matrujil-rhem`.

- [ ] **Step 2: Fill responsibility matrix and `docs/result.md` from evidence only**

- [ ] **Step 3: Commit final docs**

```bash
git add scripts/70-restore.sh docs/responsibility-matrix.md docs/result.md docs/design.md
git commit -m "docs: record investigation result and restore procedure"
git push
```

---

## Spec coverage check

| Design section | Tasks |
|---|---|
| Goal / responsibility split | 9–11 |
| AWS hub + EC2 architecture | 3, 7, 8 |
| New public repo harness layout | 1, 5, 6 |
| RHEM install lean | 3 |
| Images A/B + greenboot gate | 6, 10 |
| Test 1 / Test 2 / evidence | 5, 9, 10 |
| Restore / no secrets | 4, 11 + `.gitignore` |

## Placeholder scan

No TBD steps; operator REPLACE_ME values confined to `config/env.example`. CLI asset URL in Task 2 may need adjustment if GitHub asset naming differs — script already has fallback message.

---

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-10-01-rhem-os-rollout-lab.md`.

Two execution options:

1. **Subagent-Driven (recommended)** — fresh subagent per task, review between tasks  
2. **Inline Execution** — execute tasks in this session with checkpoints  

Which approach?
