#!/bin/sh
# zl1 fingerprint probe -- why does setActiveGroup return SYS_EINVAL? Read-only by default.
#
# The answer is structural, and it is in the source rather than in the log (docs/ubuntu-touch/83):
#
#   In Android, /data/system/users/<id>/fpdata is created by **system_server**, not by the HAL.
#   frameworks/base/.../fingerprint/FingerprintService.java:1605-1620 does
#       File fpDir = new File(Environment.getUserSystemDirectory(userId), "fpdata");
#       if (!fpDir.exists()) { if (!fpDir.mkdir()) { Slog.v(...); return; } SELinux.restorecon(fpDir); }
#       daemon.setActiveGroup(userId, fpDir.getAbsolutePath());
#   -- and it only ever runs at all when the active user *changes* (`if (userId != mCurrentUserId)`).
#
#   This port has no system_server, so nothing creates that directory. biometryd calls the HAL
#   directly with the same path the framework would have used
#   (halium/biometryd/src/biometry/devices/android.cpp:590-598):
#       api_level = get("ro.product.first_api_level") ?: get("ro.build.version.sdk")
#       if (atoi(api_level) <= 27)  "/data/system/users/0/fpdata/"
#       else                        "/data/vendor_de/0/fpdata/"
#
#   And the HAL checks it before doing anything else
#   (device/leeco/zl1/biometrics/BiometricsFingerprint.cpp:215-228):
#       if (storePath.size() >= PATH_MAX || <= 0) { ALOGE("Bad path length"); return SYS_EINVAL; }
#       if (access(storePath.c_str(), W_OK)) { return SYS_EINVAL; }     <-- NO LOG AT ALL
#
#   The silent branch is the one that matters: it is why the device log shows the *caller's*
#   "setActiveGroup failed: SYS_EINVAL" and nothing from the HAL, and it makes this a one-line
#   question -- does that path exist and is it writable **as the HAL process sees it**?
#
# `access()` is evaluated in the HAL's own mount namespace and with its own real uid, so the one
# honest check is /proc/<hal-pid>/root/... (that path is resolved through the target's namespace),
# plus its uid from /proc/<hal-pid>/status. Not the host's view, not guesswork about namespace flags.
#
# Nothing here writes. `--create-store-dir` is off by default and is the only thing that would: it
# creates exactly the directory Android's own FingerprintService creates -- the ONE path section 2
# determined biometryd passes, not both candidates, and it prints the rmdir undo for that path. It is a
# directory in Android's own /data (= /android/data, /dev/sda10[/android-data], a rw ext4 that Android
# writes to normally) -- it is not a partition image, not one of the forbidden partitions, and not a
# flash. (Before docs 97 it created both candidates and printed an undo for one of them.)
#
# Usage (on the device, as root): zl1-fingerprint-probe.sh [--create-store-dir] [--quiet]

set -u

CREATE=0
QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
  --create-store-dir) CREATE=1; shift ;;
  --quiet) QUIET=1; shift ;;
  --help|-h) sed -n '2,40p' "$0"; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

grep -qa msm8996 /proc/device-tree/compatible 2>/dev/null ||
  { echo "not the zl1 (no msm8996 in /proc/device-tree/compatible) -- refusing" >&2; exit 1; }

A=$(lxc-info -n android -pH 2>/dev/null | head -1)

echo "zl1 fingerprint probe :: $(date) :: read-only$([ "$CREATE" = 1 ] && echo ' EXCEPT --create-store-dir')"

# --- 1. the HAL process, and the path as IT sees it --------------------------------------------

# The service is vendor.hal.fingerprint@2.0 (service.cpp) and its process name is the vendor binary;
# match on the HIDL interface name in the command line instead of guessing the comm truncation.
hal_pid() {
  for p in /proc/[0-9]*; do
    [ -r "$p/cmdline" ] || continue
    c=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
    case "$c" in *biometrics.fingerprint*service*) printf '%s\n' "${p#/proc/}"; return ;; esac
  done
}

H=$(hal_pid)
if [ -z "$H" ]; then
  echo "== HAL: not running (no cmdline matching biometrics.fingerprint*service)"
  echo "   check the container's init for it:"
  [ -n "$A" ] && nsenter -t "$A" -p -- ps -eo pid,user,comm 2>/dev/null | grep -ai "finger\|fpd" | sed 's/^/   | /'
