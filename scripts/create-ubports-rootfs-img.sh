#!/usr/bin/env bash
set -euo pipefail

# Create a host-side Ubuntu Touch rootfs.img from an official UBports
# system-image rootfs tarball. This script does not touch the phone.

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 /path/to/ubports-rootfs.tar.xz /path/to/rootfs.img [size-mib]" >&2
  echo "Example: $0 /mnt/data/ubports-rootfs/ubports-16.04-arm64-android9-ota25.tar.xz /mnt/data/ubports-rootfs/rootfs.img 4096" >&2
  exit 2
fi

TARBALL=$(realpath -m "$1")
OUT_IMG=$(realpath -m "$2")
SIZE_MIB=${3:-4096}
EXPECTED_PREFIX=${UBPORTS_TAR_PREFIX:-system}

if [[ ! -f "$TARBALL" ]]; then
  echo "Missing tarball: $TARBALL" >&2
  exit 1
fi

for tool in fakeroot tar truncate mke2fs e2fsck sha256sum; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required host tool: $tool" >&2
    exit 1
  fi
done

mkdir -p "$(dirname "$OUT_IMG")"
WORKDIR=$(mktemp -d "$(dirname "$OUT_IMG")/.rootfs-build.XXXXXX")
cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

ROOTDIR="$WORKDIR/rootfs"
mkdir -p "$ROOTDIR"
rm -f "$OUT_IMG" "$OUT_IMG.partial"

echo "Input tarball: $TARBALL"
echo "Output image:  $OUT_IMG"
echo "Image size:    ${SIZE_MIB} MiB"
echo "Tar prefix:    $EXPECTED_PREFIX/"
echo "This is host-only; no adb/fastboot/device operation is performed."

# Extract and build the filesystem inside one fakeroot session so numeric owners,
# modes, symlinks, and special files from the tarball are represented to mke2fs.
fakeroot -- bash -euo pipefail <<EOF
set -euo pipefail
ROOTDIR='$ROOTDIR'
TARBALL='$TARBALL'
OUT_IMG_PARTIAL='$OUT_IMG.partial'
SIZE_MIB='$SIZE_MIB'
EXPECTED_PREFIX='$EXPECTED_PREFIX'

tar -tf "\$TARBALL" "\$EXPECTED_PREFIX/." >/dev/null

tar --extract \
    --file "\$TARBALL" \
    --directory "\$ROOTDIR" \
    --strip-components=1 \
    --numeric-owner \
    --xattrs \
    --acls \
    "\$EXPECTED_PREFIX/."

test -e "\$ROOTDIR/sbin/init" || { echo "Extracted rootfs lacks /sbin/init" >&2; exit 1; }
test -d "\$ROOTDIR/etc/system-image" || { echo "Extracted rootfs lacks /etc/system-image" >&2; exit 1; }

truncate -s "\${SIZE_MIB}M" "\$OUT_IMG_PARTIAL"
mke2fs -q -t ext4 -F -L UBPORTS_ROOTFS -d "\$ROOTDIR" "\$OUT_IMG_PARTIAL"
EOF

e2fsck -fy "$OUT_IMG.partial" >/dev/null
mv "$OUT_IMG.partial" "$OUT_IMG"

printf '\n== rootfs image ==\n'
ls -lh "$OUT_IMG"
sha256sum "$OUT_IMG"

printf '\n== filesystem info ==\n'
dumpe2fs -h "$OUT_IMG" 2>/dev/null | sed -n '1,40p'
