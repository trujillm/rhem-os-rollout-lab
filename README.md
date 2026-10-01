# rhem-os-rollout-lab

Lean AWS lab to validate **RHEM / flightctl OS image rollout and recovery** (bootc + greenboot) without the Fury demo stack.

**Design:** [docs/design.md](docs/design.md)

## Status

Design approved. Implementation harness (Makefile, scripts, images, Fleet) comes next.

## What this is / is not

| Is | Is not |
|---|---|
| OpenShift hub (`matrujil-rhem`) + RHEM 1.3 | HP ZGX Fury / Tailscale demo |
| One EC2 bootc device | Twelve robot micro-VMs |
| Fleet `os-rollout-test` via `flightctl apply` | Flywheel / ROS / GPU / ACT |

## Secrets

Public repository. Never commit kubeconfigs, pull secrets, tokens, or `config/env`.