else
  uid=$(awk '/^Uid:/{print $2}' "/proc/$H/status" 2>/dev/null)
  gid=$(awk '/^Gid:/{print $2}' "/proc/$H/status" 2>/dev/null)
  echo "== HAL: pid $H  uid=$uid gid=$gid  ns/pid $(readlink /proc/$H/ns/pid 2>/dev/null)  ns/mnt $(readlink /proc/$H/ns/mnt 2>/dev/null)"
  echo "   cmdline: $(tr '\0' ' ' < /proc/$H/cmdline 2>/dev/null | cut -c1-120)"
  if [ -n "$A" ]; then
    echo "   container pid $A ns/mnt $(readlink /proc/$A/ns/mnt 2>/dev/null)"
    if [ "$(readlink /proc/$H/ns/mnt 2>/dev/null)" = "$(readlink /proc/$A/ns/mnt 2>/dev/null)" ]; then
      echo "   -> same mount namespace as the container (so /data means the container's /data)"
    else
      echo "   -> a DIFFERENT mount namespace from the container: /data may not be what this script thinks"
    fi
  fi

  # ---- the decisive check: resolve the store paths through the HAL's own namespace ----
  echo "== the store paths, resolved through the HAL's own mount namespace (/proc/$H/root/...)"
  for p in /data/system/users/0/fpdata /data/vendor_de/0/fpdata /data/vendor/biometrics; do
    t="/proc/$H/root$p"
    if [ -e "$t" ]; then
      ls -ldn "$t" 2>/dev/null | awk '{ printf "   EXISTS   %-34s mode=%-11s uid=%s gid=%s\n", $NF, $1, $3, $4 }'
    else
      echo "   MISSING  $p"
    fi
  done
  echo "   (access(W_OK) with uid=$uid decides: MISSING -> ENOENT -> SYS_EINVAL;"
  echo "    EXISTS but not writable by $uid -> EACCES -> SYS_EINVAL. Both are silent in the HAL.)"
  if [ -e "/proc/$H/root/data/system/users/0" ]; then
    echo "   the parent, for reference:"
    ls -ldn "/proc/$H/root/data/system/users/0" 2>/dev/null | awk '{ printf "   %-34s mode=%-11s uid=%s gid=%s\n", $NF, $1, $3, $4 }'
  fi
  [ "$QUIET" = 1 ] || echo "   open fds that look like the fingerprint device:" && \
    ls -l "/proc/$H/fd" 2>/dev/null | grep -aiE "goodix|fpc|tty|fp" | sed 's/^/   | /'

  # Can the HAL even write there, tested without creating anything: the parent's mode bits.
  if [ -e "/proc/$H/root/data/system/users/0" ]; then
    echo "   writable-by-that-uid test on the parent (uses a bind-free probe: touch would write, so this"
    echo "   only reports the mode bits and the owner):"
    ls -ldn "/proc/$H/root/data/system/users/0" 2>/dev/null | sed 's/^/   | /'
  fi
fi

# --- 2. which path biometryd will pass ---------------------------------------------------------

# TARGET is the single path this run decided on, and section 5 writes only that one. It used to write
# BOTH candidates while printing an undo for one of them, in a script whose entire point is that the
# two paths are different answers: creating /data/vendor_de/0/fpdata on a device whose api_level says
# the <=27 branch is a write that nothing will ever read, and its undo was not even printed -- so the
# one thing this script is allowed to write could leave something behind that no line of output
# mentioned. Deciding it here means section 5 cannot disagree with section 2 (docs 97).
TARGET=""
echo "== which of the two paths biometryd passes (its own rule: api_level <= 27 -> /data/system/users/0)"
if [ -n "$A" ]; then
  # Read the properties INSIDE the container: the host's getprop is a stub (docs 50).
  fal=$(nsenter -t "$A" -p -- /system/bin/getprop ro.product.first_api_level 2>/dev/null | tr -d '\r')
  sdk=$(nsenter -t "$A" -p -- /system/bin/getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')
  lvl=${fal:-$sdk}
  printf '   ro.product.first_api_level = %s\n   ro.build.version.sdk      = %s\n' "${fal:-<unset>}" "${sdk:-<unset>}"
  case "$lvl" in
    ''|*[!0-9]*) echo "   -> both unset/garbage: atoi(\"\")=0, so biometryd takes the <=27 branch: /data/system/users/0/fpdata/"
                 TARGET=/data/system/users/0/fpdata ;;
    *) if [ "$lvl" -le 27 ] 2>/dev/null; then
         echo "   -> level $lvl <= 27: biometryd passes /data/system/users/0/fpdata/"
         TARGET=/data/system/users/0/fpdata
       else
         echo "   -> level $lvl > 27: biometryd passes /data/vendor_de/0/fpdata/  (check THAT one above)"
         TARGET=/data/vendor_de/0/fpdata
       fi ;;
  esac
else
  echo "   (no container)"
fi

# --- 3. logcat: whose message is missing -------------------------------------------------------

