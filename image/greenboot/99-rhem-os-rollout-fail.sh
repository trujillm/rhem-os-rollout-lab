#!/bin/bash
# Installed only on image B (Containerfile.bad) under /etc/greenboot/check/required.d/.
# A required.d check that exits non-zero fails greenboot's boot health check, which is what
# should trigger an automatic rollback to the previous deployment (bootc rollback) — that is
# the behavior Test 2 (docs/design.md) is probing for.
set -euo pipefail

if [[ -e /etc/rhem-os-rollout-test/FAIL ]]; then
  echo "rhem-os-rollout-test: FAIL marker present" >&2
  exit 1
fi

exit 0
