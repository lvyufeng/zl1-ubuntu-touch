#!/usr/bin/env bash
# Build one of the Halium `<name>_compat_layer.so` libraries out of the Android tree.
#
# Why these exist as a family: a Halium host stack does not link its Android side, it reaches it
# at runtime. For graphics that is `libui_compat_layer.so` (Mir's EGL/GLES platform) and
# `libhwc2_compat_layer.so` (a client of the HIDL `composer@2.1` service); for the camera it is
# `libcamera_compat_layer.so`, which wraps Android's `libcamera_client`. None of them are in the
# stock LeEco Android image -- they are built by the device's *Halium* build and the vendor image
# predates it. Every one of them fails the same way when absent:
#
#     library "libcamera_compat_layer.so" not found
#
# and every one of them has to be built by the real Android build rather than compiled standalone,
# because they need generated headers (`hidl-gen` output for hwc2) or Android-internal headers and
# a matching `libcamera_client` (camera). Docs 42/43 did this for the two graphics layers; this
# script is that script generalised, so the camera one is one command.
#
# The module table is the whole configuration:
#
#   module                   tree source                          exported prefix
#   libui_compat_layer       halium/libhybris/compat/ui           ui_compat_ / ui_holo*
#   libhwc2_compat_layer     halium/libhybris/compat/hwc2         hwc2_compat_
#   libcamera_compat_layer   halium/libhybris/compat/camera       android_camera_
#   libis_compat_layer       halium/libhybris/compat/input        android_input_
#
# libis_compat_layer is the odd one out in that nothing on this device links it directly: the
# camera needs it because the *host's* libis.so.1 (the input-system half of libhybris) dlopens it
# by name at runtime, and libcamera.so.1 pulls libis.so.1 in. It shows up as the camera's next
# failure after the whole Android side is working -- the connect succeeds, the HAL opens, and then:
#
#     library "libis_compat_layer.so" not found
#
# with the paths the trace shows being hybris' own search order (HYBRIS_LD_LIBRARY_PATH, then the
# Android ones), which is what makes it that dlopen rather than a link-time dependency.
#
# Three host-side prerequisites, all discovered the hard way and all of the "reads like a broken
# tree rather than a missing host package" kind:
#
#   * ImageMagick (`mogrify`) -- vendor/lineage/bootanimation/Android.mk calls $(error stop)
#     during product config without it, before anything about our module is looked at.
#   * Python 2 for the Soong genrules -- external/clang/clang-version-inc.py and
#     bionic/libc/fs_config_generator.py still use Python 2 `print`; with python3 they fail with a
#     SyntaxError inside the sandbox. A shim directory holding a `python` that is python2.7 is
#     prepended to PATH for the build only.
#   * ALLOW_MISSING_DEPENDENCIES=true -- unrelated modules in the lineage tree (update_engine's
#     unit tests, the CodeAurora IMS java library) have dependencies that are not all present, and
#     Kati aborts on those before ninja starts.
#
# Nothing here touches the phone. The arm64 result lands in `out/` next to the other shims.
#
# Usage: build-compat-layer.sh <module|all> [tree-dir] [lunch-target]
#
# Examples:
#   build-compat-layer.sh libcamera_compat_layer
#   build-compat-layer.sh all

set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

MODULES_ALL="libui_compat_layer libhwc2_compat_layer libcamera_compat_layer libis_compat_layer"

# module -> "source-subdir symbol-prefix-regex"
module_src() {
  case "$1" in
  libui_compat_layer) echo "ui '^(ui_compat_|ui_holo)" ;;
  libhwc2_compat_layer) echo "hwc2 '^hwc2_compat_'" ;;
  libcamera_compat_layer) echo "camera '^android_camera_'" ;;
  libis_compat_layer) echo "input '^android_input_'" ;;
  *) return 1 ;;
  esac
}

what="${1:-}"
case "$what" in
"" | -h | --help)
  awk 'NR==1{next} /^#/{print; next} {exit}' "$0"
  exit 1
  ;;
all) WANT="$MODULES_ALL" ;;
*)
  module_src "$what" >/dev/null || { echo "unknown module: $what (known: $MODULES_ALL)" >&2; exit 1; }
  WANT="$what"
  ;;
esac
shift || true
TREE="${1:-/mnt/data/halium-zl1-build}"
LUNCH="${2:-}"

