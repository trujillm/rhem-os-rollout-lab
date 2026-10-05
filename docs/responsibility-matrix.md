# Responsibility matrix

Consolidated from the per-test matrices in `docs/test1-notes.md` and `docs/test2-notes.md`.
Filled from evidence only (gitignored `results/test1-20261002T184924Z/`,
`results/test2-20261003T005840Z/`, and live probe output cited in those notes) — no inferred
or assumed behavior.

Per `docs/design.md` §1:

| Layer | Owns |
| --- | --- |
| **RHEM** | Desired OS image via Fleet, orchestration, device/Fleet status reporting |
| **OS** | bootc stage/switch/reboot, greenboot health, automatic rollback |
| **App/config** | Deliberate failure mechanism used only for Test 2 |

## Test 1 — known-good OS rollout (PASS)

| Layer | Question | Answer | Source |
| --- | --- | --- | --- |
| RHEM (hub) | Did the hub accept Fleet `os.image`? | Yes — `200 OK` | `hub/fleet-apply.txt` |
| RHEM (hub) | Did the device report matching rendered spec? | Yes, after recovery — `renderedVersion=3` matches annotation `3` | `after/hub/device.json` |
| RHEM (agent) | Did the agent ever get stuck on stale state? | Yes — persisted `/var/lib/flightctl/rollback.json` kept marking spec v3 "failed" across agent restarts even though bootc was already booted on the correct digest; required a manual stop/archive-state/restart to resync (not scripted — see `docs/test1-notes.md` "Manual recovery step") | on-device journal + `rollback.json` |
| OS (bootc) | Is booted deployment the intended digest? | Yes — `cd08cfb8...` matches target | `after/device/bootc-status.json` |
| OS (AMI/greenboot) | Any pre-existing OS-level landmine? | Yes — AMI's first boot left a greenboot grubenv rollback-trigger / exhausted boot-counter state that skipped the first post-switch boot into A′; cleared manually, not a Test-1 product behavior | `docs/test1-notes.md` timeline 18:36–18:39 |
| App/config | Any application drift? | N/A — empty `applications`/`config` in this Fleet template | `fleet-applied.yaml` |

**Verdict:** PASS. Evidence: `results/test1-20261002T184924Z/`.

## Test 2 — failure/recovery feasibility gate (BLOCKED)

| Layer | Question | Answer | Source |
| --- | --- | --- | --- |
| App/config (image B design) | Does the custom `required.d` fail-marker mechanism run? | No — disabled before evaluation | `probe/greenboot-conf-after.txt` |
| RHEM (`flightctl-greenboot`) | Does RHEM restrict which greenboot checks can trigger rollback? | Yes — `flightctl-configure-greenboot.service` (`Before=greenboot-healthcheck.service`) disables any `required.d` script not matching `*flightctl*`, writing it into `DISABLED_HEALTHCHECKS` in `greenboot.conf` before greenboot ever evaluates it | `/usr/share/flightctl/functions/greenboot.sh` (`find_third_party_scripts`), confirmed live by probe |
| OS (greenboot/bootc) | Is greenboot itself wired and enabled? | Yes — `greenboot-healthcheck.service`, `greenboot-set-rollback-trigger.service`, `flightctl-greenboot` all enabled | `docs/prerequisites.md` P18 |
| RHEM (hub) | Was Fleet pointed at B? | No — gate blocked before `apply_fleet_image` ran | `results/test2-20261003T005840Z/` (no `hub/fleet-apply.txt`) |

**Verdict:** BLOCKED (feasibility gate, not FAIL — greenboot is present and the
flightctl-shipped check works; only the *custom* `required.d` extension point this lab's
image B depends on is disabled by product automation). Evidence:
`results/test2-20261003T005840Z/`.

## Restore

| Layer | Question | Answer | Source |
| --- | --- | --- | --- |
| RHEM (hub) | Does re-applying Fleet `os.image` at the known-good digest converge idempotently? | Yes — Test 1's final run (3rd apply, already-converged state) reached Online+UpToDate in ~14s on poll 1 | `results/test1-20261002T184924Z/poll.log` |
| OS (bootc) | Does the device remain on the known-good digest across a repeat apply? | Yes — `bootc status` booted digest unchanged at `cd08cfb8...` | `results/test1-20261002T184924Z/after/device/bootc-status.json` |
| Operator | Is cluster/EC2 teardown part of this repo's automation? | No — `scripts/70-restore.sh` only restores Fleet `os.image` and (opt-in) deletes the Fleet / terminates EC2; `openshift-install destroy` remains a manual, operator-owned step outside this repo | `docs/design.md` §7 "Restore / teardown"; `scripts/70-restore.sh` |

`scripts/70-restore.sh` was written and syntax-checked against these patterns but not executed
against the live environment as part of this task (no new infra-mutating action taken beyond
what Tasks 1–10 already produced evidence for).

## Cross-cutting follow-ups (not fixed here — investigation only)

- RHEM 1.3's agent persists a "failed version" marker that is not automatically cleared once the
  device is demonstrably on the correct image (Test 1).
- RHEM 1.3's `flightctl-configure-greenboot.service` unconditionally disables any third-party
  `required.d`/`wanted.d` greenboot check not shipped by flightctl itself, which blocks the
  documented greenboot extension point for OS/app-level custom health checks on
  flightctl-managed devices (Test 2).
- The AMI build left a greenboot grubenv counter in a half-exhausted state from its own first
  boot; worth a look in `scripts/15-build-ami.sh` (Test 1).
