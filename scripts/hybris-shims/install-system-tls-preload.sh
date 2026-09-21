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

# The discovery runs on the device: `systemctl show` gives each enabled unit's ExecStart path,
# and the test for "this one may read an Android TLS slot" is a string scan of that binary.
# `readelf`, `objdump` and `strings` are all absent there, so `grep -a` is what there is.
# It over-approximates: snapd mentions the libhybris sonames too (it probes the platform), so
# it gets a drop-in it does not need. That costs nothing, and a rule that is a bit too wide is
# better here than a hand-maintained list that goes stale.
#
# It also *under*-approximates, which is why there is a second list below, and since
# 2026-09-21 it follows the library graph instead of only looking at the executable.
#
# The units are the *enabled* ones, because a disabled unit will not start at boot whether it
# has the drop-in or not.
#
# The scan cannot see services that reach their Android side through a runtime plugin rather
# than a link: sensorfwd, urfkill, hfd-service, lomiri-location-service and biometryd have no
# "libhybris" string in their executable at all, yet five of them were in `failed (Result:
# signal)` with the same SIGSEGV on 2026-09-21. They were found by their failures, not by
# their symbols, so they are listed here.
#
# **The transitive case is now covered too** (added 2026-09-21, for
# `update-machine-info-from-deviceinfo`). A binary can reach the Android side *through another
# host library*: that unit's `ExecStart` is a small program whose only interesting `DT_NEEDED`
# is `libdeviceinfo.so.0`, which links `libandroid-properties.so.1`, which is the one that
# links `libhybris-common.so.1` and calls `property_get`. Grepping the executable alone finds
# none of that, which is why it sat in `failed (Result: signal)` with no explanation.
#
# So `uses_hybris()` below walks the reference graph: for a file, grep it for `libhybris`; if
# that misses, take every `lib*.so*` string in it (over-approximate — the same trade-off as
# above), resolve each through `ldconfig -p`, and recurse. Depth-limited to 4, which is one
# more than this case needs. It is a string scan, not an ELF parse: `readelf`, `objdump` and
# `strings` are all absent on this device, `grep -a` is what there is, and for a
# "does this ever mention libhybris" question that is enough.
#
# Two things that made the *writing* half lie, both fixed 2026-09-21. They are worth naming
# because both produced the same symptom — the installer printing a count of drop-ins written
# while the unit it was supposed to fix stayed `failed`:
#
#   1. the name had the `.service` suffix stripped for the guard and then appended again for
#      the path, so a scanned `foo.service` became `foo.service.service` and the guard skipped
#      it — every unit the scan found was dropped;
#   2. the drop-in directory was built from the bare name (`foo.d`), and systemd only reads
#      `foo.service.d` for a service. Files under `foo.d` are never loaded at all.
#
# `add()` now normalises to the full unit name once and both the guard and the paths use it,
# and `--install`/`--remove` clean up the stray `foo.d` directories the old version left.
EXTRA_UNITS="mechanicd repowerd sensorfwd urfkill hfd-service lomiri-location-service biometryd update-machine-info-from-deviceinfo"

REMOTE_SCAN='
  LDCACHE=/tmp/zl1-ldcache.$$
  ldconfig -p > "$LDCACHE" 2>/dev/null
  # soname -> soname to absolute path, via the ldconfig cache. A line looks like
  #     \tlibc.so.6 (libc6,AArch64) => /lib/aarch64-linux-gnu/libc.so.6
  # so with `-F" => "` column 1 is the soname followed by the tag and column 2 is the path.
  # The soname is the *first* whitespace-separated word of column 1, after the leading tab —
  # it is not the last one, which is the tag. `==` is a string compare, so the dots and pluses
  # in a soname are not treated as patterns.
  resolve() {
    awk -v s="$1" -F" => " "NF==2 { t=\$1; sub(/^[ \t]+/, \"\", t); split(t, a, \" \"); if (a[1]==s) { print \$2; exit } }" "$LDCACHE"
  }
  mentions_hybris() { grep -qa libhybris "$1" 2>/dev/null; }
  uses_hybris() {
    seen=""; todo="$1"; d=0
    while [ -n "$todo" ] && [ "$d" -lt 4 ]; do
      next=""
      for f in $todo; do
        case " $seen " in *" $f "*) continue;; esac
        seen="$seen $f"
        mentions_hybris "$f" && return 0
        for so in $(grep -aoE "lib[a-zA-Z0-9_+.-]+\.so[0-9.]*" "$f" 2>/dev/null | sort -u); do
          p=$(resolve "$so")
          [ -n "$p" ] && next="$next $p"
        done
      done
      todo="$next"; d=$((d + 1))
    done
    return 1
  }
  for u in $(systemctl list-unit-files --type=service --state=enabled --no-legend --plain 2>/dev/null | awk "{print \$1}"); do
    b=$(systemctl show "$u" -p ExecStart --value 2>/dev/null | sed -n "s/.*path=\([^ ;]*\).*/\1/p" | head -1)
    [ -n "$b" ] || continue
    [ -x "$b" ] || continue
    uses_hybris "$b" || continue
    echo "$u $b"
  done
  rm -f "$LDCACHE"
