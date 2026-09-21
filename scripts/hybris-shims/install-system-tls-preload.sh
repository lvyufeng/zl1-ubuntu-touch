#!/usr/bin/env bash
# Give every system service that loads an Android library the bionic-TLS shim.
#
# Why this exists: docs 41/45 fixed the TLS fault for the *compositor* and the *session*, by
# putting `LD_PRELOAD=libtls-padding.so` in lsc-wrapper and in the Lomiri unit's drop-in.
# Nothing was done for the system services, and on 2026-09-21 seven of them were sitting in
# `failed (Result: signal)` with the same SIGSEGV:
#
#   mechanicd  repowerd  sensorfwd  urfkill  hfd-service  lomiri-location-service  biometryd
#
# They are all Halium services — power, sensors, rfkill, haptics, GPS, fingerprint — that
# call into an Android library through libhybris, so they hit the same NULL TLS slot 1 and
# die the same way. Adding the preload to four of them brought them straight up
# (`mechanicd`, `repowerd`, `urfkill`, `hfd-service` went active with 0 restarts).
#
# Rather than list them by hand, this finds them: any enabled system unit whose ExecStart
# binary mentions libhybris gets a drop-in on the /etc/systemd/system writable-path, so it
# survives a reboot and stays right as units come and go.
#
# Usage: install-system-tls-preload.sh --install | --remove | --status
#
# Env: ZL1_HOST (default root@10.15.19.82)

set -uo pipefail
DEV="${ZL1_HOST:-root@10.15.19.82}"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$DEV")

guard() {
  "${SSH[@]}" 'grep -qa msm8996 /proc/device-tree/compatible' 2>/dev/null ||
    { echo "not the zl1 (no msm8996 in /proc/device-tree/compatible) — refusing" >&2; exit 1; }
}

# The discovery and the write loop both run on the device. `systemctl show` gives the
# ExecStart path and `grep -q libhybris` on the binary is the over-approximate test for
# "this one may read an Android TLS slot" — there is no readelf there. It over-approximates:
# snapd mentions the libhybris sonames too (it probes the platform), so it gets a drop-in it
# does not need. That costs nothing, and a rule that is a bit too wide is better here than a
# hand-maintained list that goes stale.
#
# It also *under*-approximates, which is why there is a second list below.
#
# The units are the *enabled* ones, because a disabled unit will not start at boot whether it
# has the drop-in or not.
#
# The scan cannot see services that reach their Android side through a runtime plugin rather
# than a link: sensorfwd, urfkill, hfd-service, lomiri-location-service and biometryd have no
# "libhybris" string in their executable at all, yet five of them were in `failed (Result:
# signal)` with the same SIGSEGV on 2026-09-21. They were found by their failures, not by
# their symbols, so they are listed here.
EXTRA_UNITS="mechanicd repowerd sensorfwd urfkill hfd-service lomiri-location-service biometryd"

REMOTE_SCAN='
  for u in $(systemctl list-unit-files --type=service --state=enabled --no-legend --plain 2>/dev/null | awk "{print \$1}"); do
    b=$(systemctl show "$u" -p ExecStart --value 2>/dev/null | sed -n "s/.*path=\([^ ;]*\).*/\1/p" | head -1)
    [ -n "$b" ] || continue
    [ -x "$b" ] || continue
    grep -qa libhybris "$b" 2>/dev/null || continue
    echo "$u $b"
  done
'

case "${1:-}" in
--install)
  guard
  echo "scanning the device for services that link libhybris..."
  found="$("${SSH[@]}" "$REMOTE_SCAN")"
  echo "  (plus the units that reach Android through a plugin: $EXTRA_UNITS)"
  # Quoted delimiter: nothing in the body needs expanding here, so there is no escaping to
  # get wrong. EXTRA_UNITS goes in on stdin rather than inside the heredoc, which is what
  # keeps the delimiter quotable.
  "${SSH[@]}" "EXTRA_UNITS='$EXTRA_UNITS' bash -s" <<'REMOTE'
set -u
shim_env='[Service]
Environment=LD_PRELOAD=/usr/lib/aarch64-linux-gnu/libtls-padding.so'
add() {
  u=$1
  mkdir -p "/etc/systemd/system/$u.d"
  printf '%s\n' "$shim_env" > "/etc/systemd/system/$u.d/zl1-tls.conf"
  n=$((n + 1))
}
n=0
for u in $(systemctl list-unit-files --type=service --state=enabled --no-legend --plain 2>/dev/null | awk '{print $1}'); do
  b=$(systemctl show "$u" -p ExecStart --value 2>/dev/null | sed -n 's/.*path=\([^ ;]*\).*/\1/p' | head -1)
  [ -n "$b" ] || continue
  [ -x "$b" ] || continue
  grep -qa libhybris "$b" 2>/dev/null || continue
  add "$u"
done
for u in $EXTRA_UNITS; do
  systemctl list-unit-files --type=service "$u.service" >/dev/null 2>&1 || continue
  add "$u"
done
systemctl daemon-reload
echo "wrote $n drop-in(s)"
# reset-failed first: a unit that already exhausted Restart= is not started by `start`.
for u in $(systemctl list-unit-files --type=service --state=enabled --no-legend --plain 2>/dev/null | awk '{print $1}'); do
  [ -f "/etc/systemd/system/$u.d/zl1-tls.conf" ] || continue
  systemctl reset-failed "$u" >/dev/null 2>&1
  systemctl start --no-block "$u" >/dev/null 2>&1
done
sleep 20
echo "-- now:"
for u in $(systemctl list-unit-files --type=service --state=enabled --no-legend --plain 2>/dev/null | awk '{print $1}'); do
  [ -f "/etc/systemd/system/$u.d/zl1-tls.conf" ] || continue
  printf '  %-32s %s\n' "$u" "$(systemctl is-active "$u" 2>&1)"
done
REMOTE
  echo
  echo "Verify with: $0 --status"
  ;;
--remove)
  guard
  "${SSH[@]}" "
    n=0
    for f in /etc/systemd/system/*.service.d/zl1-tls.conf; do
      [ -f \"\$f\" ] || continue
      rm -f \"\$f\"; n=\$((n+1))
      rmdir \"\$(dirname \$f)\" 2>/dev/null
    done
    systemctl daemon-reload
    echo \"removed \$n drop-in(s). The services go back to segfaulting at their next start.\""
  ;;
--status)
  guard
  "${SSH[@]}" "
    echo 'services with the shim (from the /etc/systemd/system writable-path):'
    for f in /etc/systemd/system/*.service.d/zl1-tls.conf; do
      [ -f \"\$f\" ] || continue
      u=\$(basename \$(dirname \$f) .d)
      printf '  %-32s %s\n' \"\$u\" \"\$(systemctl is-active \$u 2>&1)\"
    done
    echo
    echo -n 'shim in place: '
    findmnt -n -T /usr/lib/aarch64-linux-gnu/libtls-padding.so -o TARGET 2>/dev/null || echo 'NO — run install-tlsfix.sh --mount'
    echo 'still failing:'
    systemctl list-units --state=failed --no-legend --plain 2>/dev/null | awk '{print \"  \" \$1}'"
  ;;
*)
  sed -n '2,26p' "$0"; exit 1;;
esac
