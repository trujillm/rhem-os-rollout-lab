# Prerequisites (P1–P19)

Updated 2026-10-02 after Task 8 enroll/verify (evidence: `results/baseline-20261002T183027Z/`). Earlier rows also refreshed from live hub/device state.

**Worker capacity:** The default IPI worker profile (`m6i.large` ×2) is too small for the full RHEM chart; `flightctl-kv` needs roughly **m6i.xlarge** headroom on at least one worker. See [hub/README.md](../hub/README.md).

| ID | Check | Status | Notes |
| --- | --- | --- | --- |
| P1 | `oc` on PATH | Pass | `/opt/homebrew/bin/oc` |
| P2 | `flightctl` on PATH | Pass | `~/.local/bin/flightctl` v1.3.0 |
| P3 | `aws` on PATH | Pass | |
| P4 | `podman` on PATH | Pass | `/opt/homebrew/bin/podman` |
| P5 | Hub env vars (`KUBECONFIG`, `RHEM_CHART_VERSION`, `FLIGHTCTL_*`, `OCP_APPS_DOMAIN`) | Pass | `config/env` (local, gitignored) |
| P6 | OpenShift ClusterVersion Available | Pass | `Available=True` |
| P7 | RHEM / flightctl pods healthy | Pass | 12 Running + 1 Completed in `flightctl` |
| P8 | flightctl API routes | Pass | `flightctl-api`, `flightctl-agent-api` (plus UI/telemetry/remote-access) |
| P9 | Operator `flightctl login` + `get fleets` | Pass | kubeadmin bearer token via local kubeconfig |
| P10 | OS image registry env (`OS_IMAGE_*`, no `REPLACE_ME`) | Pass | `quay.io/matrujil/rhem-os-rollout-lab:{good,bad}` |
| P11 | AWS caller identity | Pass | `sts get-caller-identity` OK |
| P12 | EC2 provision env (`EC2_*`, `DEVICE_SSH`) | Pass | key/subnet/SG + `DEVICE_SSH=ec2-user@18.224.62.89` |
| P13 | Worker capacity for RHEM (`flightctl-kv` schedules) | Pass | After scaling workers to ~`m6i.xlarge` per hub README |
| P14 | EC2 bootc device provisioned | Pass | AMI `ami-0dfccb3062bb6e180`, instance `i-003d47109987f5f21` |
| P15 | Device enrolled (`fleet=os-rollout-test`) | Pass | alias `os-rollout-test-01`; metadata.name is agent-generated hash (RHEM 1.3); labels `fleet=os-rollout-test,alias=os-rollout-test-01`; owner `Fleet/os-rollout-test` |
| P16 | Device Online in RHEM | Pass | `status.summary.status=Online`, `updated=UpToDate` |
| P17 | bootc image-mode on device (image A) | Pass | booted `quay.io/matrujil/rhem-os-rollout-lab:good` @ `sha256:5ba1080134020a6d1d4cf0166b502ccd67f978b1d4febbc31afce2a3d7439eee` |
| P18 | greenboot / Test 2 feasibility on device | Pass | `greenboot-0.16.3`, `flightctl-greenboot-1.3.0` installed; inducing failure still gated to Task 10 |
| P19 | Recovery runbook present | Pass | [config/recovery-runbook.md](../config/recovery-runbook.md) |

**Enroll notes (Task 8):** Late-bind `/etc/flightctl/config.yaml` via `flightctl certificate request --output=embedded`, approve with `-l fleet=os-rollout-test -l alias=…`. Fleet is applied **without** `os.image` at enroll — digest-pinning the private Quay repo triggers an unauthorized prefetch and OutOfDate; Test 1 will set `os.image` once pull credentials are in place.
