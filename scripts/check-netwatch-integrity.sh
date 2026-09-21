#!/usr/bin/env bash
# Assert a netwatch build still contains every function it is supposed to.
#
# Why: on 2026-09-19 a Python edit sliced from a comment block to `hwcheck()`, which
# spanned restore_addrs, heal_reenumerate, heal_rebind_function, heal and netsnap.
# Deleting function definitions is not a syntax error, so `sh -n` passed and the file
# shrank from 23513 to 19043 bytes unnoticed. It was then installed and used for a cold
# boot, which had to be discarded.
#
# Usage: check-netwatch-integrity.sh [FILE]

set -uo pipefail
F="${1:-/mnt/data/zl1-bb10/scripts/device/zl1-netwatch.sh}"
[[ -f "$F" ]] || { echo "missing $F" >&2; exit 1; }

REQUIRED="log ifname_stats gadget_stats sample probe_host write_file restore_addrs
heal_reenumerate heal_rebind_function heal apply_policy_routing_fix hwcheck netsnap
container_pid"

missing=""; n=0
for fn in $REQUIRED; do
  n=$((n + 1))
  grep -q "^$fn()" "$F" || missing="$missing $fn"
done

echo "file: $F ($(wc -c < "$F") bytes, $(wc -l < "$F") lines)"
echo "functions checked: $n"
if [[ -n "$missing" ]]; then
  echo "MISSING:$missing" >&2
  exit 1
fi
# The two keyword counts that would also have caught it.
tb=$(grep -c '^POLICY_TABLES=' "$F"); [[ "$tb" -eq 1 ]] || { echo "POLICY_TABLES defined $tb times, want 1" >&2; exit 1; }
echo "all $n functions present"
