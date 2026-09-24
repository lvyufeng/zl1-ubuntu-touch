#!/usr/bin/env bash
# Create Android's fingerprint store directory -- the one step `system_server` would do, and this port
# has nobody to do it. This is the FIX for `setActiveGroup failed: SYS_EINVAL`, not another instrument.
#
# The chain, read out of four sources in order (docs 83):
#
#   (a) the HAL, device/leeco/zl1/biometrics/BiometricsFingerprint.cpp:215-228
#         setActiveGroup(gid, storePath):
#           if (storePath.size() >= PATH_MAX || <= 0) { ALOGE("Bad path length: %zd"); return SYS_EINVAL; }
#           if (access(storePath.c_str(), W_OK))     { return SYS_EINVAL; }   <-- NO LOG AT ALL
#       The second branch is silent. That is why the device log shows only the CALLER's
#       `setActiveGroup failed: SYS_EINVAL` and nothing from the HAL -- and why "Bad path length" = 0
#       is itself the evidence that the failing branch is access().
#
#   (b) the caller, halium/biometryd/src/biometry/devices/android.cpp:590-598
#         api_level = store.get("ro.product.first_api_level"); if empty, store.get("ro.build.version.sdk")
#         if (atoi(api_level) <= 27) setActiveGroup(..., "/data/system/users/0/fpdata/")
#         else                       setActiveGroup(..., "/data/vendor_de/0/fpdata/")
#       The path is not given by the framework or the user: biometryd picks it.
#
#   (c) real Android, frameworks/base/.../fingerprint/FingerprintService.java:1585-1622
#         File fpDir = new File(baseDir, FP_DATA_DIR);      // FP_DATA_DIR = "fpdata"
#         if (!fpDir.exists()) {
#             if (!fpDir.mkdir()) { Slog.v(TAG, "Cannot make directory: ..."); return; }
#             if (!SELinux.restorecon(fpDir)) { ...; return; } }
#         daemon.setActiveGroup(userId, fpDir.getAbsolutePath());
#       system_server creates it, as the `system` uid -- and returns WITHOUT calling setActiveGroup if
#       mkdir fails. The HAL's access(W_OK) passes because by then the directory exists and belongs to
#       the caller.
#
#   (d) this port: nobody creates it. There is no system_server (that is Halium's design), biometryd
#       has no mkdir besides those two path constants, and device/leeco/zl1/biometrics/*.rc has no
#       mkdir for it either (only chown/chmod of sysfs and /dev nodes).
#
# So the ONE thing standing between biometryd and a working setActiveGroup is a missing directory that
# Android's own framework would have created, at a path Android's own framework would have used.
#
# WHERE it goes, and why writing it from the HOST is the right level: Android's `/data` is
# `/dev/sda10[/android-data]`, an ordinary rw ext4, mounted at `/var/lib/android-data` on the host and
# bind-mounted to `/android/data` (= the container's `/data`) by
# usr/libexec/lxc-android-config/mount-android-partitions. It is the SAME filesystem either way, so
# creating the directory through the host path needs no nsenter, works even when the container is not
# running, and cannot be confused by the container's mount namespace. (The fingerprint probe asks the
# question the other way round -- it resolves the path through the HAL's OWN namespace with
# /proc/<pid>/root, because that is what access() means; the two must agree, and --status checks that
# they do.) This is not a partition image, not a flash, and not one of the forbidden partitions: it is
# a directory on the partition Android writes to all day long.
#
# WHICH of the two paths: /data/vendor_de/0/fpdata, the `> 27` branch -- and the reason is not what
# this file used to say. The old text here claimed biometryd's read "answers nothing for `ro.*` either",
# so `atoi("")` = 0 and the `<= 27` branch was taken *because the read is broken*. **That is false, and
# the device said so twice.** biometryd execs the UT-side /usr/bin/getprop, the v63 boot hook does
# replace that file with a shell stub -- but the stub has a `ro.build.version.sdk) printf 28` arm, and
# NO arm for `ro.product.first_api_level`. Its own fallback is therefore the only one answered:
#
#   ro.product.first_api_level -> <unset>       (the stub omits it)
#   ro.build.version.sdk       -> 28            (the stub answers it)
#   -> atoi("28") = 28 > 27, so biometryd passes /data/vendor_de/0/fpdata/
#
# Both readings are on this device, from the probe, twice: tmp-post-recovery-20260923T145530Z/
# 06-fingerprint.txt:20-23 and tmp-post-recovery-20260924T013059Z/06-fingerprint.txt:19-22 (docs 126).
# The branch is flipped by an OMISSION, not by a wrong answer: the stub answers the fallback and not
# the first choice, and the first choice is what decides.
#
# So the shipped rule is right for the right reason -- the applier RE-READS biometryd's rule at every
# boot instead of hardcoding a path, so it follows biometryd wherever the read goes, and on this device
# that is /data/vendor_de/0/fpdata (docs 97's rule: write the ONE path the rule selects). The Android
# side disagrees (vendor.img build.prop says ro.product.first_api_level=23, i.e. the `<= 27` branch),
# and the probe prints that disagreement on purpose -- biometryd never reads Android's property area,
# so Android's answer is a cross-check and not the rule. What must exist is the directory biometryd
# HANDS OVER, which is the one above. If the UT-side getprop is ever repaired to answer
# `ro.product.first_api_level` the way Android does, biometryd flips to the other path, the applier
# follows on the next boot, and --status says DISAGREE about the directory already installed -- which
# is exactly why the rule is re-read and the second directory is never created "just in case".
#
# The OTHER candidate is deliberately NOT created (docs 97): creating both leaves one directory that
# nothing will ever read and an undo line that names only one of the two. --status prints it as
# "not created, by design" so its absence is a stated decision rather than an oversight.
#
# WHAT IS *NOT* done, and why:
#   * no `restorecon` (Android calls it). It would have to run inside the container, whose SELinux
#     state this port has measured; --status prints the container's getenforce so the assumption is
#     checked rather than assumed. If it ever says Enforcing, the label matters and that is where to
#     start.
#   * no chown to a hardcoded uid. The applier reads the HAL's real uid from /proc when the HAL is
#     running and falls back to 1000 (`user system` -- what Android's own FingerprintService runs as,
#     and what the device's rc asks for), and --status prints AGREE/DISAGREE against the measured uid.
#   * NOTHING IS REPORTED AS FIXED FROM THE WRITE ALONE. `chown` to a uid that does not exist still
#     succeeds numerically, a chown the kernel refuses fails silently behind `2>/dev/null`, and
#     `access(W_OK)` is decided by what the directory SAYS, not by what was asked for. So the applier
#     stats the result and exits 1 on a mismatch -- the same lesson as the cpufreq applier (docs 95).
#   * nothing is restarted. The directory is the fix and it takes effect on biometryd's next attempt --
#     which is automatic, because the unit is `Restart=always` and the device has been retrying (docs
#     63 records `NRestarts=2`). --install prints the one command to trigger a retry if the daemon is
#     not active, instead of doing it behind the operator's back.
#
# Usage: install-fingerprint-store-dir.sh --install | --remove | --status | --explain
#
#   --install   creates the directory NOW, writes and enables the boot unit, and reports what it did
#   --remove    disables and deletes the unit and the applier; the directory is left alone (Android
#               would create it anyway) and the exact rmdir is printed
#   --status    read-only: the unit, the resolved path, the directory as the HAL sees it, the uid
#               comparison, the other candidate, and SELinux's enforce value
#   --explain   why, what it writes, what it does not, and the trade-off. Changes nothing.
#
# Env: ZL1_HOST (default root@10.15.19.82)

