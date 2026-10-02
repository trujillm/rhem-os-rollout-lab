# Evidence pack template

Copy this file into `results/<label>-<timestamp>/notes.md` (or keep a filled copy under `results/` locally; `results/` is gitignored). Base conclusions only on files from `scripts/60-collect-evidence.sh` — do not infer state without evidence.

## Run metadata

| Field | Value |
| --- | --- |
| Label | |
| Collected (UTC) | from `meta.env` |
| Test phase | prerequisites / enroll / test-1-good / test-2-failure / restore |
| Collector path | `results/<label>-<ts>/` |

## Hub (RHEM / flightctl)

| Check | Expected | Observed | Evidence file |
| --- | --- | --- | --- |
| Fleet exists | `fleet/os-rollout-test` | | `hub/fleet-os-rollout-test.yaml` |
| Fleet `spec.template.spec.os.image` | digest-pinned ref for phase | | same |
| Device enrolled | `DEVICE_NAME` Online | | `hub/device-*-summary.json` |
| Device labels | `fleet=os-rollout-test` | | `hub/device-*.yaml` |
| Fleet rollout status | Updated / progressing / failed (note enum) | | device summary + fleet status fields |

## Device (bootc / agent / greenboot)

| Check | Expected | Observed | Evidence file |
| --- | --- | --- | --- |
| bootc booted vs staged | match desired image for phase | | `device/bootc-status.txt` or `.json` |
| Lab marker | GOOD on A; FAIL only on B test | | `device/lab-markers.txt` |
| Agent healthy | no fatal errors in current boot | | `device/journal-flightctl-agent.txt` |
| greenboot | pass before reboot complete | | `device/journal-greenboot.txt` |
| Packages | flightctl-agent, greenboot present | | `device/rpm-versions.txt` |

If `device/README-skipped.txt` exists, SSH collection did not run — note why (no EC2 yet, key, or network).

## Responsibility matrix (fill from evidence only)

| Layer | Question | Answer | Source |
| --- | --- | --- | --- |
| RHEM | Did the hub accept the Fleet desired `os.image`? | | `hub/fleet-*.yaml` |
| RHEM | Did the device report matching rendered spec / summary? | | `hub/device-*` |
| OS (bootc) | Is the booted deployment the intended digest? | | `device/bootc-status*` |
| OS (bootc) | After Test 2, did rollback restore A? | | bootc + markers |
| App/config | Any application drift? | N/A for this lab (empty `applications`) | fleet template |

## Verdict

| Test | Result (PASS / FAIL / BLOCKED) | Expected vs observed (1–3 sentences) |
| --- | --- | --- |
| Test 1 — good rollout | | |
| Test 2 — failure + recovery | | |

## Follow-ups

- Gaps, blocked gates (see `docs/prerequisites.md`), or manual recovery steps taken (link `config/recovery-runbook.md`).