[ -d "$TREE/build/make" ] || { echo "not an Android tree: $TREE" >&2; exit 1; }
for m in $WANT; do
  d="$(module_src "$m")"
  d="${d%% *}"
  [ -d "$TREE/halium/libhybris/compat/$d" ] || { echo "$TREE has no halium/libhybris/compat/$d" >&2; exit 1; }
done

command -v mogrify >/dev/null || {
  echo "ImageMagick is missing (vendor/lineage/bootanimation needs mogrify)." >&2
  echo "install it with: sudo apt-get install -y imagemagick" >&2
  exit 1
}

# --- tree patches -------------------------------------------------------------
# Small, idempotent, and each one recorded next to its reason.
#
# libcamera_compat_layer: its Android.mk decides whether to build 32-bit-only by reading
# `frameworks/av/media/libmediaplayerservice` -- a check copied from the *media* compat layer,
# where the media players really are 32-bit-only. It has nothing to do with the camera, and it
# makes this module `LOCAL_32_BIT_ONLY := true`, which on this port is exactly backwards:
# `libaalcamera.so` and `test_camera` are aarch64, so a 32-bit-only build is a library the host
# cannot load. The failure is quiet -- the build succeeds, `out/.../system/lib/libcamera_compat_layer.so`
# appears, `out/.../system/lib64/` stays empty, and the only symptom is the missing .so at dlopen
# time on the device. The whole two-`ifeq` construct is guarded by one variable, so neutralising
# the variable (a later `:=` wins, and neither `ifeq` uses `override`) is enough.
patch_tree() {
  case "$1" in
  libcamera_compat_layer)
    mk="$TREE/halium/libhybris/compat/camera/Android.mk"
    grep -q '^HYBRIS_MEDIA_32_BIT_ONLY := false' "$mk" && { echo "== tree patch: already applied"; return 0; }
    cp -a "$mk" "$mk.zl1-orig"
    # The neutralising line goes right after the `endif` that closes the variable's own
    # computation, so both of the `ifeq (...,true)` blocks further down take the false branch.
    awk '
      /^HYBRIS_MEDIA_32_BIT_ONLY := \$\(shell cat/ { seen = 1 }
      { print }
      seen && /^endif$/ && !done {
        print "HYBRIS_MEDIA_32_BIT_ONLY := false"
        print "# zl1: ^ forced above; see build-compat-layer.sh -- the 32-bit-only rule below is"
        print "# inherited from frameworks/av/media/libmediaplayerservice and is wrong for the camera."
        done = 1
      }
    ' "$mk.zl1-orig" > "$mk"
    echo "== tree patch: $mk (32-bit-only rule neutralised; original at $mk.zl1-orig)"
    ;;
  libis_compat_layer)
    mk="$TREE/halium/libhybris/compat/input/Android.mk"
    cpp="$TREE/halium/libhybris/compat/input/input_compatibility_layer.cpp"
    # Two separate patches, applied independently -- an earlier version of this had them behind one
    # combined guard, which meant that once the Android.mk half was in place the source half could
    # never be applied at all. Each keeps its own pristine copy and will not overwrite one.
    #
    # libskia is a *static* module in this tree -- AOSP 9 ships Skia that way, which is why the
    # device has libhwui.so and no libskia.so anywhere (checked: /system/lib64, /system/lib,
    # /vendor/lib64 -- none). The input compat layer lists it in LOCAL_SHARED_LIBRARIES, which makes
    # Make look for SHARED_LIBRARIES/libskia_intermediates/export_includes; nothing ever generates
    # that path, and ninja stops with
    #   '.../obj/SHARED_LIBRARIES/libskia_intermediates/export_includes', needed by
    #   '.../libis_compat_layer_intermediates/import_includes', missing and no known rule to make it
    # It is not a missing host package and not a stale tree: the module is simply mis-declared, and
    # it is the only file in the tree that references Skia this way (the other three compat layers
    # and every platform module take it statically). Moving it to LOCAL_STATIC_LIBRARIES is the same
    # thing libinputservice does, and it is what has to happen for the result to load at all: a
    # DT_NEEDED on libskia.so would fail on the device, where that file does not exist.
    #
    # Static linking brings its own cost: Make inherits neither the dynamic nor the static
    # dependencies of a library it is handed as a .a, so both have to be spelled out from what
    # external/skia/Android.bp's `skia_deps` declares. Without the shared ones the link stops on
    # FreeType; without the static ones it stops on WebP:
    #   libskia.a(SkFontHost_FreeType.o): error: undefined reference to FT_Library_SetLcdFilter
    #   libskia.a(SkWebpCodec.o): error: undefined reference to WebPIDecode
    # The shared ones are all on the device already -- they are exactly what libhwui.so is built
    # from, and libhwui.so is what the device libinputservice.so links for its own copy of Skia.
    #
    # The second half of the Android.mk patch is the same shape of mistake one level up: the module
    # forces `-std=gnu++0x`, and LOCAL_CFLAGS comes after the platform's cflags, so it silently
    # downgrades the whole translation unit from the tree's -std=gnu++14 to C++11. The generated HIDL
    # headers that arrive through libgui -> ui/GraphicTypes.h -> android.hardware.graphics.common@1.0
    # use constexpr functions the standard only allows from C++14 on, and the module is -Werror, so
    # the build stops inside a header nobody here wrote:
    #   .../common/1.0/types.h:1404: error: use of this statement in a constexpr function is a
    #   C++14 extension [-Werror,-Wc++14-extensions]
    # Dropping the override lets the platform default stand. It is the only thing the module wanted
    # from C++11, and gnu++14 is a superset.
    #
    # The third is the -Wno-unused family: this layer implements InputReaderPolicyInterface and is
    # meant to ignore most of it (getKeyboardLayoutOverlay(), getDeviceAlias() and
    # getTouchAffineTransformation() all return a default on purpose), and it carries a little dead
    # code -- a verbosity flag and two display ids nothing reads. The module also adds -Wall -Werror
    # *after* the platform's own -Wno-unused, which re-enables every one of those diagnostics.
    #
    # The fourth is libheif, and it is the one that crashed rather than failed. libskia's HEIF codec
    # object is in the archive and has exactly one dependency outside skia and libc++ --
    # createHeifDecoder(), which libheif.so provides:
    #   external/skia/src/codec/SkHeifCodec.cpp:123: error: undefined reference to
    #   'createHeifDecoder()'
    # Linking libheif does produce a .so, and that .so was the one deployed first. But a DT_NEEDED
    # is transitive and libheif.so's chain on this image is
    #   libis_compat_layer.so -> libheif.so -> libmedia.so -> libavenhancements.so
    # where libavenhancements.so is a vendor prebuilt that imports android::AVFactory::
    # createMediaFilter, which nothing on the device provides:
    #   cannot locate symbol "_ZN7android9AVFactory17createMediaFilterEv" referenced by
    #   "/android/system/lib64/libavenhancements.so"
    # hybris does not NULL-check a failed dlopen, so that gap was a SIGSEGV with an empty stdout
    # (test_camera exit 139) rather than a message. compat-layer-src/zl1-no-libheif.cpp supplies the
    # single symbol instead, returning null -- a case SkHeifCodec::MakeFromStream() checks for
    # explicitly (SkHeifCodec.cpp:124-127) -- so this module needs neither libheif nor the audio
    # stack behind it. The source file is copied into the module directory here, which is why this
    # happens outside the guard below: a missing copy is not a patch that can be skipped.
    #
    # The fifth is libinputservice, and it is the paragraph above being right for the wrong reason.
    # Dropping libheif from LOCAL_SHARED_LIBRARIES does not get libheif out of the process, and the
    # run that followed that rebuild proved it: libheif.so was still opened, by libhwui.so, which is
    # a dependency of libinputservice.so, which is a dependency of this module --
    #
    #   libis_compat_layer.so -> libinputservice.so -> libhwui.so -> libheif.so -> libmedia.so
    #                                                               -> libavenhancements.so
    #
    # -- and libavenhancements.so has the unresolvable import, so the crash came back unchanged.
    # (Measured, not inferred: `strace -f -e trace=openat` on the device names those files in that
    # order, and of this module's shared libraries only libinputservice.so lists libhwui.so at all.)
    #
    # libinputservice is two sources in this tree -- frameworks/base/libs/input/PointerController.cpp
    # and SpriteController.cpp, the mouse pointer and the touch-visualization spots -- and Soong
    # links them against libhwui because that is where Skia lives on an Android system. This module
    # already carries Skia statically (see above) and wants nothing else from that library, so its
    # two sources are compiled in here and the dependency is dropped rather than worked around. Both
    # are copied into the module directory, which is why this happens outside the guard below.
    cp -a "$here/compat-layer-src/zl1-no-libheif.cpp" "$TREE/halium/libhybris/compat/input/"
    cp -a "$TREE/frameworks/base/libs/input/PointerController.cpp" \
          "$TREE/frameworks/base/libs/input/SpriteController.cpp" \
          "$TREE/halium/libhybris/compat/input/"
    if grep -q '^LOCAL_STATIC_LIBRARIES += libskia libarect' "$mk" &&
       grep -q '^LOCAL_SHARED_LIBRARIES += libft2 libexpat' "$mk" &&
       grep -q '^LOCAL_SRC_FILES += zl1-no-libheif.cpp' "$mk" &&
       grep -q '^# zl1: LOCAL_CFLAGS += -std=gnu++0x removed' "$mk" &&
       grep -q '^LOCAL_CFLAGS += -Wno-unused-parameter' "$mk"; then
      echo "== tree patch: $mk already applied"
    else
      [ -f "$mk.zl1-orig" ] || cp -a "$mk" "$mk.zl1-orig"
      awk '
        $0 == "LOCAL_CFLAGS += -std=gnu++0x" {
          print "# zl1: LOCAL_CFLAGS += -std=gnu++0x removed; see build-compat-layer.sh"
          next
        }
        /^\tlibskia \\$/ { next }
        /^include \$\(BUILD_SHARED_LIBRARY\)$/ || /^include \$\(BUILD_EXECUTABLE\)$/ {
          print "LOCAL_SRC_FILES += zl1-no-libheif.cpp"
          print "# zl1: ^ supplies createHeifDecoder(), the one symbol the libskia HEIF codec needs"
          print "# the only reason this module would otherwise link libheif.so -- whose DT_NEEDED chain"
          print "# on this image reaches libmedia -> libavenhancements, and the vendor"
          print "# libavenhancements imports a symbol nothing here provides. See build-compat-layer.sh"
          print "# and the header comment in that source file."
          print "LOCAL_STATIC_LIBRARIES += libskia libarect libsfntly libwebp-decode libwebp-encode"
          print "LOCAL_GROUP_STATIC_LIBRARIES := true"
          print "# zl1: ^ libskia plus the four archives Soong links into it (external/skia/Android.bp"
          print "# skia_deps: libarect libsfntly libwebp-decode libwebp-encode), grouped because Make"
          print "# does not inherit a static library own static dependencies any more than the shared"
          print "# ones; see build-compat-layer.sh."
          print "# zl1: ^ moved out of LOCAL_SHARED_LIBRARIES; see build-compat-layer.sh -- libskia"
          print "# is static in this tree and there is no libskia.so on the device."
          print "# zl1: a static library does not carry its own dynamic dependencies in Make, so the"
          print "# ones the Soong module declares are repeated here; see build-compat-layer.sh. All of"
          print "# them are on the device already (they are what libhwui.so is built from)."
          print "LOCAL_SHARED_LIBRARIES += libft2 libexpat liblog libpng libjpeg libz \\"
          print "\tlibnativewindow libicui18n libicuuc libpiex libdng_sdk libEGL libGLESv2 libvulkan"
          print "LOCAL_CFLAGS += -Wno-unused-parameter -Wno-unused-variable -Wno-unused-const-variable"
          print "# zl1: ^ this layer implements an interface (InputReaderPolicyInterface) and is meant"
          print "# to ignore most of it, and it carries a little dead code from when it was written (a"
          print "# verbose flag and two display ids nothing reads). The module also adds -Wall -Werror"
          print "# *after* the platform -Wno-unused, which re-enables all of that. See"
          print "# build-compat-layer.sh."
        }
        { print }
      ' "$mk.zl1-orig" > "$mk"
      echo "== tree patch: $mk (libskia moved to LOCAL_STATIC_LIBRARIES; original at $mk.zl1-orig)"
    fi

    # Its own guard, for the reason given above: the two patches have nothing to do with each other
    # and a tree that already has one of them must still be able to receive the other. This one
    # rewrites the line the module uses to take libinputservice, and it reads and writes $mk in
    # place -- the pristine copy it would otherwise need is the same one the patch above saved.
    # It drops its own previous output first, so a tree that has an earlier version of this patch
    # (this one was written twice: the first cut linked the sprite controllers in, which needs libui
    # as well, and the link stopped on two symbols the second time) still converges on the current
    # one. The guard names both halves so that a half-applied tree is not mistaken for a done one.
    if grep -q '^LOCAL_SRC_FILES += SpriteController.cpp' "$mk" &&
       grep -q '^LOCAL_SHARED_LIBRARIES += libui$' "$mk"; then
      echo "== tree patch: $mk (libinputservice) already applied"
    else
      awk '
        /^# zl1: libinputservice is deliberately not linked\./ { drop = 1; next }
        drop { if ($0 ~ /SpriteController\.cpp$/) drop = 0; next }
        /^LOCAL_SHARED_LIBRARIES \+= libinputflinger( libinputservice)?$/ {
          print "LOCAL_SHARED_LIBRARIES += libinputflinger libui"
          print "# zl1: libinputservice is deliberately not linked. Its two sources are compiled"
          print "# into this module instead; see build-compat-layer.sh. It is the only reason this"
          print "# layer reached libhwui -> libheif -> libmedia -> libavenhancements, whose missing"
          print "# import is a SIGSEGV in any process that loads it. Upstream links it for Skia and"
          print "# for these two files; this module has Skia statically and needs nothing else."
          print "# libui is here for the same reason the controllers are: SpriteController draws with"
          print "# android::bytesPerPixel() and android::Region, and both live in libui.so. libui has"
          print "# no graphics stack behind it -- its own dependencies are the HIDL mapper/allocator"
          print "# and base libraries -- so it ends the chain rather than continuing it."
          print "LOCAL_SRC_FILES += \\"
          print "\tPointerController.cpp \\"
          print "\tSpriteController.cpp"
          next
        }
        { print }
      ' "$mk" > "$mk.zl1-new" && mv "$mk.zl1-new" "$mk"
      echo "== tree patch: $mk (libinputservice compiled in instead of linked)"
    fi

    # And the one API that the Halium 9.0 source has not caught up with. This is the source port
    # itself, and it is small: Android 8 replaced
    #     InputReaderConfiguration::setDisplayInfo(bool external, const DisplayViewport&)
    # with
    #     setPhysicalDisplayViewport(ViewportType, const DisplayViewport&)
    # and the halium-9.0 branch of libhybris still calls the old one -- which is the honest
    # explanation of why nobody had built this module before: it does not compile against a
    # Pie-class inputflinger at all, because the Android input stack is not what a Halium 9 port
    # uses for input (repowerd is). Everything else in the file lines up with Pie, including
    # getReaderConfiguration/obtainPointerController/getKeyboardLayoutOverlay.
    if grep -q 'setPhysicalDisplayViewport' "$cpp"; then
      echo "== tree patch: $cpp already applied"
    else
      [ -f "$cpp.zl1-orig" ] || cp -a "$cpp" "$cpp.zl1-orig"
      awk '
      /^\t\tdefault_configuration\.setDisplayInfo\(/ {
        print "#if ANDROID_VERSION_MAJOR >= 8"
        print "\t\t/* zl1: Android 8 replaced InputReaderConfiguration::setDisplayInfo() with"
        print "\t\t * setPhysicalDisplayViewport(). See build-compat-layer.sh. */"
        print "\t\tdefault_configuration.setPhysicalDisplayViewport(android::ViewportType::VIEWPORT_INTERNAL, viewport);"
        print "#else"
        print $0
        in_old = 1
        next
      }
      in_old && /^\t\t\t\tviewport\);$/ {
        print $0
        print "#endif"
        in_old = 0
        next
      }
      { print }
      ' "$cpp.zl1-orig" > "$cpp"
      echo "== tree patch: $cpp (setDisplayInfo -> setPhysicalDisplayViewport; original at $cpp.zl1-orig)"
    fi
    ;;
  esac
}