set -uo pipefail
DEV="${ZL1_HOST:-root@10.15.19.82}"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$DEV")
D=/etc/systemd/system
UNIT=$D/zl1-fp-store-dir.service
APPLIER=$D/zl1-fp-store-dir.sh
MNT=/var/lib/android-data
# There is deliberately NO `REL=` constant here any more. There was one -- `/system/users/0/fpdata` --
# and it was used in exactly one place, the `--remove` undo message, where it named a directory this
# device does not have: the applier DERIVES the path from biometryd's rule while the undo ASSUMED one,
# so the one instruction an operator gets for undoing the fix pointed at the other candidate. That is
# the same defect as the prose, one level worse because it is an instruction rather than a description
# (docs 126). The undo now asks the device the same question the applier does.

guard() {
  "${SSH[@]}" 'grep -qa msm8996 /proc/device-tree/compatible' 2>/dev/null ||
    { echo "not the zl1 (no msm8996 in /proc/device-tree/compatible) - refusing" >&2; exit 1; }
}

# THE RULE, ASKED OF THE DEVICE. Used everywhere this script has to NAME the path: the --install
# read-out, and the --remove undo. It is a function and not a constant because the constant was WRONG
# here -- `/system/users/0/fpdata` -- and both of those places used it. The applier derives the path
# from biometryd's rule while the host side assumed one, so on this device the operator was told to
# look at the directory nothing reads and to rmdir it (docs 126). Prints "<selected> <other>"; prints
# an empty string when the device did not answer, and callers say so rather than guessing.
read_rel() {
  "${SSH[@]}" 'G=/usr/bin/getprop
    api=$("$G" ro.product.first_api_level 2>/dev/null)
    [ -n "$api" ] || api=$("$G" ro.build.version.sdk 2>/dev/null)
    case "${api:-}" in ""|*[!0-9]*) api=0 ;; esac
    if [ "$api" -le 27 ]; then printf "/system/users/0/fpdata /vendor_de/0/fpdata"
    else printf "/vendor_de/0/fpdata /system/users/0/fpdata"; fi' 2>/dev/null | tr -d '\r\n'
}

