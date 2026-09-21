#!/usr/bin/env bash
# Pull the Android libraries off the device that the shims are built *against*.
#
# These are link-time inputs only. Nothing here is modified except
# libhidltransport.so, which build-hybris-shims.sh patches; everything else is
# used to resolve the Android-side symbols (GraphicBuffer, operator new, …) so
# the shim's ABI is the device's ABI rather than a guess at it.
#
# Read-only with respect to the device: it only copies files out.
#
# Usage: fetch-android-libs.sh [OUTDIR]     (default: <here>/out/stubs)

set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="${1:-$here/out/stubs}"
DEV="${ZL1_HOST:-root@10.15.19.82}"

# libhidltransport.so is not a link-time dependency of anything we build — it is
# the file we ship a patched copy of, so we need the original to patch.
LIBS="libui.so libgui.so libutils.so libcutils.so libbinder.so libhardware.so \
      liblog.so libc.so libm.so libdl.so libc++.so libbase.so libhidltransport.so"

SCP=(scp -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$DEV")

# A wrong address would mean copying files off somebody else's machine.
"${SSH[@]}" 'grep -qa msm8996 /proc/device-tree/compatible' 2>/dev/null ||
  { echo "not the zl1 (no msm8996 in /proc/device-tree/compatible) — refusing" >&2; exit 1; }

mkdir -p "$out"
for l in $LIBS; do
  "${SCP[@]}" "$DEV:/android/system/lib64/$l" "$out/$l" || { echo "could not fetch $l" >&2; exit 1; }
done

echo "fetched $(echo $LIBS | wc -w) libraries into $out"
( cd "$out" && sha256sum $LIBS )
