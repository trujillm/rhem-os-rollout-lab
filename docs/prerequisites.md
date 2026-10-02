# Prerequisites (P1–P19)

Filled from `make prerequisites` on 2026-10-02 (evidence: `results/prereqs-20261002T133126Z.txt`).

**Worker capacity:** The default IPI worker profile (`m6i.large` ×2) is too small for the full RHEM chart; `flightctl-kv` needs roughly **m6i.xlarge** headroom on at least one worker. See [hub/README.md](../hub/README.md).

| ID | Check | Status | Notes |
| --- | --- | --- | --- |
| P1 | `oc` on PATH | Pass | `/opt/homebrew/bin/oc` |
| P2 | `flightctl` on PATH | Pass | `~/.local/bin/flightctl` |
| P3 | `aws` on PATH | Pass | |
| P4 | `podman` on PATH | Pass | |
| P5 | Hub env vars (`KUBECONFIG`, `RHEM_CHART_VERSION`, `FLIGHTCTL_*`, `OCP_APPS_DOMAIN`) | Pass | `config/env` (local, gitignored) |
| P6 | OpenShift ClusterVersion Available | Pass | `Available=True` |
| P7 | RHEM / flightctl pods healthy | Pass | All pods Running or Completed in `flightctl` |
| P8 | flightctl API routes | Pass | `flightctl-api`, `flightctl-agent-api` |
| P9 | Operator `flightctl login` + `get fleets` | Pass | kubeadmin bearer token via local kubeconfig |
| P10 | OS image registry env (`OS_IMAGE_*`, no `REPLACE_ME`) | Fail | Quay repo not set in `config/env` yet (`make build-images`) |
| P11 | AWS caller identity | Pass | `sts get-caller-identity` OK |
| P12 | EC2 provision env (`EC2_*`, `DEVICE_SSH`) | Pending | `REPLACE_ME` until `make provision` |
| P13 | Worker capacity for RHEM (`flightctl-kv` schedules) | Pass | After scaling workers to ~`m6i.xlarge` per hub README |
| P14 | EC2 bootc device provisioned | Pending | No device until AMI/provision (Task 7) |
| P15 | Device enrolled (`fleet=os-rollout-test`) | Pending | Task 8 |
| P16 | Device Online in RHEM | Pending | Task 8 |
| P17 | bootc image-mode on device (image A) | Pending | Task 7–8 |
| P18 | greenboot / Test 2 feasibility on device | Pending | Test 2 gate; probe on live device |
| P19 | Recovery runbook present | Pass | [config/recovery-runbook.md](../config/recovery-runbook.md) |
