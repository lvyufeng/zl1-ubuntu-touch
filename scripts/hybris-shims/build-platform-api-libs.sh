#!/usr/bin/env bash
# Build libubuntu_application_api.so and libbiometry_fp_api.so out of the Halium 9 tree.
#
# Why these two: they are the Android-side halves of the libhybris bridge for GPS and
# fingerprint. The host libraries (libubuntu_platform_hardware_api.so and libbiometry.so)
# call android_dlopen("libubuntu_application_api.so") / android_dlopen("libbiometry_fp_api.so")
# and then android_dlsym("u_...") on the result -- and libhybris' bridge does not NULL-check
# the pointer it has just resolved, so a missing library is a `br x16` onto NULL, i.e.
# `pc=0x0` (docs 50). `lomiri-location-service` and `biometryd` were dying exactly that way
# and the reason turned out to be blunter than "a symbol is missing": a full `find / -xdev`
# plus /android /vendor /system finds neither library anywhere on the device (docs 53).
#
# The sources have been in this tree all along. Unlike the graphics stack (docs 42/43), where
# something had to be written, here nothing has to be: both Android.mk files are complete,
# already branched for Android 9, and -- this is the part that was not obvious --
# *already in the build graph*:
#
#     $ grep -n 'platform-api\|biometryd' out/.module_paths/Android.mk.list
#     233:halium/biometryd/android/hybris/Android.mk
#     242:halium/platform-api/android/hybris/Android.mk
#
# so `m libubuntu_application_api` was always a valid request; nothing in
# device/leeco/zl1/ ever named either module in PRODUCT_PACKAGES, and nothing else depended
# on them, so ninja never had a reason to build them. "Never wired into the build" is
# precisely right, and the fix is one request, not one patch.
#
# Same three host prerequisites as build-hwc2-compat-layer.sh, and they fail in the same
# confusing ways, so they are checked here too:
#
#   * ImageMagick (`mogrify`) -- vendor/lineage/bootanimation/Android.mk calls $(error stop)
#     during product config without it, before anything about our modules is looked at.
#   * Python 2 for the Soong genrules -- external/clang/clang-version-inc.py and
#     bionic/libc/fs_config_generator.py still use Python 2 `print`. A shim directory
#     holding a `python` that is python2.7 is prepended to PATH for the build only.
#   * ALLOW_MISSING_DEPENDENCIES=true -- the lineage tree has unrelated modules whose
#     dependencies are not all present, and Kati aborts on those before ninja starts.
#
# Nothing here touches the phone.
#
# Usage: build-platform-api-libs.sh [tree-dir] [lunch-target]

set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
TREE="${1:-/mnt/data/halium-zl1-build}"
LUNCH="${2:-}"

MODULES=(libubuntu_application_api libbiometry_fp_api)

[ -d "$TREE/build/make" ] || { echo "not an Android tree: $TREE" >&2; exit 1; }
[ -f "$TREE/halium/platform-api/android/hybris/Android.mk" ] ||
  { echo "$TREE has no halium/platform-api/android/hybris/Android.mk" >&2; exit 1; }
[ -f "$TREE/halium/biometryd/android/hybris/Android.mk" ] ||
  { echo "$TREE has no halium/biometryd/android/hybris/Android.mk" >&2; exit 1; }

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

echo "== building: ${MODULES[*]}"
(
  cd "$TREE"
  [ -z "$PYSHIM" ] || export PATH="$PYSHIM:$PATH"
  export ALLOW_MISSING_DEPENDENCIES=true
  # `set +u` is not optional here, and it is the whole reason this script exists in the shape
  # it does. envsetup.sh is not `set -u`-clean: to detect whether the shell's arrays are
  # zero- or one-based it evaluates
  #
  #     _xarray=(a b c)
  #     if [ -z "${_xarray[${#_xarray[@]}]}" ]
  #
  # i.e. it indexes one past the end on purpose. bash < 4.4 expanded that to the empty string;
  # bash >= 4.4 calls it an unbound variable and *aborts the source* under `set -u`. With
  # `set -e` above, the subshell then dies right there — after "== building:" and before a
  # single line of make output — so the script exits 1 having done nothing, and it reads as
  # "the build system rejected the module" rather than "the shell refused to read envsetup".
  # Observed on this host with bash 5.1.16.
  set +u
  source build/envsetup.sh >/dev/null 2>&1
  lunch "$LUNCH" >/dev/null 2>&1
  m -j"$(nproc)" "${MODULES[@]}"
) || { echo "build failed (see the make output above)" >&2; exit 1; }

# The GPS implementation is one of two files depending on BOARD_HAS_LEGACY_GPS_HAL, and the
# choice is silent at build time. Say which one went in, because it decides whether the
# resulting library talks to the HIDL gnss service or the old hardware/gnss.h shim, and that
# in turn decides whether anything the container registers can answer it.
OBJ="$TREE/out/target/product/zl1/obj/SHARED_LIBRARIES/libubuntu_application_api_intermediates"
if [ -f "$OBJ/ubuntu_application_gps_hidl_for_hybris.o" ]; then
  echo "== GPS backend: HIDL (ubuntu_application_gps_hidl_for_hybris.cpp)"
elif [ -f "$OBJ/ubuntu_application_gps_for_hybris.o" ]; then
  echo "== GPS backend: legacy hardware/gnss.h shim (ubuntu_application_gps_for_hybris.cpp)"
else
  echo "== GPS backend: could not tell from obj/ — check the BLOB below by hand"
fi

mkdir -p "$here/out"
rc=0
for m in "${MODULES[@]}"; do
  # lib64 explicitly. The product out holds two copies — system/lib (arm) and system/lib64
  # (arm64) — and `find … -print -quit` happily returns the 32-bit one; both are the same file
  # name, both build fine, and the wrong one fails only later, at load, on a 64-bit device.
  src="$TREE/out/target/product/zl1/system/lib64/$m.so"
  if [ ! -f "$src" ]; then
    echo "$m.so: build reported success but $src is not there" >&2
    rc=1
    continue
  fi
  cp "$src" "$here/out/$m.so"
  echo "== $m.so  <- $src  ($(stat -c %s "$src") bytes)"
done
exit $rc
