# Final result — RHEM OS rollout & recovery lab

**Date:** 2026-10-05
**Scope:** `docs/design.md` §1 — can RHEM/flightctl 1.3 roll out an OS image via Fleet, report
status correctly, and correctly reflect recovery on a health failure. Investigation only; no
product rollback features were implemented to force a result.

## Overall outcome

**Investigation complete. Not a clean product PASS.** Test 1 (OS rollout) **PASSED** with one
manual agent-state recovery along the way. Test 2 (health-failure rollback) is **BLOCKED** at
its feasibility gate — the custom greenboot mechanism this lab's image B relies on never runs
on this build, so rollback-on-failure was not exercised. Per `docs/design.md` §10's "done when"
criteria, items 1–2, 4, and 6 are satisfied; item 3 ("Test 2 executed only if safe") resolved to
BLOCKED rather than executed; item 5 (restore) has a correct, ready script (see below) but was
not run against the live environment as part of this task.

## Test 1 — known-good OS rollout

**Verdict: PASS**

| | Expected | Observed |
| --- | --- | --- |
| Fleet apply | Hub accepts `spec.template.spec.os.image` pinned to target digest | `200 OK`; `fleet-applied.yaml` matches |
| Device convergence | `summary.status=Online`, `updated.status=UpToDate`, `os.imageDigest` = target | Reached after one manual intervention (see below); final run converged on poll 1 |
| bootc | Booted deployment digest = target | `sha256:cd08cfb8fe911855ce8dab9b3ff3b42fd2fdc9e0c9aa86c4d0f6e630cdbb7c68`, confirmed |

**Gap observed (not a Test 1 failure, but worth recording):** a leftover AMI greenboot
grubenv counter caused the first post-switch boot to skip A′, and RHEM 1.3's agent then
persisted `/var/lib/flightctl/rollback.json` marking spec version 3 "failed" — it did not
self-clear once bootc was demonstrably on the correct digest. Recovery required a manual
stop-agent / archive-state / restart-agent action, documented in `docs/test1-notes.md` and
consistent with `config/recovery-runbook.md`'s targeted-recovery guidance. This is flagged as a
product gap, not papered over with new automation.

Evidence: `results/test1-20261002T184924Z/`.

## Test 2 — health failure and recovery

**Verdict: BLOCKED** (feasibility gate, per `docs/design.md` §6 "Test 2 feasibility gate")

| | Expected (if gate had passed) | Observed |
| --- | --- | --- |
| Feasibility gate | Custom `required.d` check runs and can trigger rollback, or only flightctl-shipped checks matter and the gate blocks safely | `flightctl-configure-greenboot.service` disables any non-flightctl `required.d` script (via `DISABLED_HEALTHCHECKS`) **before** `greenboot-healthcheck.service` evaluates it — confirmed live with a non-destructive probe, not inferred from source alone |
| Fleet → image B | Only if gate passes | Fleet was **not** pointed at image B; no reboot induced |

This is BLOCKED rather than FAIL because greenboot itself is present, wired, and the
flightctl-shipped health check works — only the *custom* `required.d` extension point that
image B's deliberate-failure mechanism depends on is disabled by product automation. Per task
scope, the lab did not work around this (e.g., renaming the script to pass as a flightctl
check, or building a different failure mechanism through the flightctl-agent service itself).

Evidence: `results/test2-20261003T005840Z/`.

## Responsibility (RHEM vs OS vs App/config)

See `docs/responsibility-matrix.md` for the full evidence-sourced breakdown. Summary:

- **RHEM** correctly orchestrated the Fleet→device rollout and reported matching state once its
  own agent-side stale-state issue was cleared; it also correctly left the device untouched when
  Test 2's gate blocked (Fleet was never pointed at B).
- **OS (bootc)** correctly staged/switched/booted the target digest in Test 1. Greenboot itself
  is enabled and functional for flightctl-shipped checks; it is **not** reachable by this lab's
  custom `required.d` check because RHEM's `flightctl-configure-greenboot.service` disables
  non-flightctl checks before evaluation.
- **App/config** (image B's deliberate-failure marker) is correctly built and installed, but
  never gets evaluated on this build — the gate exists specifically to catch this before
  inducing a misleading "PASS".

## Restore

`scripts/70-restore.sh` was written per `docs/design.md` §7 "Restore / teardown" and the
existing `scripts/40-rollout-good.sh` / `scripts/lib.sh` patterns:

1. Re-resolves the known-good digest (current `:good` tag, or an explicit `OS_IMAGE_TARGET`
   override) and re-applies Fleet `os.image` to it, polling for Online+UpToDate+bootc agreement.
2. `DELETE_FLEET=1` (opt-in): after restore is confirmed, deletes `Fleet/os-rollout-test`.
3. `TERMINATE_EC2=1` (opt-in): terminates the EC2 device via `aws ec2 terminate-instances`,
   requiring `INSTANCE_ID` from `config/env` and re-confirming the live instance's `Name` tag
   before terminating — never runs by default.
4. Always prints a reminder that OpenShift cluster teardown (`openshift-install destroy`) is a
   separate, operator-owned step outside this repo.

The script was syntax-checked but **not executed** against the live environment as part of this
task — no new infra-mutating action was taken beyond what Tasks 1–10 already produced evidence
for. Running it (and deciding on `DELETE_FLEET`/`TERMINATE_EC2`) is left to the operator.

## Done-when checklist (`docs/design.md` §10)

| # | Item | Status |
| --- | --- | --- |
| 1 | Prerequisites table filled | Done — `docs/prerequisites.md` (P1–P19) |
| 2 | Test 1 executed or BLOCKED with evidence | Done — PASS, `results/test1-20261002T184924Z/` |
| 3 | Test 2 executed only if safe; otherwise BLOCKED with gap | Done — BLOCKED, `results/test2-20261003T005840Z/` |
| 4 | RHEM vs OS vs app/config recorded separately | Done — `docs/responsibility-matrix.md` |
| 5 | Environment restored / EC2 terminated as appropriate | Script ready (`scripts/70-restore.sh`); not run live this task — operator-owned next step |
| 6 | Jira-style result: PASS/FAIL/BLOCKED with expected vs observed | Done — this document |

## Follow-ups worth raising upstream (not fixed in this lab)

1. RHEM 1.3's agent persists a "failed version" rollback marker that does not self-clear once
   the device is demonstrably on the correct image/digest (Test 1).
2. RHEM 1.3's `flightctl-configure-greenboot.service` disables any third-party greenboot
   `required.d`/`wanted.d` check that isn't flightctl-shipped, blocking the documented greenboot
   custom-check extension point on flightctl-managed devices (Test 2).
3. The AMI build (`scripts/15-build-ami.sh`) left a greenboot grubenv counter in a
   half-exhausted state from its own first boot — worth resetting explicitly before handoff.
