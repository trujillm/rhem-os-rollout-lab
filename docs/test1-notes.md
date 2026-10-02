# Test 1 — known-good OS rollout (notes)

See `docs/design.md` §7 Test 1 for PASS/FAIL/BLOCKED criteria and `docs/results-template.md`
for the evidence-pack structure. This file is the narrative timeline + verdict; raw evidence
lives under `results/test1-*/` (gitignored, not committed).

## Verdict

**PASS** — device Online + UpToDate; `bootc` booted digest agrees with Fleet `spec.os.image`
target (A′, digest `sha256:cd08cfb8fe9...dbb7c68`).

Final passing run: `results/test1-20261002T184924Z/` (`verdict.env`, `result.txt`).

## Setup

- Target: A′ — a thin marker-bump layer on top of known-good image **A**
  (`quay.io/matrujil/rhem-os-rollout-lab:good`), built via `scripts/40-rollout-good.sh`'s
  `build_aprime` (cluster buildah, same pattern as `scripts/10-build-images.sh`). A′ was used
  instead of re-pinning A because the device was already booted on A's digest — A′ gives a
  visible transition for Test 1.
- Private-registry pull auth: local `~/.config/containers/auth.json` copied to the device as
  `/etc/ostree/auth.json` (0600, root-owned). Verified via `skopeo inspect --authfile ... docker://$OS_IMAGE_GOOD`
  on-device before trusting bootc to pull. No credentials appear in any `results/` file (checked
  with `grep -rl` for `BEGIN PRIVATE KEY` / `auth.json` content / `password`).

## Timeline (UTC)

| Time | Event |
| --- | --- |
| 18:28:33 | Device enrolled to RHEM hub (`d7702be7...ing4420`, alias `os-rollout-test-01`). |
| 18:29:13 | First Fleet apply attempt failed prefetch: `permission denied` pulling `:good` — pull auth not yet installed on device. |
| 18:35:15 | `scripts/40-rollout-good.sh` run 1: pull-auth install + skopeo probe **PASS**; A′ built and pushed, marker `A-PRIME-20261002T183523Z`, digest `sha256:cd08cfb8f...`; Fleet applied with `os.image` pinned to A′ digest. |
| ~18:36–18:39 | Device staged/pulled A′ and switched; a leftover **greenboot grubenv poison** from the AMI's first boot (`greenboot_rollback_trigger` / exhausted boot counter) caused the first post-switch reboot to skip booting into A′. Cleared manually; device rebooted again. |
| 18:39 | Device actually boots A′ (digest `cd08cfb8...`); greenboot-success reached; RHEM reports Online. Agent, however, had already recorded the earlier skipped/rolled-back attempt and persisted `/var/lib/flightctl/rollback.json` marking **spec version 3 as failed**. |
| 18:39:43 | `scripts/40-rollout-good.sh` run 2: **BLOCKED** — SSH to device transiently unreachable (reboot in flight). |
| — | Operator paused here; Task 9 WIP report written as BLOCKED (`.superpowers/sdd/task-9-report.md`). |
| 18:41–18:42 | On each agent restart, log shows: `No OS update in progress` → `Marking version 3 as failed from previous rollback` → `New spec version received: 2 -> 3` with no further action — agent refuses to re-apply v3 because of the persisted rollback record, even though bootc is already on the correct digest. Hub stuck: `status.config.renderedVersion=2` vs rendered annotation `3`, `updated.status=OutOfDate`. |
| 18:46 (resume) | Confirmed live: SSH reachable, `bootc status` shows booted = A′ digest with marker `A-PRIME-20261002T183523Z` present; hub still `OutOfDate` for the reason above. |
| 18:48:42 | **Manual agent recovery** (one-time, not scripted — see below): stopped `flightctl-agent`, archived `/var/lib/flightctl/rollback.json` → `rollback.json.poisoned-20261002` on-device, removed the poisoned file, restarted the agent. Journal: `New spec version received: 0 -> 3` → `Spec reconciliation complete: current version 3` (no rollback message). |
| 18:48:5x | Hub confirms: `summary=Online`, `updated=UpToDate` ("Device was updated to the fleet's latest device spec"), `os.imageDigest=cd08cfb8...`, `config.renderedVersion=3` matching the `device-controller/renderedVersion: "3"` annotation. |
| 18:49:24–18:49:38 | `scripts/40-rollout-good.sh` run 3 (final), with `OS_IMAGE_TARGET` pinned explicitly to the already-booted A′ digest (avoids `BUILD_APRIME=auto` building a second A″ bump, since the `:good` tag now also resolves to the A′ digest): pull-auth probe PASS, Fleet re-applied idempotently, converged on **poll 1** (already in sync) in ~14s. **Verdict: PASS.** Evidence: `results/test1-20261002T184924Z/`. |

