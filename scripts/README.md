# scripts/ — zl1 Halium / Ubuntu Touch tooling

Every script here is written to be run from the host against the `zl1`
(LeEco Pro3, MSM8996). Scripts that write to the device are named `stage*`,
require an explicit `--yes`, verify image hashes before touching anything, and
refuse to run unless the target serial `33e80afe` is present — the unrelated
Xiaomi `4a2fe00b` shares the USB bus. Everything else is read-only. See
[`../docs/ubuntu-touch/00-safety.md`](../docs/ubuntu-touch/00-safety.md).

## Device inspection and backup

| Script | Purpose |
| --- | --- |
| `device-readonly-inventory.sh` | Read-only device inventory. No flashing, no `dd`, no block writes. |
| `backup-partitions-adb.sh` | Back up allowlisted partitions by streaming reads over `adb exec-out`. |
| `backup-partitions-adb-staged.sh` | Same, but stages each image in `/data/local/tmp` first. Works around Magisk/ADB stdout corruption seen when streaming large block devices directly. |
| `backup-partitions-twrp.sh` | Partition backup via TWRP instead of a booted Android. |
| `stage0-backup-userdata-cache.sh` | Stage 0. Images `userdata` (26.1 GB) in resumable 512 MiB chunks and cross-checks it against a device-side SHA256. Read-only. |

## Stage 2 — the only scripts that write to the device

| Script | Purpose |
| --- | --- |
| `stage2-flash-boot-and-verify.sh` | Flash the known-good v63 boot image with `fastboot flash boot`, then bring up host RNDIS and verify both device IPs plus the HTTP status server. Enforces the rollback and v63 image hashes first. |
| `stage2-rollback-boot.sh` | Put the original Android `boot.img` back. This is the undo for the script above. |
| `verify-device-online.sh` | Wait for the device gadget, set up host RNDIS, ping both device IPs and fetch the status page. Read-only; use it for cold-boot repeats 2 and 3. |

## Halium 9 build tree

| Script | Purpose |
| --- | --- |
| `setup-halium9-tree.sh` | Initialise the external Halium 9 build tree for zl1. |
| `sync-halium9-tree.sh` | Sync the external build tree. |
| `patch-halium9-build-tree.sh` | Reproducible local fixes needed by the historical `halium-leeco` zl1 tree. Touches only the external tree, never the phone. |
| `verify-halium-kernel-config.sh` | Check Halium-relevant kernel config options. Read-only. |
| `build-halium-boot.sh` | Build the Halium boot artifact. |
| `gen-candidate-manifest.sh` | Regenerate `../manifests/halium-boot-candidates.md` from `/mnt/data/halium-zl1-candidates/`. |
| `make-halium-diagnostic-boot-images.sh` | Build host-side diagnostic Android boot images from existing images. |
| `make-halium-nonblocking-usb-debug-boot.sh` | Diagnostic boot image that brings up initramfs USB RNDIS/telnet early but still continues the normal boot path. |
| `make-halium-postswitch-debug-boot.sh` | Diagnostic boot image that also installs `/tmp/zl1-debug-init` in the Ubuntu rootfs just before `switch_root`. |

## Ubuntu Touch rootfs and image staging

| Script | Purpose |
| --- | --- |
| `create-ubports-rootfs-img.sh` | Build a host-side `rootfs.img` from an official UBports system-image tarball. |
| `derive-halium-android-system-img.sh` | Derive the Halium Android `system.img` candidate from the trusted staged backup. Does not modify the original backup. |
| `stage-halium-userdata-images-adb.sh` | Push images to Android `/data` as regular files (`/data/rootfs.img`, `/data/system.img`). No block-device writes, no fastboot. |

## On-device runtime

| Script | Purpose |
| --- | --- |
| `fix-ssh-sshd-config.sh` | Edit `sshd_config` inside userdata. |
| `install-ssh-to-userdata.sh` | Install SSH keys into USERDATA. `/root` is bind-mounted from userdata at runtime, which is why keys must live there and not in the rootfs. |
| `zl1-status-server-enhanced.py` | HTTP status server with a command-execution endpoint; deployed into the ramdisk at `/usr/local/sbin/`. |

## boot-experiments/

The per-iteration `watch-and-boot` drivers used while hunting for a boot
configuration that survives on this device. Each one encodes the serial
(`33e80afe`) and an absolute image path, so they are a record of what was tried
rather than a general-purpose tool. Highest-numbered is newest:

- `v55` … `v60` — USB attribution / fakebind / packaging experiments
- `v61` … `v63` — post-init monitor and keeper variants; **v63 (`netd` disabled) is the configuration that gave stable RNDIS network access**
- `v64` … `v66` — attempts to make that configuration persistent in production
- `v67-quick-boot.sh` — quick `fastboot boot` of the v67 image
- `retest-v64.sh`, `test-v73.sh` — re-test drivers for the v64 and v73 images

Image build inputs live in untracked `tmp-v*/` directories at the repo root
(see the ignore rules in `../.gitignore`); the resulting `.img` files are not
tracked either.
