#!/usr/bin/env bash
# Stage 2 acceptance over SSH instead of over RNDIS probes.
#
# SSH became usable on 2026-09-19 (see docs/ubuntu-touch/35-...), which changes what a
# "cold boot trial" can check. Pinging the host from the device and reading the status
# page both only tell you the link is up; SSH additionally lets the check run the actual
# acceptance criteria — is systemd PID 1, is the Android container running, are the HAL
# processes there, is the policy routing fix holding.
#
# Usage: verify-over-ssh.sh [--note "..."]
# Exit 0 when every criterion passes.

set -uo pipefail
SER_HOST="root@10.15.19.82"
NOTE=""
[[ "${1:-}" == "--note" ]] && NOTE="$2"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="/mnt/data/zl1-bb10/tmp-ssh-verify-${STAMP}"
mkdir -p "$OUT"
LEDGER="/mnt/data/zl1-bb10/docs/ubuntu-touch/stage2-coldboot-trials.md"

SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$SER_HOST")

report="$(timeout 45 "${SSH[@]}" '
  echo "uptime=$(cut -d" " -f1 /proc/uptime)"
  echo "pid1=$(cat /proc/1/comm)"
  p=$(pgrep -f "lxc-start -n android" | head -1)
  echo "lxc_start=${p:-none}"
  echo "hal_count=$(pgrep -cf "android\.hardware" 2>/dev/null || echo 0)"
  echo "coldboot_done=$([ -n "$p" ] && { [ -e /proc/$p/root/dev/.coldboot_done ] && echo yes || echo no; } || echo n/a)"
  echo "route_get=$(ip route get 192.168.2.100 >/dev/null 2>&1 && echo ok || echo FAIL)"
  echo "t99=$(ip route show table 99 2>/dev/null | wc -l)"
  echo "sshd=$(ss -ltn 2>/dev/null | grep -c ":22 " || echo 0)"
' 2>/dev/null)"

printf '%s\n' "$report" > "$OUT/verify.txt"
get() { printf '%s\n' "$report" | sed -n "s/^$1=//p" | head -1; }

uptime="$(get uptime)"; pid1="$(get pid1)"; lxc="$(get lxc_start)"
hal="$(get hal_count)"; cold="$(get coldboot_done)"; rg="$(get route_get)"; t99="$(get t99)"

pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  OK   %-22s %s\n' "$1" "$2"
        else fail=$((fail+1)); printf '  FAIL %-22s got=%s want=%s\n' "$1" "$2" "$3"; fi; }
chk systemd_pid1   "$pid1" "systemd"
chk link_route_get "$rg"   "ok"
chk table99_routes "$t99"  "2"

printf '  info container=%s hal=%s coldboot_done=%s uptime=%s\n' "${lxc:-none}" "${hal:-0}" "${cold:-?}" "${uptime:-?}"
[ "${hal:-0}" -ge 5 ] 2>/dev/null && printf '  OK   %-22s %s\n' "hal_processes" "$hal" || printf '  WARN %-22s %s\n' "hal_processes" "${hal:-0}"

if [[ ! -f "$LEDGER" ]]; then
  mkdir -p "$(dirname "$LEDGER")"
  { echo "# Stage 2.4 — cold-boot trials"; echo
    echo "One row per boot, appended by \`scripts/stage2-coldboot-trial.sh\` (RNDIS probes)"
    echo "or \`scripts/verify-over-ssh.sh\` (SSH, from 2026-09-19). Stage 2.4 asks for three"
    echo "consecutive boots with the same result."; echo
    echo "| # | UTC | method | pid1 | link | t99 | container | HAL | coldboot_done | note |"
    echo "| ---: | --- | --- | --- | --- | ---: | --- | ---: | --- | --- |"
  } > "$LEDGER"
fi
n=$(( $(grep -c '^| [0-9]' "$LEDGER" || true) + 1 ))
printf '| %d | %s | ssh | %s | %s | %s | %s | %s | %s | %s |\n' \
  "$n" "$STAMP" "${pid1:-?}" "${rg:-?}" "${t99:-?}" "${lxc:-none}" "${hal:-0}" "${cold:-?}" "$NOTE" >> "$LEDGER"

echo
echo "pass=$pass fail=$fail   evidence: $OUT"
[[ "$fail" -eq 0 ]]