echo "== container logcat counts (the HAL's silent branch is the point -- a missing line is evidence)"
if [ -n "$A" ]; then
  dump=$(nsenter -t "$A" -p -m -- /system/bin/logcat -d -v brief 2>/dev/null)
  for pat in 'setActiveGroup failed' \
             'Bad path length' \
             'Unable to get FP service' \
             'Connected to IBiometricsFingerprint' \
             'Unable to get IBiometricsFingerprint' \
             'Opening fingerprint hal library' \
             'Can not open fingerprint HW Module' \
             'Start biometrics' \
             'Can not create instance of BiometricsFingerprint' \
             'android.hardware.biometrics.fingerprint@2.1-service' ; do
    printf '   %-52s %s\n' "$pat" "$(printf '%s\n' "$dump" | grep -ac "$pat")"
  done
  echo "   -- 'Bad path length' = 0 while 'setActiveGroup failed' > 0 means the access() branch,"
  echo "      which logs NOTHING (BiometricsFingerprint.cpp:221-223)."
  echo "   -- 'Start biometrics' is an ALOGE in service.cpp, so it always lands in logcat: it means"
  echo "      openHal() got as far as registering the HIDL service, which puts the failure after open."
  echo "   -- the last 10 lines mentioning finger/biometric:"
  printf '%s\n' "$dump" | grep -aiE 'finger|biometric|fp_|goodix' | tail -10 | cut -c1-150 | sed 's/^/   | /'
else
  echo "   (no container: lxc-info gave nothing)"
fi

# --- 4. the HIDL service and the device node ---------------------------------------------------

echo "== HIDL registration (lshal needs nsenter -p -m)"
if [ -n "$A" ]; then
  nsenter -t "$A" -p -m -- lshal 2>/dev/null | grep -ai 'fingerprint' | sed 's/^/   /'
  n=$(nsenter -t "$A" -p -m -- lshal 2>/dev/null | grep -aci 'fingerprint')
  [ "$n" -gt 0 ] || echo "   (no fingerprint service registered)"
fi

echo "== the fingerprint device node(s)"
for d in /dev/goodix_fp /dev/qseecom /sys/devices/soc/soc:fpc_fpc1020; do
  [ -e "$d" ] && ls -ld "$d" 2>/dev/null | sed 's/^/   /' || echo "   MISSING $d"
done

echo "== SELinux (if it is enforcing, a newly created directory needs the right label)"
for f in /sys/fs/selinux/enforce /sys/fs/selinux/mls; do
  [ -r "$f" ] && printf '   %-26s %s\n' "$f" "$(cat "$f" 2>/dev/null)" || echo "   $f unreadable/absent"
done

# --- 5. the one write, only when asked ---------------------------------------------------------

if [ "$CREATE" = 1 ]; then
  echo
  echo "== --create-store-dir: creating the directory Android's own FingerprintService would create"
  if [ -z "$A" ] || [ -z "$H" ]; then
    echo "   aborted: need both a container and a running HAL (to learn the uid it must be writable by)"
    exit 1
  fi
  if [ -z "$TARGET" ]; then
    echo "   aborted: section 2 could not decide which of the two paths biometryd passes, so there is no"
    echo "   single directory to create. Creating both would be a write nothing reads -- run section 2's"
    echo "   properties by hand first."
    exit 1
  fi
  uid=$(awk '/^Uid:/{print $2}' "/proc/$H/status" 2>/dev/null)
  gid=$(awk '/^Gid:/{print $2}' "/proc/$H/status" 2>/dev/null)
  case "$TARGET" in
  /data/system/users/0/fpdata) OTHER=/data/vendor_de/0/fpdata ;;
  *)                           OTHER=/data/system/users/0/fpdata ;;
  esac
  # Through the container's namespace: nsenter -m makes /data mean the container's /data.
  if nsenter -t "$A" -m -- test -e "$TARGET"; then
    echo "   exists already: $TARGET"
    nsenter -t "$A" -m -- ls -ldn "$TARGET" 2>/dev/null | sed 's/^/   /'
  else
    nsenter -t "$A" -m -- mkdir -p "$TARGET" && echo "   created $TARGET"
    # chown only if the HAL is not root: root can write anything, so the mode is then irrelevant.
    if [ -n "$uid" ] && [ "$uid" != 0 ]; then
      nsenter -t "$A" -m -- chown "$uid:$gid" "$TARGET" 2>/dev/null && echo "   chown $uid:$gid $TARGET"
      nsenter -t "$A" -m -- chmod 0700 "$TARGET" 2>/dev/null && echo "   chmod 0700 $TARGET"
    fi
    nsenter -t "$A" -m -- ls -ldn "$TARGET" 2>/dev/null | sed 's/^/   now: /'
  fi
  echo "   NOT created: $OTHER (section 2 says biometryd passes $TARGET, so nothing would ever read the"
  echo "   other one; if the evidence later contradicts section 2, make it by hand:"
  echo "     nsenter -t $A -m -- mkdir -p $OTHER"
  echo "   UNDO: nsenter -t $A -m -- rmdir $TARGET   (only if it is still empty)"
  echo "   then restart whatever reports the failure and re-read the logcat counts above."
fi