# The read-only report. It is a remote script rather than a local summary because every number in it
# has to come from the device. No apostrophes in it: it is passed as one single-quoted local argument,
# so `\047` (octal) is used inside printf FORMATS and possessives are avoided in echo lines. Octal and
# not `\x27`: the remote shell is `sh`, which on this rootfs is dash, and dash's printf does not
# interpret `\x` -- it prints the escape itself, which is how the first version of this report ended up
# saying "lines matching \x27setActiveGroup failed\x27".
REMOTE_STATUS='
D=/etc/systemd/system
UNIT=$D/zl1-fp-store-dir.service
APPLIER=$D/zl1-fp-store-dir.sh
echo "--- the unit and its applier ---"
if [ -f "$UNIT" ]; then echo "  present: $UNIT"; else echo "  absent:  $UNIT"; fi
if [ -f "$APPLIER" ]; then echo "  present: $APPLIER"; else echo "  absent:  $APPLIER"; fi
# The only honest check that a unit is in effect is `systemctl cat` (docs 63: seventeen drop-ins
# existed and were never loaded because their directory was named <unit>.d instead of <unit>.service.d).
if systemctl cat zl1-fp-store-dir.service >/dev/null 2>&1; then
  echo "  systemctl cat zl1-fp-store-dir.service: found"
  printf "  is-enabled: %s   is-active: %s\n" \
    "$(systemctl is-enabled zl1-fp-store-dir.service 2>/dev/null)" \
    "$(systemctl is-active zl1-fp-store-dir.service 2>/dev/null)"
  printf "  Effective ordering: %s\n" "$(systemctl show zl1-fp-store-dir.service -p Before --value)"
else
  echo "  systemctl cat zl1-fp-store-dir.service: NOT FOUND - systemd does not know this unit"
fi

echo
echo "--- which of the two paths biometryd passes (its own rule, re-read here) ---"
# biometryd reads the UT-side getprop and nothing else (docs 101). These are the SAME two keys it
# reads, in the same order, and the same atoi() behaviour.
G=/usr/bin/getprop
api=
if [ -x "$G" ]; then
  api=$("$G" ro.product.first_api_level 2>/dev/null)
  [ -n "$api" ] || api=$("$G" ro.build.version.sdk 2>/dev/null)
  printf "  UT-side getprop is executable: %s\n" "$G"
  printf "    ro.product.first_api_level = \047%s\047\n" "$("$G" ro.product.first_api_level 2>/dev/null)"
  printf "    ro.build.version.sdk      = \047%s\047\n" "$("$G" ro.build.version.sdk 2>/dev/null)"
else
  echo "  the UT-side getprop $G is not executable, so the read answers nothing"
fi
case "${api:-}" in ""|*[!0-9]*) api=0 ;; esac   # atoi("") = 0 and atoi(garbage) = 0: both take <=27
if [ "$api" -le 27 ]; then
  P=/data/system/users/0/fpdata
  echo "  -> level (${api}) <= 27: biometryd passes /data/system/users/0/fpdata/"
else
  P=/data/vendor_de/0/fpdata
  echo "  -> level (${api}) > 27: biometryd passes /data/vendor_de/0/fpdata/"
