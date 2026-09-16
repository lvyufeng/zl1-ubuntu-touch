# Build log index

Record each build attempt here. Store large logs outside this repo.

## Template

```text
Attempt: YYYY-MM-DD-N
Build tree: /mnt/data/halium-zl1-build
Manifest: manifests/halium-9-zl1.xml
Command:
  source build/envsetup.sh
  lunch lineage_zl1-userdebug
  mka halium-boot
Output:
  out/target/product/zl1/halium-boot.img
SHA256:
Result:
Notes:
```

## Source commit capture

After sync, capture key revisions:

```bash
repo forall device/leeco/zl1 device/leeco/msm8996-common kernel/leeco/msm8996 vendor/leeco -c 'echo $REPO_PATH $(git rev-parse HEAD) $(git rev-parse --abbrev-ref HEAD)'
```

## Sync attempt: 2026-06-07

Build tree: `/mnt/data/halium-zl1-build`

Initial full `repo sync` failed on transient DNS/network errors resolving `android.googlesource.com` for a small set of AOSP projects. Retried the missing projects serially with `repo sync -j1 --fail-fast`, which completed successfully.

Key synced revisions:

| Path | Revision |
|---|---|
| `device/leeco/zl1` | `c430cb9` |
| `device/leeco/msm8996-common` | `9ff1910` |
| `kernel/leeco/msm8996` | `c2f6e859` |
| `vendor/leeco` | `084763d` |
| `halium/halium-boot` | `8656205` |
| `build/make` | `1bfc37a` |

Kernel config verification against `lineage_zl1_defconfig` passed with warnings only:

- `CONFIG_VETH` not set
- `CONFIG_MEMCG` not set
- `CONFIG_POSIX_MQUEUE` not set

AppArmor is enabled in the defconfig.

## Build issue: missing `tools/metalava/manual`

After adding the minimal `halium.mk`, lunch succeeded and Soong bootstrap started. The next failure was:

```text
build/make/core/droiddoc.mk:188: error: FindEmulator: find: `tools/metalava/manual`: No such file or directory
```

The Halium 9 manifest comments out `tools/metalava`, but the LineageOS 16 droiddoc rules still scan `tools/metalava/manual`. For boot-only `halium-boot` builds, `scripts/patch-halium9-build-tree.sh` now creates an empty `tools/metalava/manual` directory in the external build tree to avoid makefile parse failure.

## Build issue: ImageMagick / `mogrify` parse-time requirement

The next build failure was:

```text
vendor/lineage/bootanimation/Android.mk: ImageMagick is not installed
```

This happens while parsing makefiles because Lineage bootanimation generation checks `command -v mogrify`. For boot-only `halium-boot` builds, the bootanimation is irrelevant. `scripts/patch-halium9-build-tree.sh` now creates a no-op `mogrify` at `.halium-host-tools/mogrify`, and `scripts/build-halium-boot.sh` prepends that directory to `PATH`.

## Build issue: missing optional/test dependencies

After makefile parsing progressed further, ckati reported many missing modules from CTS, tests, docs, and optional framework components, ending with:

```text
build/make/core/main.mk:844: error: exiting from previous errors.
```

The errors themselves suggested `ALLOW_MISSING_DEPENDENCIES=true`. Since this rebuild is boot-only (`halium-boot`) and the missing modules are not expected to be part of the boot image, `scripts/build-halium-boot.sh` now exports:

```bash
ALLOW_MISSING_DEPENDENCIES=true
```

This should not be used as proof that a full Android/system image is buildable; it is only for producing the Halium boot image.

## Build issue: kernel `gcc-wrapper.py` requires Python 2

After allowing missing optional dependencies, the build reached the actual kernel compile stage and failed with:

```text
FAILED: TARGET_KERNEL_BINARIES
/usr/bin/env: ‘python2’: No such file or directory
make[2]: *** [.../kernel/leeco/msm8996/./Kbuild:36: kernel/bounds.s] Error 127
```

The kernel Makefile invokes `kernel/leeco/msm8996/scripts/gcc-wrapper.py` directly as part of `CC`, and that script was Python 2-only. A simple `python2 -> python3` symlink is not valid because the legacy script uses Python 2 syntax such as `print >> sys.stderr`.

For this external build tree only, `scripts/patch-halium9-build-tree.sh` now replaces `kernel/leeco/msm8996/scripts/gcc-wrapper.py` with a Python 3-compatible wrapper that preserves the original behavior: run the real compiler, mirror stderr, and fail on non-whitelisted compiler warnings.

## Build issue: host DTC link fails with duplicate `yylloc`

Once the Python wrapper was patched, the kernel build advanced to host tool compilation and failed linking the in-tree device tree compiler:

