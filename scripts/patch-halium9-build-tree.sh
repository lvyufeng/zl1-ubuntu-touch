#!/usr/bin/env bash
set -euo pipefail

# Apply small, reproducible local fixes needed by the historical halium-leeco zl1 tree.
# This modifies only the external Android/Halium build tree, never the phone.

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /path/to/external-halium-build-tree" >&2
  exit 2
fi

BUILD_DIR=$(realpath -m "$1")
PRODUCT_DIR="$BUILD_DIR/build/target/product"
HALIUM_MK="$PRODUCT_DIR/halium.mk"

if [[ ! -d "$PRODUCT_DIR" ]]; then
  echo "Missing product directory: $PRODUCT_DIR" >&2
  exit 1
fi

if [[ -f "$HALIUM_MK" ]]; then
  echo "Already exists: $HALIUM_MK"
else
  cat > "$HALIUM_MK" <<'EOF'
# Minimal Halium product base for legacy Halium 9 device trees.
#
# Some historical device repositories, including halium-leeco zl1, inherit
# $(SRC_TARGET_DIR)/product/halium.mk, but the synced Halium 9 build/make tree
# is LineageOS 16 based and does not ship that file. This lightweight product
# base is enough to let the product parse and to build boot-only Halium targets
# such as halium-boot.

$(call inherit-product, $(SRC_TARGET_DIR)/product/core_minimal.mk)

PRODUCT_PACKAGES += \
    halium-boot
EOF
  echo "Created $HALIUM_MK"
fi

# Avoid Lineage roomservice trying to auto-fetch from GitHub if lunch fails; all
# required zl1 repos are supplied by the local manifest.
mkdir -p "$BUILD_DIR/.repo/local_manifests"

# Halium's manifest comments out tools/metalava, but LineageOS 16 droiddoc
# rules still run `find tools/metalava/manual` while parsing some doc modules.
# For boot-only builds an empty directory is sufficient to keep makefile parsing
# from failing before the requested halium-boot target is reached.
mkdir -p "$BUILD_DIR/tools/metalava/manual"
echo "Ensured $BUILD_DIR/tools/metalava/manual exists"


# Lineage bootanimation Android.mk checks `command -v mogrify` at parse time.
# Boot-only Halium builds do not need a real bootanimation, so provide a local
# no-op mogrify in the external build tree instead of requiring global
# ImageMagick installation.
HOST_TOOLS="$BUILD_DIR/.halium-host-tools"
mkdir -p "$HOST_TOOLS"
cat > "$HOST_TOOLS/mogrify" <<'EOF'
#!/usr/bin/env bash
# no-op placeholder for boot-only Halium builds
exit 0
EOF
chmod +x "$HOST_TOOLS/mogrify"
echo "Ensured no-op $HOST_TOOLS/mogrify exists"

# The zl1 kernel Makefile invokes scripts/gcc-wrapper.py directly as the C
# compiler wrapper. Upstream this script is Python 2-only (`print >>` and a
# python2 shebang), but many modern hosts no longer ship python2. Replace it
# with a Python 3-compatible equivalent in the external build tree.
GCC_WRAPPER="$BUILD_DIR/kernel/leeco/msm8996/scripts/gcc-wrapper.py"
if [[ -f "$GCC_WRAPPER" ]]; then
  cat > "$GCC_WRAPPER" <<'EOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-

# Python 3-compatible replacement for the legacy Qualcomm gcc-wrapper.py.
# It preserves the original behavior: run the real compiler, mirror stderr,
# and fail the build when non-whitelisted compiler warnings are emitted.

import errno
import os
import re
import subprocess
import sys

allowed_warnings = set([
    "fdt.c:932",
    "hid-magicmouse.c:579",
    "sysrq.c:956",
    "hci_sock.c:980",
    "pppopns.c:296",
    "pppopns.c:305",
    "pppopns.c:336",
])

ofile = None
warning_re = re.compile(r'''(.*/|)([^/]+\.[a-z]+:\d+):(\d+:)? warning:''')