## Manual recovery step (not in `scripts/40-rollout-good.sh`)

The script implements the designed happy path (pin digest → apply → poll → verdict). The
agent-side "poisoned rollback" state above was an artifact of the AMI's leftover greenboot
grubenv counter from the *first ever* boot (pre-existing environmental issue, not something
Test 1 is meant to validate) compounding with the RHEM 1.3 agent's own failed-version bookkeeping.
Recovery was a manual, documented action matching `config/recovery-runbook.md`'s spirit (inspect
state → targeted recovery, not reinstall from scratch):

```bash
sudo systemctl stop flightctl-agent
sudo cp -a /var/lib/flightctl/rollback.json /var/lib/flightctl/rollback.json.poisoned-20261002
sudo rm -f /var/lib/flightctl/rollback.json
sudo systemctl start flightctl-agent
```

This is **not** baked into the committed script: it is a one-off clear of agent-persisted state
left over from the AMI poison + first-boot sequence, not a reusable product feature, and the task
scope is investigation-only (no inventing rollback automation). If this recurs on a fresh
AMI/device without the grubenv poison, it should not be needed — flag it for the AMI/greenboot
build (`scripts/15-build-ami.sh`) if seen again on a clean device.

## PASS evidence (final run `results/test1-20261002T184924Z/`)

- `verdict.env`: `verdict=PASS`, `target_digest=sha256:cd08cfb8fe911855ce8dab9b3ff3b42fd2fdc9e0c9aa86c4d0f6e630cdbb7c68`.
- `before/snapshot.env`, `after/snapshot.env`: both show `summary.status=Online`,
  `updated.status=UpToDate`, `os.imageDigest` matching target — i.e. the device was already
  converged going into this run (sync fix above), and the idempotent re-apply confirmed it stays
  converged.
- `after/device/bootc-status.json` / `before/device/bootc-status.txt`: `bootc status --booted.image.imageDigest`
  = target digest.
- `after/device/lab-markers.txt`: `GOOD` and `A-PRIME=A-PRIME-20261002T183523Z` present.
- `device/pull-auth-probe.txt`: skopeo inspect digest, no credentials in output.
- `hub/fleet-applied.yaml`, `hub/fleet-apply.txt`: Fleet `spec.template.spec.os.image` pinned to
  the target digest, applied with `200 OK`.
- `poll.log`: converged on poll 1 (hub + bootc already agreed before poll started).

## Responsibility matrix (from evidence only)

| Layer | Question | Answer | Source |
| --- | --- | --- | --- |
| RHEM (hub) | Did the hub accept Fleet `os.image`? | Yes — `200 OK`, `fleet-applied.yaml` | `hub/fleet-apply.txt` |
| RHEM (hub) | Did the device report matching rendered spec? | Yes, after recovery — `renderedVersion=3` matches annotation `3` | `after/hub/device.json`, device yaml |
| RHEM (agent) | Did the agent ever get stuck on stale state? | Yes — persisted `rollback.json` kept marking v3 failed across restarts despite bootc already correct | on-device journal + `rollback.json` |
| OS (bootc) | Is booted deployment the intended digest? | Yes — `cd08cfb8...` matches target | `after/device/bootc-status.json` |
| App/config | Any application drift? | N/A — empty `applications`/`config` in this Fleet template | `fleet-applied.yaml` |

## Follow-ups

- The AMI (`scripts/15-build-ami.sh`) left a greenboot grubenv rollback-trigger state from its
  own first boot; worth checking whether the AMI build should explicitly clear/reset greenboot
  counters before handoff so future device-under-test instances don't inherit a half-exhausted
  counter.
- RHEM 1.3's agent persists a "failed version" marker (`/var/lib/flightctl/rollback.json`) that
  is **not** automatically cleared once the device is demonstrably on the correct image/digest —
  it required a manual restart-with-state-clear to resync. This is a gap worth flagging upstream;
  not something this lab should paper over with custom automation (see task scope: investigation
  only, no invented rollback features).
