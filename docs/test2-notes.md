# Test 2 — failure/recovery (notes)

See `docs/design.md` § Test 2 feasibility gate and §7 Test 2 for PASS/FAIL/BLOCKED criteria.
This file is the narrative timeline + verdict; raw evidence lives under `results/test2-*/`
(gitignored, not committed).

## Verdict

**BLOCKED** — the feasibility gate failed. On this live RHEM 1.3 / `flightctl-greenboot`
build, **custom `/etc/greenboot/check/required.d/` scripts are disabled by product automation
before `greenboot-healthcheck.service` ever evaluates them.** Image B's deliberate-failure
mechanism (`image/greenboot/99-rhem-os-rollout-fail.sh`, installed to
`/etc/greenboot/check/required.d/`) would face the same fate and never run. Per
`docs/design.md`'s gate ("if neither can safely induce failure → BLOCKED; do not invent a
custom rollback mechanism") and the task brief ("if not safe → BLOCKED; do not point Fleet at
B"), Fleet was **not** pointed at image B and no reboot was induced on the device.

Blocking run: `results/test2-20261003T005840Z/` (`gate.env`, `verdict.env`, `result.txt`,
`probe/`).

## Feasibility probe (what ran, and why it's non-destructive)

`scripts/50-rollout-failure.sh`'s `feasibility_probe()`:

1. Backs up `/etc/greenboot/greenboot.conf` on the device.
2. Writes a harmless script (`exit 0`, never touches the `FAIL` marker) to
   `/etc/greenboot/check/required.d/50-rollout-failure-probe.sh` — the same directory and
   convention image B's `99-rhem-os-rollout-fail.sh` uses.
3. Runs `systemctl restart flightctl-configure-greenboot.service` — the exact unit that runs on
   every real boot, ordered `Before=greenboot-healthcheck.service`, `WantedBy=greenboot-healthcheck.service`.
4. Reads `/etc/greenboot/greenboot.conf` back and checks whether the probe script was added to
   `DISABLED_HEALTHCHECKS`.
5. Removes the probe script and restores the original `greenboot.conf` from the backup.

No reboot, no Fleet change, no modification to the booted deployment. Confirmed clean
afterward: `required.d/` is empty again, `greenboot.conf` matches the pre-probe copy, no
backup file left behind (checked live post-run).

### What the probe found