def interpret_warning(line):
    """Decode gcc warning lines and fail on non-whitelisted warnings."""
    global ofile
    text = line.rstrip('\n')
    match = warning_re.match(text)
    if match and match.group(2) not in allowed_warnings:
        print("error, forbidden warning:", match.group(2), file=sys.stderr)
        if ofile:
            try:
                os.remove(ofile)
            except OSError:
                pass
        sys.exit(1)


def run_gcc():
    global ofile
    args = sys.argv[1:]
    try:
        index = args.index('-o')
        ofile = args[index + 1]
    except (ValueError, IndexError):
        pass

    try:
        proc = subprocess.Popen(
            args,
            stderr=subprocess.PIPE,
            universal_newlines=True,
            errors='replace',
        )
        assert proc.stderr is not None
        for line in proc.stderr:
            print(line, end='', file=sys.stderr)
            interpret_warning(line)
        return proc.wait()
    except OSError as exc:
        result = exc.errno
        if result == errno.ENOENT:
            compiler = args[0] if args else 'compiler'
            print(compiler + ':', exc.strerror, file=sys.stderr)
            print('Is your PATH set correctly?', file=sys.stderr)
        else:
            print(' '.join(args), str(exc), file=sys.stderr)
        return result


if __name__ == '__main__':
    sys.exit(run_gcc())
EOF
  chmod +x "$GCC_WRAPPER"
  echo "Patched Python 3-compatible $GCC_WRAPPER"
else
  echo "Missing kernel gcc wrapper: $GCC_WRAPPER" >&2
  exit 1
fi

# GCC 10+ defaults to -fno-common, which breaks this old kernel's shipped DTC
# generated lexer/parser pair with a duplicate `yylloc` symbol at host-link time.
# Build only the in-tree host DTC lexer/parser objects with -fcommon; this does
# not affect target kernel compiler flags or the phone. The per-object lines are
# intentional: the Makefile assigns HOSTCFLAGS_dtc-*.o with := before this local
# block, so appending only to HOSTCFLAGS_DTC is not enough.
DTC_MAKEFILE="$BUILD_DIR/kernel/leeco/msm8996/scripts/dtc/Makefile"
if [[ -f "$DTC_MAKEFILE" ]]; then
  if grep -q 'HOSTCFLAGS_dtc-lexer.lex.o += -fcommon' "$DTC_MAKEFILE" && \
     grep -q 'HOSTCFLAGS_dtc-parser.tab.o += -fcommon' "$DTC_MAKEFILE"; then
    echo "DTC Makefile already has per-object -fcommon compatibility: $DTC_MAKEFILE"
  else
    cat >> "$DTC_MAKEFILE" <<'EOF'

