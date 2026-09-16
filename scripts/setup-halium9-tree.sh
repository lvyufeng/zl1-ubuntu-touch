#!/usr/bin/env bash
set -euo pipefail
export PATH="$HOME/bin:$PATH"

# Initialize an external Halium 9 build tree for zl1. Does not touch the phone.

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /path/to/external-halium-build-tree" >&2
  exit 2
fi

BUILD_DIR=$(realpath -m "$1")
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MANIFEST_SRC="$REPO_ROOT/manifests/halium-9-zl1.xml"

case "$BUILD_DIR" in
  "$REPO_ROOT"|"$REPO_ROOT"/*)
    echo "Refusing to initialize Android/Halium source inside notes repo: $REPO_ROOT" >&2
    exit 1
    ;;
esac

if [[ ! -f "$MANIFEST_SRC" ]]; then
  echo "Missing local manifest: $MANIFEST_SRC" >&2
  exit 1
fi

command -v repo >/dev/null 2>&1 || {
  echo "repo command not found. Install repo first." >&2
  exit 1
}

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

if [[ ! -d .repo ]]; then
  repo init -u https://github.com/Halium/android -b halium-9.0 --depth=1
else
  echo ".repo already exists; leaving existing repo init in place."
fi

mkdir -p .repo/local_manifests
cp "$MANIFEST_SRC" .repo/local_manifests/zl1.xml

echo "Installed local manifest to $BUILD_DIR/.repo/local_manifests/zl1.xml"
echo "Next: scripts/sync-halium9-tree.sh $BUILD_DIR"