`/usr/libexec/flightctl/configure-greenboot.sh` (source:
`/usr/share/flightctl/functions/greenboot.sh`'s `find_third_party_scripts`) scans both
`/usr/lib/greenboot/check/required.d` and `/etc/greenboot/check/required.d`, and treats any
script that does **not** match `*flightctl*` and is **not** one of the three core greenboot
scripts (`00_required_scripts_start.sh`, `01_repository_dns_check.sh`, `02_watchdog.sh`) as
"third-party" — then writes it into `DISABLED_HEALTHCHECKS` in `greenboot.conf`. Greenboot
itself (`greenboot health-check`) honors that list and skips disabled scripts entirely.

- Before probe: `DISABLED_HEALTHCHECKS=()`
  (`results/test2-20261003T005840Z/probe/greenboot-conf-before.txt`).
- After probe: `DISABLED_HEALTHCHECKS=( "50-rollout-failure-probe.sh")`
  (`results/test2-20261003T005840Z/probe/greenboot-conf-after.txt`).
- After cleanup: back to `DISABLED_HEALTHCHECKS=()`
  (`results/test2-20261003T005840Z/probe/greenboot-conf-restored.txt`, and reconfirmed live
  post-run).

This exactly matches the design's "or only flightctl-shipped checks matter" branch of the
feasibility gate — confirmed live, not assumed from reading source alone (the probe actually
exercised the unit).

## Timeline (UTC)

| Time | Event |
| --- | --- |
| 00:58:40 | `scripts/50-rollout-failure.sh` run: SSH + hub reachable; `before` snapshot taken — device Online/UpToDate on A′ (`sha256:cd08cfb8...`), `renderedVersion=3`. |
| 00:58:4x | Feasibility probe: probe script staged, `flightctl-configure-greenboot.service` restarted, probe script found in `DISABLED_HEALTHCHECKS` — gate=**blocked**. Probe script + conf cleaned up. |
| 00:58:51 | Verdict written: **BLOCKED**. Script exited 2 without calling `apply_fleet_image` — Fleet `os.image` untouched (confirmed still pinned to A′ digest after the run). |

## Preconditions also checked (informational — gate failed before these mattered for induction)

- **Grubenv state (landmine #1 from Task 9):** `boot_success=1`, no stale `boot_counter` or
  `greenboot_rollback_trigger` present (`results/test2-20261003T005840Z/before/device/grubenv.txt`)
  — the AMI poison seen in Test 1 is not currently present. Not exercised further since the
  gate blocked before any image switch.
- **Agent `rollback.json` (landmine #2 from Task 9):** currently in its default/empty state
  (confirmed separately via SSH, not re-copied into evidence since no induction occurred). If a
  future retry proceeds past the gate, re-check this before and after — Task 9 found RHEM 1.3's
  agent does not self-clear a previously-failed-version marker.

## Why this is BLOCKED and not FAIL

The design distinguishes FAIL ("mis-reporting or no rollback when health failed") from BLOCKED
("missing greenboot path or unsafe to induce failure"). Here, greenboot itself is present and
wired (`greenboot-healthcheck.service`, `greenboot-set-rollback-trigger.service`,
`flightctl-greenboot` all enabled — see `docs/prerequisites.md` P18) and the flightctl-shipped
health check (`20_check_flightctl_agent.sh`) does work. What's missing/unsafe is specifically
the *custom* `required.d` mechanism this lab's image B relies on: it is deliberately disabled
by `flightctl-configure-greenboot.service` before greenboot ever sees it, so applying B would
not exercise a genuine health-check failure — it would just converge cleanly, giving a false
"PASS" that doesn't actually probe rollback. Per task scope ("do not invent product rollback
features"), the lab does not work around this by, e.g., renaming the script to pass as a
flightctl check, pre-seeding `DISABLED_HEALTHCHECKS` to exclude it, or building a different
image that fails via the flightctl-agent service itself (a different, out-of-scope failure
mechanism not specified by the plan). BLOCKED stands as the honest result for the mechanism as
designed.

## Responsibility matrix (from evidence only)

| Layer | Question | Answer | Source |
| --- | --- | --- | --- |
| App/config (image B design) | Does the custom `required.d` fail-marker mechanism run? | No — disabled before evaluation | `probe/greenboot-conf-after.txt` |
| RHEM (`flightctl-greenboot`) | Does RHEM restrict which greenboot checks can trigger rollback? | Yes — `flightctl-configure-greenboot.service` disables all non-flightctl `required.d` scripts every boot | `/usr/share/flightctl/functions/greenboot.sh` (`find_third_party_scripts`), confirmed live |
| OS (greenboot/bootc) | Is greenboot itself wired and enabled? | Yes | `docs/prerequisites.md` P18; `systemctl is-enabled` output in probe run |
| RHEM (hub) | Was Fleet pointed at B? | No — gate blocked before `apply_fleet_image` | `results/test2-20261003T005840Z/` has no `hub/fleet-apply.txt` |

## Follow-ups

- Worth flagging upstream (not fixing here, per investigation-only scope): RHEM 1.3's
  `flightctl-configure-greenboot.service` unconditionally disables any third-party
  `required.d`/`wanted.d` greenboot check that doesn't match `*flightctl*`. This means any
  OS/app-level custom health check — not just this lab's fail marker — cannot drive an
  automatic bootc rollback on a flightctl-managed device unless it is shipped by flightctl
  itself. That is a meaningful constraint for anyone planning to use greenboot's documented
  `required.d` extension point on RHEM-managed fleets.
- If a future iteration of this lab wants a live PASS/FAIL (not BLOCKED) result for Test 2, the
  failure mechanism would need to go through the flightctl-shipped check instead (e.g., breaking
  `flightctl-agent` itself so `20_check_flightctl_agent.sh` fails) — that is a different image
  and a different design decision, out of scope for this task.
