#!/usr/bin/env bash
set -eo pipefail
# Android build/envsetup.sh is not nounset-safe; do not enable `set -u` here.

# Build Halium boot artifact. Does not touch the phone and contains no flash commands.

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /path/to/external-halium-build-tree" >&2
  exit 2
fi

BUILD_DIR=$(realpath -m "$1")
if [[ ! -f "$BUILD_DIR/build/envsetup.sh" ]]; then
  echo "Missing build/envsetup.sh in $BUILD_DIR" >&2
  exit 1
fi

cd "$BUILD_DIR"
export PATH="$BUILD_DIR/.halium-host-tools:$HOME/bin:$PATH"
export ALLOW_MISSING_DEPENDENCIES=true

# Reproducible version string.
#
# Without these the kernel's scripts/mkcompile_h stamps UTS_VERSION with the
# wall-clock time and a counter read from .version in the kernel object dir, so
# two builds of the same source differ by ~99 bytes out of 28 MB — enough to
# change the SHA256 and make "did this rebuild reproduce the known-good image?"
# unanswerable. Measured 2026-09-16: an unpinned rebuild differed from the
# 2026-06-07 image in exactly 5 clusters, all traceable to this string (the
# Linux version banner, the utsname copy, the embedded build-id note, and two
# spans inside a compressed blob downstream of those).
#
# The defaults below are the values the 2026-06-07 known-good build carried, so
# that a clean rebuild reproduces halium-boot.img SHA256 cd5cf3c1…fbab109
# byte-for-byte. Override them for a new baseline.
#
# Note: the kernel release also carries a `-dirty` suffix from
# scripts/setlocalversion because patch-halium9-build-tree.sh leaves three files
# modified in the kernel tree. A *clean* tree would produce a different release
# string, so keep the tree in the same dirty state when comparing builds.
export KBUILD_BUILD_VERSION="${KBUILD_BUILD_VERSION:-3}"
export KBUILD_BUILD_TIMESTAMP="${KBUILD_BUILD_TIMESTAMP:-Sun Jun 7 15:14:16 UTC 2026}"
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-lvyufeng}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-root}"

# shellcheck disable=SC1091
source build/envsetup.sh

if ! lunch lineage_zl1-userdebug; then
  echo "lunch lineage_zl1-userdebug failed" >&2
  exit 1
fi

if command -v mka >/dev/null 2>&1; then
  BUILD_CMD=(mka)
else
  BUILD_CMD=(make -j"${JOBS:-$(nproc)}")
fi

if ! "${BUILD_CMD[@]}" halium-boot; then
  echo "halium-boot target failed; trying hybris-boot" >&2
  "${BUILD_CMD[@]}" hybris-boot
fi

PRODUCT_OUT="$BUILD_DIR/out/target/product/zl1"
printf '\n== candidate boot artifacts ==\n'
find "$PRODUCT_OUT" -maxdepth 1 -type f \( -name 'halium-boot.img' -o -name 'hybris-boot.img' -o -name 'boot.img' \) -print -exec ls -lh {} \; -exec sha256sum {} \;