fi
if [ "$P" = "/data/system/users/0/fpdata" ]; then OTHER=/data/vendor_de/0/fpdata
else OTHER=/data/system/users/0/fpdata; fi
# The HOST path of the same directory. $P is a path INSIDE Android (/data/...), and the partition is
# mounted at /var/lib/android-data, so the host path is the mount point plus the part after /data. It is
# NOT "$MNT$P" -- that would look for /var/lib/android-data/data/system/..., i.e. one `data` too many,
# and the mistake is invisible: the directory is simply never found and the report says the fix is not
# installed while it is sitting right there. (Found by scripts/host/zl1-fp-store-dir-selftest.sh, which
# noticed that --status said NEITHER exists on a device where --install had just created one.)
PH=/var/lib/android-data${P#/data}
OH=/var/lib/android-data${OTHER#/data}
# The cross-check, and the only honest one available: the applier DERIVES its path from the rule, so
# both literals are always in the file and grepping it proves nothing. What can be checked is whether
# the directory on disk is the one the rule selects -- which is also the question that matters, because
# it is the directory biometryd will pass to setActiveGroup.
if [ -d "$PH" ]; then
  echo "  AGREE: the directory the rule selects is the one on disk ($PH)"
elif [ -d "$OH" ]; then
  echo "  DISAGREE: the rule selects $P, but only $OTHER exists -- the fix was made under a different"
  echo "            answer to this rule. Re-run --install to make the selected one."
else
  echo "  NEITHER exists: the fix is not installed for either path"
fi
if [ -d "$OH" ]; then
  printf "  the other candidate DOES exist: %s\n" "$OH"
  echo "    - a directory nothing created and, on this device, nothing reads (docs 97)"
else
  printf "  the other candidate %s : not created, by design\n" "$OH"
fi

echo
echo "--- the directory, as the HAL sees it (access() means the caller namespace and uid) ---"
H=
for p in /proc/[0-9]*; do
  [ -r "$p/cmdline" ] || continue
  case "$(tr "\0" " " < "$p/cmdline" 2>/dev/null)" in
  *biometrics.fingerprint*service*) H=${p#/proc/}; break ;;
  esac
done
if [ -n "$H" ]; then
  hu=$(awk "/^Uid:/{print \$2}" "/proc/$H/status" 2>/dev/null)
  printf "  HAL: pid %s uid=%s\n" "$H" "$hu"
  # Through the HAL OWN namespace: /proc/<pid>/root/... is resolved by the target process, which is
  # the only way to ask what access() actually sees (docs 83 section 2).
  if [ -d "/proc/$H/root$P" ]; then
    printf "  /proc/%s/root%s EXISTS\n" "$H" "$P"
    ls -ld "/proc/$H/root$P" 2>/dev/null | sed "s/^/    /"
    owner=$(stat -c %u "/proc/$H/root$P" 2>/dev/null)
    if [ -n "$hu" ] && [ "$owner" = "$hu" ]; then
      echo "    AGREE: owned by the uids of the HAL itself, so access(W_OK) is the owner test"
    else
      echo "    DISAGREE: owner=$owner but the HAL runs as uid=$hu"
      echo "              (root ignores the permission bits; a non-root HAL needs owner or group to match)"
    fi
  else
    printf "  /proc/%s/root%s MISSING - this is the directory access() fails on\n" "$H" "$P"
  fi
else
  echo "  HAL: not running (no cmdline matching biometrics.fingerprint*service)"
  echo "       so the uid cannot be measured; the applier would use 1000 (user system)"
fi
if awk -v m=/var/lib/android-data "\$2==m {f=1} END{exit !f}" /proc/mounts; then
  echo "  /var/lib/android-data is mounted (the Android data partition - the same filesystem the"
  echo "  container sees as /data)"
else
  echo "  /var/lib/android-data is NOT mounted: the applier would refuse to create anything"
fi
if [ -d "$PH" ]; then
  ls -ld "$PH" 2>/dev/null | sed "s/^/  host view: /"
fi

echo
echo "--- biometryd: the caller that has been failing ---"
printf "  state: %s / %s   NRestarts: %s\n" \
  "$(systemctl show biometryd.service -p ActiveState --value 2>/dev/null)" \
  "$(systemctl show biometryd.service -p SubState --value 2>/dev/null)" \
  "$(systemctl show biometryd.service -p NRestarts --value 2>/dev/null)"
journalctl -b -u biometryd --no-pager -o cat 2>/dev/null | grep -a "setActiveGroup failed" | tail -3 | sed "s/^/    /"
printf "  lines matching \047setActiveGroup failed\047 in this boot journal: %s\n" \
  "$(journalctl -b -u biometryd --no-pager -o cat 2>/dev/null | grep -ac "setActiveGroup failed")"

echo
echo "--- SELinux in the container (the one thing a correct directory could still trip on) ---"
A=$(lxc-info -n android -pH 2>/dev/null | head -1)
if [ -n "$A" ]; then
  if nsenter -t "$A" -p -m -- /system/bin/getenforce 2>/dev/null; then
    echo "    (above: the container SELinux state)"
  else
    echo "  /system/bin/getenforce did not answer"
  fi
else
  echo "  no android container running"
fi
echo "  the applier does NOT call restorecon: it would have to run inside the container, and on this"
echo "  port the label has never been needed. If getenforce says Enforcing, read the applier header"
echo "  before trusting a directory that merely exists."
'

case "${1:-}" in
--install)
  guard
  # One ssh call per FILE, and each file arrives on STDIN. That is not a style choice: it is what keeps
  # the payload out of the transport's hands. A `cat > FILE` command is the only thing the remote shell
  # has to interpret, so the bytes that land are the bytes written here -- no quoting, no expansion, no
  # rewriting of the paths inside them. (The same property is what makes this script testable: the
  # harness maps the COMMAND and never the payload, so a landed applier still carries device paths --
  # and the harness therefore has to refuse to run it, or it would run them on the host.)
  "${SSH[@]}" "mkdir -p '$D'" >/dev/null || { echo "cannot reach $D on the device" >&2; exit 1; }
  "${SSH[@]}" "cat > '$APPLIER'" <<'APPLIER_EOF'
#!/bin/sh
# Written by scripts/install-fingerprint-store-dir.sh in the zl1 port repo. The reasoning, the four
# sources it comes from and the measurements behind it are in that script's header and docs 83/97/101.
#
# Android system_server creates /data/system/users/0/fpdata before it calls setActiveGroup
# (FingerprintService.updateActiveGroup: fpDir.mkdir() + restorecon). This port has no system_server,
# so nobody does, and the HAL's silent `access(W_OK)` branch returns SYS_EINVAL. This applier is that
# one missing step, and it is deliberately the narrowest version of it:
#
#   * the path follows the biometryd OWN rule, re-read every boot (its rule, not a guess -- docs 101):
#     the UT-side getprop, atoi() of ro.product.first_api_level or ro.build.version.sdk, and <= 27
#     means /data/system/users/0/fpdata, else /data/vendor_de/0/fpdata. Nothing else is ever created
#     (docs 97). WHICH branch is not a property of the port but of what that stub answers TODAY, and
#     on this device the answer is 28 (it omits the first choice and answers the fallback), so the
#     path is the '> 27' one -- docs 126. That is why this is computed and printed rather than
#     written down here: a comment cannot follow the device, and a hardcoded path would silently stop
#     being the directory the HAL is handed.
#   * the owner follows the HAL real uid when the HAL is running, else 1000 (user system, which is both
#     what the Android FingerprintService runs as and what the device rc asks for).
#   * it is idempotent, and it repairs a WRONG owner as well as a missing directory: "it exists, so do
#     nothing" would leave a half-created directory wrong forever.
#   * it REFUSES to create anything if the Android data partition is not mounted, so it can never
#     quietly create the directory on the read-only rootfs instead.
#   * it reads back what the directory says and FAILS if that is not what access(W_OK) needs, because
#     every one of these writes can fail silently (a chown the kernel refuses, a uid that does not
#     exist, an immutable attribute) and a directory that merely exists is not a fix.
#   * it does not call restorecon (see the installer header), and it does not restart anything.

set -u
MNT=/var/lib/android-data
G=/usr/bin/getprop

log() { echo "zl1-fp-store-dir: $*" ; }

# --- the path, by the rule biometryd itself applies -------------------------------------------------
api=
if [ -x "$G" ]; then
  api=$("$G" ro.product.first_api_level 2>/dev/null)
  [ -n "$api" ] || api=$("$G" ro.build.version.sdk 2>/dev/null)
fi
case "${api:-}" in
""|*[!0-9]*) api=0 ;;   # atoi("") = 0 and atoi(garbage) = 0: biometryd takes <= 27 for both
esac
if [ "$api" -le 27 ]; then
  REL=/system/users/0/fpdata
  why="api_level ${api} <= 27"