'

case "${1:-}" in
--install)
  guard
  echo "scanning the device for services that reach libhybris, directly or through a library..."
  found="$("${SSH[@]}" "$REMOTE_SCAN")"
  # The scan's own output drives the writes, rather than being re-derived by a second copy of
  # the same logic inside the heredoc: the two used to differ (the write loop only grepped the
  # executable), so what was printed and what was installed were not guaranteed to be the same
  # set. Now `--install` prints exactly what it found and installs exactly that, plus the
  # hand-listed units the scan cannot see.
  # Bare unit names, not `foo.service`: the write loop below adds the suffix itself, so a name
  # that already carried it would be doubled by a naive append and the guard would skip it.
  # That silently dropped every unit the scan found — which is why the run that added this
  # reported "wrote 8" while `update-machine-info-from-deviceinfo` and `aethercast` got nothing.
  scan_units=$(printf '%s\n' "$found" | awk '{print $1}' | sed 's/\.service$//')
  echo "  found by scan: ${scan_units:-<none>}"
  echo "  plus, from the hand list (reach Android through a runtime plugin): $EXTRA_UNITS"
  # Quoted delimiter: nothing in the body needs expanding here, so there is no escaping to
  # get wrong. The unit list goes in through the environment, which is what keeps the
  # delimiter quotable.
  "${SSH[@]}" "UNITS='$(printf '%s %s' "$scan_units" "$EXTRA_UNITS" | tr -s ' ')' bash -s" <<'REMOTE'
set -u
shim_env='[Service]
Environment=LD_PRELOAD=/usr/lib/aarch64-linux-gnu/libtls-padding.so'
# The drop-in directory has to be named after the **full unit name**, suffix included:
# `foo.service.d`, never `foo.d`. systemd only looks for `foo.d` next to a unit file called
# plain `foo`, which no service here is, so a `foo.d` directory is silently ignored —
# `systemctl cat foo.service` does not mention it and the unit starts exactly as before.
# Every name that arrives as a bare word has to get the suffix before it becomes a path.
add() {
  u=$1
  case "$u" in
  *.service) ;;
  *) u="$u.service" ;;
  esac
  mkdir -p "/etc/systemd/system/$u.d"
  printf '%s\n' "$shim_env" > "/etc/systemd/system/$u.d/zl1-tls.conf"
  n=$((n + 1))
}
n=0
for u in $UNITS; do
  case "$u" in
  *.service) ;;
  *) u="$u.service" ;;
  esac
  systemctl list-unit-files --type=service "$u" >/dev/null 2>&1 || continue
  add "$u"
done
# Clean up directories written by the earlier version of this script, which built the path
# from the bare name. They contain a zl1-tls.conf that has never done anything; leaving them
# risks a later reader concluding the shim is in place for a unit that does not have it.
for d in /etc/systemd/system/*.d; do
  case "$d" in
  *.service.d | *.socket.d | *.target.d | *.timer.d | *.mount.d | '*.d') ;;
  *) [ -f "$d/zl1-tls.conf" ] && { rm -f "$d/zl1-tls.conf"; rmdir "$d" 2>/dev/null; echo "  removed stray $d (ignored by systemd)"; } ;;
  esac
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
    # and the stray <name>.d directories a buggy earlier version wrote (see the note in
    # --install); systemd never read them, so they are removed rather than left looking live.
    for d in /etc/systemd/system/*.d; do
      case \"\$d\" in *.service.d|*.socket.d|*.target.d|*.timer.d|*.mount.d|*.d) ;; *)
        [ -f \"\$d/zl1-tls.conf\" ] && { rm -f \"\$d/zl1-tls.conf\"; rmdir \"\$d\" 2>/dev/null; };;
      esac
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
    # A <name>.d directory looks like a drop-in and is not one: systemd only reads the unit's
    # own name with its suffix. Report them, because the file inside otherwise reads as
    # installed while the unit starts without it.
    stray=''
    for d in /etc/systemd/system/*.d; do
      case \"\$d\" in *.service.d|*.socket.d|*.target.d|*.timer.d|*.mount.d|*.d) ;; *)
        [ -f \"\$d/zl1-tls.conf\" ] && stray=\"\$stray \$d\";;
      esac
    done
    if [ -n \"\$stray\" ]; then
      echo
      echo 'STRAY — ignored by systemd, the shim is NOT in effect for these:'
      for d in \$stray; do echo \"  \$d\"; done
    fi
    echo
    echo -n 'shim in place: '
    findmnt -n -T /usr/lib/aarch64-linux-gnu/libtls-padding.so -o TARGET 2>/dev/null || echo 'NO — run install-tlsfix.sh --mount'
    echo 'still failing:'
    systemctl list-units --state=failed --no-legend --plain 2>/dev/null | awk '{print \"  \" \$1}'"
  ;;
*)
  # The header, whatever its current length: lines 2..the end of the leading comment block.
  # A fixed line range silently truncates the usage text every time the header grows.
  awk 'NR==1{next} /^#/{print; next} {exit}' "$0"; exit 1;;
esac
