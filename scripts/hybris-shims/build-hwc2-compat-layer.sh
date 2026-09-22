#!/usr/bin/env bash
# Kept as a name: this is now a wrapper around build-compat-layer.sh, which does the same work for
# the whole `*_compat_layer.so` family (ui, hwc2, camera). The build harness -- ImageMagick,
# the python2 shim for the Soong genrules, ALLOW_MISSING_DEPENDENCIES, the envsetup/lunch dance --
# is identical for all of them, and it was only ever specific to hwc2 in the filename.
#
# Usage: build-hwc2-compat-layer.sh [tree-dir] [lunch-target]

set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
exec "$here/build-compat-layer.sh" libhwc2_compat_layer "$@"
