#!/usr/bin/env bash
# Build libhwc2_compat_layer.so out of the Halium 9 tree with the Android build
# system, and put the arm64 result in out/ next to the other shims.
#
# This one cannot be compiled standalone the way libui_compat_layer.so is
# (build-hybris-shims.sh): it is a *client of the HIDL composer@2.1 service*, so
# it needs hidl-gen's output for android.hardware.graphics.composer@2.1 and the
# command-buffer header library. Producing those means running hidl-gen, which
# means running Soong, which means the real build.
#
# Three host-side prerequisites bit us on the way here and are checked below:
#
#   * ImageMagick (`mogrify`) -- vendor/lineage/bootanimation/Android.mk calls
#     $(error stop) during product config without it. That failure happens
#     *before* anything about our module is looked at, so it reads as a broken
#     tree rather than a missing host package.
#   * Python 2 for the Soong genrules -- external/clang/clang-version-inc.py and
#     bionic/libc/fs_config_generator.py both still use Python 2 `print`. With
#     python3 they fail with a SyntaxError inside the sandbox, which again looks
#     like a source problem. A shim directory holding a `python` that is
#     python2.7 is prepended to PATH for the build only.
#   * ALLOW_MISSING_DEPENDENCIES=true -- the lineage tree has unrelated modules
#     (update_engine's unit tests, the CodeAurora IMS java library) whose
#     dependencies are not all present. Kati aborts on those before ninja ever
#     starts. We only want one module; the flag defers their errors to a point
#     they never reach.
#
# Nothing here touches the phone.
#
# Usage: build-hwc2-compat-layer.sh [tree-dir] [lunch-target]

set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
TREE="${1:-/mnt/data/halium-zl1-build}"
LUNCH="${2:-}"

[ -d "$TREE/build/make" ] || { echo "not an Android tree: $TREE" >&2; exit 1; }
[ -d "$TREE/halium/libhybris/compat/hwc2" ] || { echo "$TREE has no halium/libhybris/compat/hwc2" >&2; exit 1; }

command -v mogrify >/dev/null || {
  echo "ImageMagick is missing (vendor/lineage/bootanimation needs mogrify)." >&2
  echo "install it with: sudo apt-get install -y imagemagick" >&2
  exit 1
}

if [ -z "$LUNCH" ]; then
  LUNCH="$(sed -n 's/^PREVIOUS_BUILD_CONFIG := //p' \
            "$TREE/out/target/product/zl1/previous_build_config.mk" 2>/dev/null)"
  [ -n "$LUNCH" ] || LUNCH=lineage_zl1-userdebug
fi
echo "== lunch: $LUNCH"

PYSHIM=""
if ! python --version 2>&1 | grep -q '^Python 2'; then
  command -v python2.7 >/dev/null || {
    echo "python2.7 is missing; the Soong genrules in this tree are Python 2." >&2
    echo "install it with: sudo apt-get install -y python2.7 python2" >&2
    exit 1
  }
  PYSHIM="$(mktemp -d)"
  ln -sf "$(command -v python2.7)" "$PYSHIM/python"
  echo "== python shim: $PYSHIM/python -> $(command -v python2.7)"
fi
trap '[ -n "$PYSHIM" ] && rm -rf "$PYSHIM"' EXIT

echo "== building (this also builds the host toolchain the tree has not built yet)"
# shellcheck disable=SC1091
(
  cd "$TREE"
  [ -z "$PYSHIM" ] || export PATH="$PYSHIM:$PATH"
  export ALLOW_MISSING_DEPENDENCIES=true
  source build/envsetup.sh >/dev/null 2>&1
  lunch "$LUNCH" >/dev/null 2>&1
  m -j"$(nproc)" libhwc2_compat_layer
)

SRC="$TREE/out/target/product/zl1/system/lib64/libhwc2_compat_layer.so"
[ -f "$SRC" ] || { echo "build reported success but $SRC is not there" >&2; exit 1; }
mkdir -p "$here/out"
cp "$SRC" "$here/out/libhwc2_compat_layer.so"

# --- shape check ----------------------------------------------------------
# A .so that loads is not the same as a .so whose ABI the host expects: libhwc2.so.1
# resolves these by dlsym and does not check for NULL, so a missing symbol is a
# jump to address 0 at first use, not a load error.
lib="$here/out/libhwc2_compat_layer.so"
readelf -dW "$lib" | grep -q 'SONAME.*\[libhwc2_compat_layer\.so\]' ||
  { echo "missing SONAME libhwc2_compat_layer.so" >&2; exit 1; }

hostlib=""
for c in "$here/../../tmp-hybris-hang/sysroot/usr/lib/aarch64-linux-gnu/libhwc2.so.1.0.0" \
         /usr/lib/aarch64-linux-gnu/libhwc2.so.1; do
  [ -f "$c" ] && { hostlib="$c"; break; }
done
if [ -n "$hostlib" ]; then
  echo "== checking our exports against what $hostlib looks up"
  missing=$(comm -23 \
    <(strings -a "$hostlib" | grep -E '^hwc2_compat_' | sort -u) \
    <(readelf --dyn-syms -W "$lib" | awk '$7!="UND"{print $8}' | grep -E '^hwc2_compat_' | sort -u))
  if [ -n "$missing" ]; then
    echo "the host's libhwc2.so.1 dlsyms symbols this build does not export:" >&2
    echo "$missing" | sed 's/^/  /' >&2
    echo "it does not NULL-check those, so expect a jump to 0 at first use." >&2
  fi
fi

echo "== exports: $(readelf --dyn-syms -W "$lib" | awk '$7!="UND"{print $8}' | grep -cE '^hwc2_compat_') hwc2_compat_* symbols"
sha256sum "$lib"