else
  REL=/vendor_de/0/fpdata
  why="api_level ${api} > 27"
fi
D=$MNT$REL

# --- the partition ---------------------------------------------------------------------------------
# access() has to be an answer about the Android data filesystem. If it is not mounted, the directory
# would land on the read-only rootfs and every later check would be a lie about a mount point.
if ! awk -v m="$MNT" '$2==m {f=1} END{exit !f}' /proc/mounts; then
  log "REFUSING: $MNT is not mounted, so $D would not be the Android data partition"
  exit 1
fi

# --- the owner: the HAL own uid if it is running, else the Android system uid ----------------------
uid=1000
src="fallback (the HAL is not running yet)"
for p in /proc/[0-9]*; do
  [ -r "$p/cmdline" ] || continue
  case "$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)" in
  *biometrics.fingerprint*service*)
    u=$(awk '/^Uid:/{print $2}' "$p/status" 2>/dev/null)
    case "${u:-}" in ""|*[!0-9]*) ;; *) uid=$u; src="the HAL process ${p#/proc/}" ;; esac
    break ;;
  esac
done

# --- create, or repair -----------------------------------------------------------------------------
before=$(ls -ld "$D" 2>/dev/null | awk '{print $1" "$3":"$4}')
mkdir -p "$D" || { log "FAILED: mkdir -p $D"; exit 1; }
chown "$uid:$uid" "$D" 2>/dev/null
chmod 0770 "$D" 2>/dev/null
after=$(ls -ld "$D" 2>/dev/null | awk '{print $1" "$3":"$4}')
if [ -z "$before" ]; then
  log "created  $REL  ($why; asked for owner $uid:$uid from $src) -> $after"
