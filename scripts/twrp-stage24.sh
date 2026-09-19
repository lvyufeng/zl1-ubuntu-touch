#!/usr/bin/env bash
# One TWRP window: install the fixed netwatch, verify it, and cold boot.
#
# Run this with the device in TWRP. It installs the integrity-checked build in
# record-only mode, confirms on the device that the marker and the three-table fix are
# both present, then boots UT. The cold boot is then counted by verify-over-ssh.sh.
#
# Usage: twrp-stage24.sh [WAIT_TWRP_SECONDS]

set -uo pipefail
ROOT=/mnt/data/zl1-bb10
SER="33e80afe"
WAIT="${1:-7200}"
log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
in_recovery() { [[ "$(adb devices 2>/dev/null | awk -v s="$SER" '$1==s{print $2}')" == "recovery" ]]; }

log "waiting for TWRP (up to ${WAIT}s)"
deadline=$(( SECONDS + WAIT ))
while (( SECONDS < deadline )); do in_recovery && break; sleep 10; done
in_recovery || { log "timed out"; exit 1; }
log "TWRP up"

log "== install (integrity check runs inside) =="
"$ROOT/scripts/install-netwatch-service.sh" --yes --noheal >>"$ROOT/tmp-stage24.log" 2>&1 \
  || { log "install refused or failed — see $ROOT/tmp-stage24.log"; exit 1; }

log "== verify on the device, not from the installer's own message =="
chk() { adb -s "$SER" shell "$1" | tr -d '\r'; }
m="$(chk 'ls /data/zl1-netwatch-noheal 2>/dev/null')"
[[ -n "$m" ]] || { log "FATAL: record-only marker missing"; exit 1; }
log "record-only marker: present"
f="$(chk 'grep -c "^heal_rebind_function()" /data/system-data/etc/systemd/system/zl1-netwatch.sh')"
[[ "$f" = "1" ]] || { log "FATAL: installed script is missing heal_rebind_function ($f)"; exit 1; }
log "installed script has all functions"
t="$(chk 'grep -c "^POLICY_TABLES=" /data/system-data/etc/systemd/system/zl1-netwatch.sh')"
[[ "$t" = "1" ]] || { log "FATAL: POLICY_TABLES count is $t"; exit 1; }
log "installed script has the three-table fix"

log "== clear the old log and boot =="
chk 'rm -f /data/zl1-netwatch.log; sync' >/dev/null
adb -s "$SER" shell 'sync; reboot'
log "booted; count this trial with: $ROOT/scripts/verify-over-ssh.sh --note 'cold boot #N'"