# Modules that have to be built before the compat layer itself, because the compat layer links them
# and this tree has never built them. Empty for the graphics layers -- their dependencies are all
# part of a normal build -- but libskia is here because nothing else in this port pulls Skia in.
module_prereqs() {
  case "$1" in
  libis_compat_layer) echo "libskia" ;;
  *) echo "" ;;
  esac
}
for m in $WANT; do patch_tree "$m"; done

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

echo "== building: $WANT (this also builds the host toolchain if the tree has not built it yet)"
# shellcheck disable=SC1091
(
  cd "$TREE"
  [ -z "$PYSHIM" ] || export PATH="$PYSHIM:$PATH"
  export ALLOW_MISSING_DEPENDENCIES=true
  # envsetup.sh indexes one past the end of an array on purpose, which bash >= 4.4 treats as an
  # unbound variable and aborts the source under `set -u` -- killing this subshell after
  # "== building" and before any make output. See build-platform-api-libs.sh.
  set +u
  source build/envsetup.sh >/dev/null 2>&1
  lunch "$LUNCH" >/dev/null 2>&1
  # shellcheck disable=SC2086
  # Prerequisites first and in their own invocation: a prerequisite that fails is a different
  # failure from the module that needs it, and the two want different messages.
  PREREQ=""
  for m in $WANT; do PREREQ="$PREREQ $(module_prereqs "$m")"; done
  if [ -n "${PREREQ// /}" ]; then
    echo "== prerequisites:$PREREQ"
    # shellcheck disable=SC2086
    m -j"$(nproc)" $PREREQ
  fi
  # shellcheck disable=SC2086
  m -j"$(nproc)" $WANT
) || { echo "build failed (see the make output above)" >&2; exit 1; }