else
  log "checked  $REL  ($why; asked for owner $uid:$uid from $src) -> $after"
  # chown to a uid nobody has still succeeds numerically, so "we asked for it" is not "it is that".
  [ "$before" = "$after" ] || log "REPAIRED: it was $before, which is why access(W_OK) failed"
fi

# --- the read-back: what access(W_OK) will actually see --------------------------------------------
nowuid=$(stat -c %u "$D" 2>/dev/null)
nowmod=$(stat -c %a "$D" 2>/dev/null)
if [ "$nowuid" = "$uid" ] && [ "$nowmod" = 770 ]; then
  log "read back: uid=$nowuid mode=$nowmod - access(W_OK) for a caller at uid $uid"
  exit 0
fi
log "MISMATCH: $D is uid=${nowuid:-?} mode=${nowmod:-?}, not $uid/770 -- access(W_OK) may still fail"
log "          the directory EXISTS but this is NOT the fix; nothing else was attempted"
exit 1
APPLIER_EOF
  "${SSH[@]}" "chmod 0755 '$APPLIER'" >/dev/null || { echo "cannot chmod the applier" >&2; exit 1; }
  echo "  wrote $APPLIER"

  "${SSH[@]}" "cat > '$UNIT'" <<'UNIT_EOF'
[Unit]
Description=Create the Android fingerprint store directory (the step system_server would do)
Documentation=file:///etc/systemd/system/zl1-fp-store-dir.sh
# Android data partition first: RequiresMountsFor both orders this after its mount unit and binds this
# unit's life to it. After=lxc-android-config.service is the port's own "the container configuration is
# in place" point, and it already orders transitively after mount-android-partitions.service.
RequiresMountsFor=/var/lib/android-data
After=lxc-android-config.service
# biometryd is what calls setActiveGroup at startup, so the directory has to exist before it does. The
# applier is idempotent, so starting late is a repair rather than a missed window.
Before=biometryd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh /etc/systemd/system/zl1-fp-store-dir.sh