# Local host-build compatibility for modern GCC (default -fno-common).
# Per-object lines are required because this Makefile assigns HOSTCFLAGS_dtc-*.o
# with := earlier, so changing HOSTCFLAGS_DTC alone may not affect those objects.
HOSTCFLAGS_DTC += -fcommon
HOSTCFLAGS_dtc-lexer.lex.o += -fcommon
HOSTCFLAGS_dtc-parser.tab.o += -fcommon
EOF
    echo "Patched host DTC per-object -fcommon compatibility in $DTC_MAKEFILE"
  fi

  # If DTC objects were already built before the flag patch, Kbuild may go
  # straight to HOSTLD and reuse the stale -fno-common objects. Remove only the
  # external tree's DTC host objects/binary so they are rebuilt with -fcommon.
  DTC_OBJ_DIR="$BUILD_DIR/out/target/product/zl1/obj/KERNEL_OBJ/scripts/dtc"
  if [[ -d "$DTC_OBJ_DIR" ]]; then
    rm -f "$DTC_OBJ_DIR"/dtc \
          "$DTC_OBJ_DIR"/*.o \
          "$DTC_OBJ_DIR"/dtc-lexer.lex.c \
          "$DTC_OBJ_DIR"/dtc-parser.tab.c \
          "$DTC_OBJ_DIR"/dtc-parser.tab.h
    echo "Removed stale host DTC objects in $DTC_OBJ_DIR"
  fi
else
  echo "Missing kernel DTC Makefile: $DTC_MAKEFILE" >&2
  exit 1
fi

# The halium-leeco zl1 defconfig currently selects the x2 product variant in this
# tree, which produces an appended DTB set that the zl1 bootloader cannot match
# reliably. Use the zl1 product config and explicitly list only the five stock
# zl1 DTBs, in the same board-id set/order observed in the trusted stock boot
# image. Without the explicit list, the kernel Makefile falls back to appending
# every built DTB under arch/arm64/boot/dts, including stale x2 DTBs from earlier
# builds; one such unfiltered image dropped the phone into 9008/QDL.
DEFCONFIG="$BUILD_DIR/kernel/leeco/msm8996/arch/arm64/configs/lineage_zl1_defconfig"
ZL1_DTB_LIST="qcom/msm8996pro-pmi8996-le_zl1-dvt1 qcom/msm8996-v3-pmi8996-le_zl1-dvt1 qcom/msm8996pro-pmi8996-le_zl1-na qcom/msm8996-v3-pmi8996-le_zl1-evt qcom/msm8996pro-pmi8996-le_zl1-pvt"
if [[ -f "$DEFCONFIG" ]]; then
  DEFCONFIG="$DEFCONFIG" ZL1_DTB_LIST="$ZL1_DTB_LIST" python3 - <<'PY'
import os
from pathlib import Path

path = Path(os.environ['DEFCONFIG'])
dtb_list = os.environ['ZL1_DTB_LIST']
lines = path.read_text().splitlines()
out = []
seen_dtb = False
seen_x2 = False
seen_zl1 = False
changed = False

for line in lines:
    if line.startswith('CONFIG_BUILD_ARM64_APPENDED_DTB_IMAGE_NAMES='):
        newline = f'CONFIG_BUILD_ARM64_APPENDED_DTB_IMAGE_NAMES="{dtb_list}"'
        seen_dtb = True
    elif line.startswith('CONFIG_PRODUCT_LE_X2=') or line.startswith('# CONFIG_PRODUCT_LE_X2 is not set'):
        newline = '# CONFIG_PRODUCT_LE_X2 is not set'
        seen_x2 = True
    elif line.startswith('CONFIG_PRODUCT_LE_ZL1=') or line.startswith('# CONFIG_PRODUCT_LE_ZL1 is not set'):
        newline = 'CONFIG_PRODUCT_LE_ZL1=y'
        seen_zl1 = True
    else:
        newline = line
    if newline != line:
        changed = True
    out.append(newline)

if not seen_dtb:
    out.append(f'CONFIG_BUILD_ARM64_APPENDED_DTB_IMAGE_NAMES="{dtb_list}"')
    changed = True
if not seen_x2:
    out.append('# CONFIG_PRODUCT_LE_X2 is not set')
    changed = True
if not seen_zl1:
    out.append('CONFIG_PRODUCT_LE_ZL1=y')
    changed = True

new_text = '\n'.join(out) + '\n'
if new_text != path.read_text():
    path.write_text(new_text)
    changed = True
print(('Patched' if changed else 'Already patched') + f' zl1 product/DTB settings in {path}')
PY

  # Remove stale generated DTBs and kernel image outputs. The old Makefile's
  # fallback-all-DTB behavior can otherwise accidentally append leftover x2 DTBs
  # from a previous build even after the defconfig is corrected.
  KERNEL_OBJ="$BUILD_DIR/out/target/product/zl1/obj/KERNEL_OBJ"
  if [[ -d "$KERNEL_OBJ" ]]; then
    rm -f "$KERNEL_OBJ"/arch/arm64/boot/Image.gz-dtb \
          "$KERNEL_OBJ"/arch/arm64/boot/Image.gz \
          "$KERNEL_OBJ"/arch/arm64/boot/dts/qcom/*.dtb
    echo "Removed stale generated kernel/DTB outputs in $KERNEL_OBJ"
  fi
else
  echo "Missing zl1 defconfig: $DEFCONFIG" >&2
  exit 1
fi