mkdir -p "$here/out"
for m in $WANT; do
  SRC="$TREE/out/target/product/zl1/system/lib64/$m.so"
  [ -f "$SRC" ] || { echo "build reported success but $SRC is not there" >&2; exit 1; }
  cp "$SRC" "$here/out/$m.so"
  lib="$here/out/$m.so"

  # --- shape check ----------------------------------------------------------
  # A .so that loads is not a .so whose ABI the host expects. The host side resolves these names
  # with dlsym and -- for this whole family -- does NOT check for NULL, so a missing symbol is a
  # jump to address 0 at first use rather than a load error (docs 50).
  readelf -dW "$lib" | grep -q "SONAME.*\[$m\.so\]" ||
    { echo "missing SONAME $m.so" >&2; exit 1; }

  # The regex comes back from module_src() shell-quoted and awk is given the bare pattern; without
  # this the quotes are part of the regex and the check matches nothing and reports zero -- which is
  # exactly the reading that looks like a catastrophically wrong build rather than a broken check.
  src="$(module_src "$m")"; prefix="${src#* }"; prefix="${prefix//\'/}"
  readelf --dyn-syms -W "$lib" | awk -v p="$prefix" '$7!="UND" && $8 ~ p {print $8}' | sort -u \
    > "$here/out/$m.symbols.txt"
  echo "== $m: $(wc -l < "$here/out/$m.symbols.txt") exported symbols matching $prefix"