[Install]
WantedBy=multi-user.target
UNIT_EOF
  echo "  wrote $UNIT"

  "${SSH[@]}" "systemctl daemon-reload" >/dev/null
  "${SSH[@]}" "systemctl enable zl1-fp-store-dir.service" >/dev/null 2>&1
  echo "  enabled zl1-fp-store-dir.service"
  # `systemctl cat`, not `is-enabled`: docs 63 (seventeen drop-ins existed and were never loaded).
  # A unit systemd cannot read is not installed, however willing the file on disk looks.
  if "${SSH[@]}" "systemctl cat zl1-fp-store-dir.service" >/dev/null 2>&1; then
    echo "  systemctl cat zl1-fp-store-dir.service: found (systemd can read it)"
  else
    echo "  systemctl cat zl1-fp-store-dir.service: NOT FOUND -- systemd cannot see the unit" >&2
  fi

  # Run it now: the fix belongs on THIS boot too, and the applier's own output is the evidence -- what
  # it found, what it asked for, and what the directory reads back as.
  echo
  echo "--- running it now ---"
  arc=0
  applier_out=$("${SSH[@]}" "/bin/sh '$APPLIER'" 2>&1) || arc=$?
  printf '%s\n' "$applier_out" | sed 's/^/  /'
  _rel=$(read_rel); REL=${_rel%% *}; OTHER=${_rel#* }
  if [ -n "$REL" ] && [ -n "$OTHER" ]; then
    "${SSH[@]}" "for p in $MNT$REL $MNT$OTHER; do
      printf \"    %s: \" \"\$p\"
      ls -ld \"\$p\" 2>/dev/null || echo \"absent (and must stay absent unless it is the selected path)\"
    done"
  else
    echo "    (the device did not answer the path rule, so neither candidate can be named here;" >&2
    echo "     read scripts/device/zl1-fingerprint-probe.sh section 2 rather than guessing)" >&2
  fi
  echo
  if [ "$arc" != 0 ]; then
    {
      echo "THE APPLIER EXITED $arc -- the directory is not usable as it stands. Its own MISMATCH line"
      echo "says which of the two it is; do not report the fingerprint fixed until it exits 0."
    } >&2
  else
    echo "The directory is in place and reads back as the owner biometryd will pass to setActiveGroup."
    echo
    echo "Next, on THIS boot only (from the next boot the unit does it before biometryd starts):"
    echo "  biometryd is Restart=always and has been retrying, so it may already have picked the"
    echo "  directory up. If it is not active, a retry takes one command:"
    echo "      ssh $DEV 'systemctl start biometryd.service'"
    echo "  Then the three lines that say whether it worked:"
    echo "      ssh $DEV 'systemctl status biometryd.service --no-pager | head -12'"
    echo "      ssh $DEV 'journalctl -b -u biometryd --no-pager -o cat | grep -c \"setActiveGroup failed\"'   # want 0"
    echo "      ssh $DEV 'journalctl -b -u biometryd --no-pager -o cat | tail -20'"
    echo "  and the probe, which is the instrument for the rest of the chain (docs 103):"
    echo "      scp scripts/device/zl1-fingerprint-probe.sh $DEV:/tmp/ && \\"
    echo "        ssh $DEV 'sh /tmp/zl1-fingerprint-probe.sh'"
  fi
  ;;
--remove)
  guard
  "${SSH[@]}" "systemctl disable --now zl1-fp-store-dir.service" >/dev/null 2>&1
  # Delete exactly its own three paths, and name each one rather than globbing: a glob here would be a
  # way to delete a file this script never wrote.
  for f in "$UNIT" "$APPLIER" "$D/multi-user.target.wants/zl1-fp-store-dir.service"; do
    "${SSH[@]}" "rm -f '$f'"
    case "$("${SSH[@]}" "[ -e '$f' ] && echo yes || echo no")" in
    yes) echo "  COULD NOT REMOVE $f (it is still there)" >&2 ;;
    *)   echo "  removed $f" ;;
    esac
  done
  "${SSH[@]}" "systemctl daemon-reload" >/dev/null
  # The directory is LEFT ALONE, deliberately: real Android creates it too, so removing it would not
  # restore any shipped state -- and on a device where the fix works, deleting it would break the
  # fingerprint again while looking like a clean revert. The exact undo is printed instead, with the
  # emptiness check that has to come first.
  echo "  the directory was NOT removed. To undo that too:"
  # READ the path, do not assume it: the same rule the applier runs, asked of the same device, so the
  # undo cannot name the other candidate. (It did, until 2026-09-24 -- docs 126.)
  _rel=$(read_rel); REL=${_rel%% *}; OTHER=${_rel#* }
  case "$REL" in
  /system/users/0/fpdata|/vendor_de/0/fpdata)
    echo "      ssh $DEV 'ls -A $MNT$REL'    # must print nothing first: an empty directory is the only"
    echo "      ssh $DEV 'rmdir $MNT$REL'    # thing this installer can be said to have created" ;;
  *)
    echo "      (the device did not answer the path rule, so this cannot name the directory: read it"
    echo "       with scripts/device/zl1-fingerprint-probe.sh section 2 rather than guessing)" ;;
  esac
  ;;
