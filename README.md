# rhem-os-rollout-lab

Lean AWS lab to validate **RHEM / flightctl OS image rollout and recovery** (bootc + greenboot) without the Fury demo stack.

- **Design:** [docs/design.md](docs/design.md)
- **Result:** [docs/result.md](docs/result.md) — Test 1 PASS, Test 2 BLOCKED (feasibility gate)
- **Notes:** [docs/test1-notes.md](docs/test1-notes.md), [docs/test2-notes.md](docs/test2-notes.md)
- **Matrix:** [docs/responsibility-matrix.md](docs/responsibility-matrix.md)
- **Prerequisites:** [docs/prerequisites.md](docs/prerequisites.md)

## Make workflow

Copy `config/env.example` to `config/env` and fill in operator values (never commit `config/env`).

```bash
make prerequisites
make install-rhem
make build-images
make ami
make provision
make enroll
make verify
make rollout-good
make rollout-failure   # gated; exits BLOCKED if custom required.d cannot run
make collect-results
make restore           # Fleet back to known-good; TERMINATE_EC2=1 / DELETE_FLEET=1 are opt-in
```

Target order and gates are in [docs/design.md](docs/design.md). Cluster destroy stays operator-owned (`openshift-install destroy`).

## Status

Investigation complete. Not a clean product PASS — see [docs/result.md](docs/result.md). Restore script is ready; it has not been run against live infra.

## What this is / is not

| Is | Is not |
|---|---|
| OpenShift hub (`matrujil-rhem`) + RHEM 1.3 | HP ZGX Fury / Tailscale demo |
| One EC2 bootc device | Twelve robot micro-VMs |
| Fleet `os-rollout-test` via `flightctl apply` | Flywheel / ROS / GPU / ACT |

## Secrets

Public repository. Never commit kubeconfigs, pull secrets, tokens, or `config/env`.