done

# The graphics layers have a copy of their host consumer on this machine, so the export list can be
# diffed against what the consumer actually dlsyms. There is no such copy for the camera -- its
# consumer is `libaalcamera.so` / `test_camera` on the device -- so for that one this is a report,
# not a verdict, and the device is where it gets checked.
for c in "$here/../../tmp-hybris-hang/sysroot/usr/lib/aarch64-linux-gnu/libhwc2.so.1.0.0" \
         /usr/lib/aarch64-linux-gnu/libhwc2.so.1; do
  [ -f "$c" ] && { hostlib="$c"; break; }
done
# The .symbols.txt is written only for the modules this run actually built, so the check needs both
# files: with the list missing, comm() compares the host's dlsym names against nothing and reports
# every one of them as a symbol this build failed to export.
if [ -n "${hostlib:-}" ] && [ -f "$here/out/libhwc2_compat_layer.so" ] &&
   [ -f "$here/out/libhwc2_compat_layer.symbols.txt" ]; then
  echo "== checking libhwc2_compat_layer against what $hostlib dlsyms"
  missing=$(comm -23 \
    <(strings -a "$hostlib" | grep -E '^hwc2_compat_' | sort -u) \
    <(cat "$here/out/libhwc2_compat_layer.symbols.txt"))
  if [ -n "$missing" ]; then
    echo "the host's libhwc2.so.1 dlsyms symbols this build does not export:" >&2
    echo "$missing" | sed 's/^/  /' >&2
    echo "it does not NULL-check those, so expect a jump to 0 at first use." >&2
  fi
fi

sha256sum "$here/out/"*.so 2>/dev/null