--status)
  guard
  "${SSH[@]}" "$REMOTE_STATUS"
  ;;
--explain)
  cat <<'TXT'
What this fixes
  `setActiveGroup failed: SYS_EINVAL` from biometryd. The HAL returns it from a branch that logs
  nothing, and the branch it returns it from is `access(storePath, W_OK)` -- so the directory biometryd
  passes does not exist. On real Android it exists because `system_server` makes it
  (FingerprintService.updateActiveGroup: fpDir.mkdir() + restorecon, and it returns WITHOUT calling
  setActiveGroup when mkdir fails). This port has no system_server, biometryd has no mkdir, and the
  device rc files have none: nobody makes it. docs 83.

What it writes
  ONCE, IMMEDIATELY:  the directory biometryd's OWN rule selects -- on this device that is
                      /var/lib/android-data/vendor_de/0/fpdata, which IS the Android
                      /data/vendor_de/0/fpdata (see below), mode 0770, owner the HAL's real uid if
                      the HAL is running, else 1000 (`user system`). It is NOT hardcoded: the applier
                      re-reads the rule every boot, and --status prints the level and the path it
                      chose. (This text said /data/system/users/0/fpdata until 2026-09-24. The device
                      says the UT getprop answers ro.build.version.sdk = 28 and omits
                      ro.product.first_api_level, so biometryd takes the `> 27` branch; see the header
                      and docs 126.)
  PERSISTENTLY:       /etc/systemd/system/zl1-fp-store-dir.sh      the applier
                      /etc/systemd/system/zl1-fp-store-dir.service the oneshot unit: enabled, ordered
                                                                     after the Android data mount and
                                                                     before biometryd
  Both files are on /etc/systemd/system, the writable bind mount; /etc itself is a read-only image.

Why the host path is the right one
  /dev/sda10[/android-data] is an ordinary rw ext4, mounted at /var/lib/android-data and bind-mounted
  to /android/data, which is the container's /data. Same filesystem, so no nsenter is involved, it
  works when the container is down, and the container's mount namespace cannot confuse it. It is not a
  partition image, not a flash, and not one of the forbidden partitions.

What it deliberately does NOT do
  * the OTHER candidate -- /data/system/users/0/fpdata here, and the answer flips with the rule:
    creating both leaves a directory nothing reads and an undo that names only one of them (docs 97).
    The applier follows biometryd's rule, and on this port that rule resolves with the UT-side v63
    STUB's answers: it omits `ro.product.first_api_level` and answers `ro.build.version.sdk` = 28, so
    atoi("28") = 28 > 27 and the path is /data/vendor_de/0/fpdata (docs 126; the stub does NOT answer
    nothing -- the fallback is answered even though the first choice is not). --status re-reads that
    rule every time and says DISAGREE if the installed directory is the other one.
  * restorecon (Android calls it). It would have to run inside the container; --status prints the
    container's getenforce so the assumption is checked rather than assumed.
  * report success from the write alone. The applier stats the directory afterwards and exits 1 on a
    mismatch, because every step can fail silently and `access(W_OK)` is decided by what the directory
    says, not by what was asked for (the cpufreq applier's lesson, docs 95).
  * anything to any other partition, any flash, any QDL/firehose step, and any restart of a service.

The trade-off, stated
  It is a workaround for a missing `system_server`, so it is one more piece of port state that a real
  Halium fix would make unnecessary -- and if the port ever grows a proper fingerprint stack, this unit
  should be removed rather than kept "because it works". --remove does that; the directory is left
  behind on purpose, because Android creates it too and deleting it would break the fingerprint again
  while looking like a clean revert.
TXT
  ;;
--help|-h)
  # The header, whatever its current length: lines 2..the end of the leading comment block. NOT a fixed
  # line range -- a range silently truncates the usage text every time the header grows, which is a
  # defect this project has already shipped twice (docs 104, install-kmsg-drain.sh).
  awk 'NR==1{next} /^#/{print; next} {exit}' "$0"; exit 0;;
*)
  echo "unknown argument ${1:-} (try --help)" >&2; exit 2;;
esac
