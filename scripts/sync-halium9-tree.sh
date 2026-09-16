#!/usr/bin/env bash
set -euo pipefail
export PATH="$HOME/bin:$PATH"

# Sync external Halium 9 build tree. Does not touch the phone.

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /path/to/external-halium-build-tree" >&2
  exit 2
fi

BUILD_DIR=$(realpath -m "$1")
if [[ ! -d "$BUILD_DIR/.repo" ]]; then
  echo "Not a repo build tree: $BUILD_DIR" >&2
  exit 1
fi

cd "$BUILD_DIR"
JOBS=${JOBS:-8}
repo sync -c --force-sync --no-clone-bundle --no-tags -j"$JOBS"

printf '\n== key source revisions ==\n'
repo forall device/leeco/zl1 device/leeco/msm8996-common kernel/leeco/msm8996 vendor/leeco -c 'printf "%s %s %s\n" "$REPO_PATH" "$(git rev-parse HEAD)" "$(git rev-parse --abbrev-ref HEAD)"' || true
