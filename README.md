# rhem-os-rollout-lab

Lean AWS lab to validate **RHEM / flightctl OS image rollout and recovery** (bootc + greenboot) without the Fury demo stack.

**Design:** [docs/design.md](docs/design.md)

**Implementation plan:** [docs/superpowers/plans/2026-10-01-rhem-os-rollout-lab.md](docs/superpowers/plans/2026-10-01-rhem-os-rollout-lab.md)

## Make workflow

Copy `config/env.example` to `config/env` and fill in operator values (never commit `config/env`).

Run lab steps via the root `Makefile`, for example:

```bash
make prerequisites   # after scripts exist
make install-rhem
make build-images
```

Target order and gates are defined in the design doc and implementation plan above.

## Status

Scaffold (config, `scripts/lib.sh`, Makefile) in place; scripts, images, and Fleet follow the plan.

## What this is / is not

| Is | Is not |
|---|---|
| OpenShift hub (`matrujil-rhem`) + RHEM 1.3 | HP ZGX Fury / Tailscale demo |
| One EC2 bootc device | Twelve robot micro-VMs |
| Fleet `os-rollout-test` via `flightctl apply` | Flywheel / ROS / GPU / ACT |

## Secrets

Public repository. Never commit kubeconfigs, pull secrets, tokens, or `config/env`.