```text
HOSTLD  scripts/dtc/dtc
/usr/bin/ld: scripts/dtc/dtc-parser.tab.o:(.bss+0x50): multiple definition of `yylloc'; scripts/dtc/dtc-lexer.lex.o:(.bss+0x0): first defined here
collect2: error: ld returned 1 exit status
```

This is a common old-kernel vs modern-host issue: GCC 10+ defaults to `-fno-common`, exposing duplicate tentative definitions in old generated DTC sources. For the external build tree only, `scripts/patch-halium9-build-tree.sh` now appends `-fcommon` to the DTC host build flags in `kernel/leeco/msm8996/scripts/dtc/Makefile`, including the specific lexer/parser object flags (`HOSTCFLAGS_dtc-lexer.lex.o` and `HOSTCFLAGS_dtc-parser.tab.o`). The script also removes stale DTC host objects under `out/target/product/zl1/obj/KERNEL_OBJ/scripts/dtc` so they are rebuilt with the new flags. This only affects the host-built DTC utility, not target kernel flags or phone partitions.

## Successful build: 2026-06-07

Build tree: `/mnt/data/halium-zl1-build`

Command:

```bash
scripts/patch-halium9-build-tree.sh /mnt/data/halium-zl1-build
scripts/build-halium-boot.sh /mnt/data/halium-zl1-build
```

Result: `halium-boot` built successfully after the local host-build compatibility patches above.

Output artifact:

```text
Path:   /mnt/data/halium-zl1-build/out/target/product/zl1/halium-boot.img
Size:   25,264,128 bytes / 24.09 MiB
SHA256: 49113e509ab49a881894d04a13f70adb62a19d53f8bcd1e34e5cb04135da0aa4
```

The image fits the observed `boot` partition size (`67,108,864` bytes / 64 MiB).

Android boot image header summary:

```text
magic:        ANDROID!
page_size:    4096
kernel_size:  21150586
kernel_addr:  0x80008000
ramdisk_size: 4106247
ramdisk_addr: 0x81000000
second_size:  0
second_addr:  0x80f00000
tags_addr:    0x80000100
dt_size:      0
cmdline:      androidboot.hardware=qcom ehci-hcd.park=3 lpm_levels.sleep_disabled=1 cma=32M@0-0xffffffff androidboot.configfs=true apparmor=1 security=apparmor firmware_class.path=/vendor/firmware_mnt/image loop.max_part=7
```

Source revisions at build time:

| Path | Revision | Branch | Notes |
|---|---:|---|---|
| `build/make` | `1bfc37a3258f` | `HEAD` | clean |
| `device/leeco/msm8996-common` | `9ff19109679b` | `HEAD` | clean |
| `device/leeco/zl1` | `c430cb9be652` | `HEAD` | clean |
| `halium/halium-boot` | `8656205f5fe4` | `HEAD` | clean |
| `kernel/leeco/msm8996` | `c2f6e859f396` | `HEAD` | dirty due local host-build patches only |
| `vendor/leeco` | `084763d71bf6` | `HEAD` | clean |

Local build-tree patches applied by `scripts/patch-halium9-build-tree.sh`:

- Create minimal missing `build/target/product/halium.mk` for boot-only Halium target parsing.
- Create empty `tools/metalava/manual` to avoid LineageOS 16 droiddoc parse failure.
- Provide no-op `.halium-host-tools/mogrify` for boot-only builds without ImageMagick.
- Replace `kernel/leeco/msm8996/scripts/gcc-wrapper.py` with a Python 3-compatible wrapper.
- Append DTC host-build `-fcommon` compatibility lines to `kernel/leeco/msm8996/scripts/dtc/Makefile` and remove stale DTC host objects before rebuild.

No phone partitions were modified during this build.

## Boot image DTB fix: 2026-06-07

The first successful build produced an image that failed temporary boot with:

```text
Booting FAILED (remote: 'dtb not found')
```

Root cause: `lineage_zl1_defconfig` selected the X2 product variant instead of ZL1:

```text
CONFIG_PRODUCT_LE_X2=y
# CONFIG_PRODUCT_LE_ZL1 is not set
```

After selecting ZL1, a second image included 28 DTBs because `CONFIG_BUILD_ARM64_APPENDED_DTB_IMAGE_NAMES=""` caused the kernel Makefile to append every generated DTB, including stale X2 DTBs. That image dropped the phone into Qualcomm 9008/QDL and is not safe to retry.

The reproducible patch flow now forces:

```text
# CONFIG_PRODUCT_LE_X2 is not set
CONFIG_PRODUCT_LE_ZL1=y
CONFIG_BUILD_ARM64_APPENDED_DTB_IMAGE_NAMES="qcom/msm8996pro-pmi8996-le_zl1-dvt1 qcom/msm8996-v3-pmi8996-le_zl1-dvt1 qcom/msm8996pro-pmi8996-le_zl1-na qcom/msm8996-v3-pmi8996-le_zl1-evt qcom/msm8996pro-pmi8996-le_zl1-pvt"
```

The filtered candidate saved for testing is:

```text
Path:   /mnt/data/halium-zl1-candidates/halium-boot-zl1-filtered-dtb.img
Size:   17,997,824 bytes
SHA256: cd5cf3c1a715821eb6d63e390abcde4d64bb9f844c52c77ef055c2017fbab109
DTBs:   5
```

Fastboot accepted this image with `Booting OKAY`, but no ADB/fastboot/QDL/USB-network endpoint appeared during host polling. See `docs/ubuntu-touch/15-boot-diagnostics-2026-06-07.md`.
