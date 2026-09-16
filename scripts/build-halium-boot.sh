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
