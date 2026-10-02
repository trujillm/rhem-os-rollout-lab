# EC2 device: bootc-image-builder → AMI → `run-instances`

How image **A** (`$OS_IMAGE_GOOD`, pushed in Task 6) becomes a bootable EC2 AMI in `us-east-2`,
and how the resulting instance becomes the lab's `os-rollout-test-01` device. Scripts:
[`scripts/15-build-ami.sh`](../../scripts/15-build-ami.sh) (this doc's §1–4) and
[`scripts/20-provision-ec2.sh`](../../scripts/20-provision-ec2.sh) (§5).

## 0. Why not just point AWS at the OCI image

AWS has no "run this bootc container as an instance" primitive. `bootc-image-builder` ("bib")
converts a bootc container image into a disk image (`raw`/`qcow2`/**`ami`**/...) with the
container's filesystem as the booted root — image A's content (flightctl-agent, greenboot,
masked `bootc-fetch-apply-updates.timer`) ships unchanged. For `--type ami`, bib also drives the
AWS side: uploads the raw disk to S3, calls `ec2 import-snapshot`, waits for the conversion task,
then `ec2 register-image`. One command, no manual snapshot/import steps.

## 1. Key finding: image A has no `cloud-init` — SSH access must be baked in at build time

Checked directly (`podman run --rm --platform linux/amd64 "$OS_IMAGE_GOOD" rpm -qa`):

```
sshd:              enabled
cloud-init:         NOT installed
ssh-key-dir:        NOT installed
present instead:    python3-cloud-what, cloud-utils-growpart, NetworkManager-cloud-setup
```

Normal EC2 AMIs rely on `cloud-init`'s `DataSourceEc2` to fetch the instance's key pair from
metadata and write `~/.ssh/authorized_keys` on first boot. **Image A doesn't have that service**,
so launching with `--key-name` alone would produce an instance nothing can SSH into — regardless
of which EC2 key pair is attached. `bootc-image-builder`'s `config.toml` solves this at the image
level instead:

```toml
[[customizations.user]]
name = "ec2-user"
groups = ["wheel"]
key = "<contents of ~/.ssh/rhem-os-rollout-lab.pub>"
password = "<random, generated once, stored only in local config/env>"
```

This creates `ec2-user` with the SSH key baked directly into the disk image, so first boot is
already reachable. We still create/attach the AWS key pair `rhem-os-rollout-lab` too (console
hygiene, matches `DEVICE_SSH=ec2-user@…` convention already in `config/env.example`) — the
**public half of that same key pair** is what goes into `config.toml`, so both mechanisms point
at one keypair, not two unrelated ones.

The baked `password` exists only because `%wheel ALL=(ALL) ALL` in this image requires a password
for `sudo` (confirmed: no `NOPASSWD` entry) and bib's `config.toml` schema has no generic
"write arbitrary file" customization to drop a `sudoers.d` override. `scripts/20-provision-ec2.sh`
pipes the password to `sudo -S` over stdin (never as a CLI arg) when it runs `sudo bootc status`.

## 2. AWS-side prerequisites

| Requirement | This account (shared Red Hat sandbox, `us-east-2`) | Notes |
|---|---|---|
| `vmimport` IAM role (trust: `vmie.amazonaws.com`, external ID `vmimport`) | **Exists already** — shared across several teams' bootc/AMI pipelines in this account | `scripts/15-build-ami.sh` adds one more narrowly-scoped inline policy (`s3:Get*/List/PutObject` on our bucket only + the account-wide `ec2:RegisterImage`/`CopySnapshot`/`Describe*` the existing policies all already grant), following the same per-owner naming pattern already in use (`rhkp-…`, `vmimport-rhelai-s3`, …) — it does not touch anyone else's statement. |
| S3 staging bucket, same region as the AMI | Created if missing: `matrujil-rhem-os-rollout-bib-<account-id>` (account ID resolved at runtime via `aws sts get-caller-identity`, never hardcoded) | Must be in `us-east-2` — bib uploads the raw disk here before `import-snapshot`. 7-day expiry lifecycle rule applied. |
| AWS credentials | **Static access key/secret only.** The AWS Go SDK v2 (what bib's AWS uploader uses) silently ignores SSO/web-login session credentials — `aws sts get-caller-identity` succeeding is not sufficient; confirm `~/.aws/credentials` (or `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`) holds real static keys for the profile bib runs with. |
| `registry.redhat.io` pull auth | Present in this laptop's `podman login` auth file already (confirmed) | Needed to pull **bib's own container image** (`registry.redhat.io/rhel10/bootc-image-builder:latest`), matched to image A's RHEL 10 base per Red Hat's documented pairing. |
| `quay.io` pull auth for `$OS_IMAGE_GOOD` | Also present in the same auth file | **Correction from an earlier draft of this doc:** `quay.io/matrujil/rhem-os-rollout-lab` is **not** public. An unauthenticated `skopeo inspect --no-creds` against it returns `unauthorized`; the earlier "verified anonymous" claim was actually exercising this laptop's cached `quay.io` login without noticing. The in-cluster build (§3) explicitly mounts an authfile with both registries' credentials for exactly this reason. |

If `registry.redhat.io/rhel10/bootc-image-builder` is unreachable/unauthorized, the public
upstream `quay.io/centos-bootc/bootc-image-builder:latest` is API-compatible and works against a
RHEL bootc source image too (just unofficial for RHEL per Red Hat's docs) — `BIB_IMAGE` env var
overrides the default if you need this fallback.

## 3. Where bib actually runs

`bib` needs `--privileged` plus real loop-device/partitioning syscalls (losetup, mkfs, bootloader
install) — not just a container build.

**Preferred — privileged pod on the OpenShift hub (`BUILD_MODE=cluster`, the default, and what
actually built the AMI below):** the hub's nodes are already-entitled **x86_64** RHCOS (same arch
as image A — no cross-arch disk tooling needed). `scripts/15-build-ami.sh` creates an ephemeral
namespace `os-rollout-bib` and a pod with:

1. **`securityContext.seLinuxOptions.type: spc_t`** (pod *and* container level), not just
   `privileged: true`. Without it bib's entrypoint fails immediately: `chcon: failed to change
   context of '/store' to 'system_u:object_r:root_t:s0': Operation not supported` — plain
   `privileged: true` gets CRI-O's default confined SELinux type, which can't relabel its own
   working directory. `spc_t` is the standard "superprivileged container" label OpenShift uses for
   this class of workload.
2. **A real `emptyDir` mounted at `/store`** (bib's `--store`, default `/store`). Even with
   `spc_t`, the container's own overlay rootfs still can't be relabeled per-path (same `chcon`
   error) — overlay mounts a single fixed SELinux context for everything under it. A separate
   `emptyDir` volume is backed by a normal node-disk directory, which supports arbitrary
   `security.selinux` xattrs.
3. **A real `emptyDir` mounted at `/var/lib/containers/storage`**, pre-populated by an **init
   container** running `podman --root /var/lib/containers/storage pull --authfile=... "$OS_IMAGE_GOOD"`.
   Current bib versions **do not pull images themselves** — `cannot build manifest: failed to
   inspect the image: ... image not known / bootc-image-builder no longer pulls images, make sure
   to pull it before running` — so whatever path backs `/var/lib/containers/storage` must already
   contain the image before the main container starts, in the exact `containers/storage` layout
   (`mkdir -p .../overlay` isn't enough on its own; it has to be a real `podman pull`).
4. **An authfile `Secret`** (this laptop's `~/.config/containers/auth.json`, holding both
   `registry.redhat.io` and `quay.io` credentials) mounted into the init container for that pull,
   **and** a separate `kubernetes.io/dockerconfigjson` copy linked to the namespace's `default` SA
   (`oc secrets link ... --for=pull`) so the **kubelet** can pull bib's own pod image
   (`registry.redhat.io/rhel10/bootc-image-builder:latest`) — two different consumers of the same
   credentials, at two different layers (kubelet image pull vs. in-container `podman pull`).
5. **An AWS credentials *file*** (`Secret` mounted at `/root/.aws/credentials`, profile
   `default`), not just `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` env vars. Env-vars-only
   produced `error: cannot handle AWS setup: failed to get shared config profile, default` — bib's
   AWS uploader explicitly loads a named shared-config profile, which requires an actual
   `~/.aws/credentials` file to exist (env vars alone, per the upstream README, are only
   officially supported without `--config`-driven consumers reading the profile this way; in
   practice the credentials-file form is what worked here).

The script waits for the pod to reach `Succeeded`/`Failed` (`oc wait`), tees `oc logs`, then
independently confirms the result via `aws ec2 describe-images --filters
Name=name,Values=<ami-name>` (not just trusting the build log) before deleting the namespace in an
`EXIT` trap.

**Fallback — local podman machine (`BUILD_MODE=local`), experimental:** this laptop's podman
machine (`applehv`) is **arm64** with no x86_64 hardware-virtualization path — there is no way to
run a "real" x86_64 VM on Apple Silicon the way the OpenShift path gets real x86_64 nodes. Local
mode either runs the `linux/amd64` bib container under QEMU user-mode emulation (`--platform
linux/amd64`, same trick Task 6 used for plain `dnf install`, unverified for bib's lower-level
loop/mkfs/bootloader operations) or uses bib's own `--target-arch amd64` cross-build flag, which
upstream marks **experimental**. Also: the podman machine has only 18 GB free disk at last check —
tight for a multi-GB raw disk image. Treat this path as a last resort if the cluster path is
blocked, not as equally viable.

## 4. `scripts/15-build-ami.sh`

```bash
export BUILD_MODE=cluster   # or: local (see §3)
./scripts/15-build-ami.sh
```

On success: prints `AMI_ID=ami-...`, writes it into local `config/env` (`update_env` in
`scripts/lib.sh`), and reminds you it's **not** committed — only `config/env.example`'s
`AMI_ID=REPLACE_ME` placeholder is.

## 5. `scripts/20-provision-ec2.sh`

```bash
./scripts/20-provision-ec2.sh
```

- Discovers (or creates) what `config/env` is missing: default VPC's default subnet in
  `us-east-2`, a security group `rhem-os-rollout-lab-ssh` (ingress `tcp/22` from your current
  public IP `/32`, ingress-free otherwise; egress `tcp/443` **and `tcp+udp/53`** — the brief asked
  for 443-only, but VPC DNS resolution is subject to security groups same as any other traffic, so
  without 53 the instance can't resolve any hostname before HTTPS even starts; noted here rather
  than silently diverging), and the `rhem-os-rollout-lab` EC2 key pair (private half written only
  to `~/.ssh/rhem-os-rollout-lab`, `chmod 600`, never under the repo).
- `aws ec2 run-instances`: `$AMI_ID`, `m6i.large`, that SG/subnet/key, tag `Name=os-rollout-test-01`.
- Waits for `instance-status-ok`, prints the public IP, updates `DEVICE_SSH` in `config/env`, and
  tells you to `source config/env` before `ssh "$DEVICE_SSH"`.
- Verifies `sudo bootc status` over SSH (password piped via stdin per §1) and prints the result —
  expected: a single booted deployment pointing at image A's digest.

## 6. Teardown

`config/recovery-runbook.md` §4 already covers `terminate-instances` + relaunch from
`$AMI_ID`. The S3 staging bucket and `vmimport` inline policy are small/inert enough to leave in
place for the next AMI build in this lab; delete manually (`aws s3 rb --force`,
`aws iam delete-role-policy`) only if decommissioning the whole lab.
