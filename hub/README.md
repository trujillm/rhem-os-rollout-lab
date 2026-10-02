# RHEM hub install (matrujil-rhem)

Install: `make install-rhem` (Helm chart `redhat-rhem` 1.3.0).

## Capacity note

The lab IPI profile (`m6i.large` ×2 workers) is **too small** for the full chart.
`flightctl-kv` requests 1 CPU / 2Gi and will stay Pending until workers have spare capacity.

**Required for this lab:** at least one worker with roughly `m6i.xlarge` headroom
(we scaled MachineSet `…-worker-us-east-2b` to 1× `m6i.xlarge` and set worker
MachineSets' `instanceType` to `m6i.xlarge` for future replacements).

After capacity is available, re-run `make install-rhem`.
