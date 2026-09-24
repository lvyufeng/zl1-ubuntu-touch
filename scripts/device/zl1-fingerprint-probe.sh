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
#   **And `get` is `core::posix::exec("/usr/bin/getprop", {key}, ...)`**
#   (halium/biometryd/src/biometry/util/property_store.cpp:26) -- an ABSOLUTE path to the *UT-side*
#   binary, which the v63 boot hook replaces with a /bin/sh stub on every boot (docs 50, 93). So
#   biometryd's api_level is always "", atoi("")=0, and it takes the <=27 branch because its property
#   read is broken -- not because of what the device reports. Section 2 reads biometryd's own path
#   and then cross-checks it against the container's properties, because the two can disagree:
#   the vendor.img build.prop in the 2026-06-07 backup set says ro.product.first_api_level=23, which
#   happens to be the same branch. Two independent readings agreeing is what makes the write safe.
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
# The log has two halves, and section 4 counts each string in the one its owner writes to (docs 103):
# the caller's "setActiveGroup failed" is **biometryd's**, and biometryd is a UT-side service, so that
# line goes to ITS journal -- not to the container's logcat, where a HAL whose access() branch logs
# nothing has nothing to say. Reading the caller's line out of logcat made the pair the header asks
# the reader to compare impossible to satisfy. The evidence for every owner is in
# docs/ubuntu-touch/evidence/fp-log-owners-2026-09-23.log.
#
# Nothing here writes unless asked. `--create-store-dir` is off by default and is the only thing that
# would: it
# creates exactly the directory Android's own FingerprintService creates -- the ONE path section 2
# determined biometryd passes, not both candidates, and it prints the rmdir undo for that path. It is a
# directory in Android's own /data (= /android/data, /dev/sda10[/android-data], a rw ext4 that Android
# writes to normally) -- it is not a partition image, not one of the forbidden partitions, and not a
# flash. (Before docs 97 it created both candidates and printed an undo for one of them.)
#
# The write mode's guard used to be unanswerable, and this is the one place where those nine `nsenter`
# failures had a WRITE behind them (docs 117): `[ -e ]` was `nsenter -m -- test -e`, `test` is not in
# the container's /bin, so it answered "missing" every time and the create branch was always taken --
# and `mkdir`/`chown`/`chmod` ARE in that /bin, so on a device the mode would have created the
# directory and chowned it, and printed "now: <the right mode>". It would have looked correct while
# its "exists already" branch was dead code. Everything is read through /proc/<pid>/root now, so the
# guard answers, and it says "exists already" instead of re-creating.
#
# Usage (on the device, as root): zl1-fingerprint-probe.sh [--create-store-dir] [--quiet]

set -u

CREATE=0
QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
  --create-store-dir) CREATE=1; shift ;;
  --quiet) QUIET=1; shift ;;
  # The header is lines 1-56 (Usage is the last of them); line 58 is `set -u`. The range used to stop
  # at 40, i.e. short of the Usage line it exists to print. scripts/host/zl1-loc-fp-selftest.sh now
  # asserts both halves of that -- the usage block IS printed, and no `set -u` is -- because a line
  # number drifts with the header and only the negative assertion can see the other direction.
  --help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0" ; exit 0 ;;
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

# --- the one honest way to read a path through the HAL's mount namespace -------------------------
#
# `nsenter -t PID -m` switches the mount namespace and THEN execs, so a bare command name is resolved
# through the CONTAINER's mount table -- where the UT rootfs's /usr/bin does not exist. The device said
# so out loud on 2026-09-24: `nsenter: failed to execute test: No such file or directory`, nine times,
# once per (variant x directory) in section 2. exec failure is exit 127, which the shell reads as
# FALSE -- so an existence test that COULD NOT RUN was reported as "does not exist", and section 2
# concluded "no variant match; AOSP would fall back to fingerprint.default.so" without having looked
# at anything. That is the defect this file already hunts for one level up (docs 103, 109): an
# instrument that cannot report, printing a definite answer. (lshal and logcat keep working for the
# reverse reason: the container's applet set is Android's own, which has both -- but logcat is reached
# by ABSOLUTE path (/system/bin/logcat, and its counts are on the record from a live run on
# 2026-09-23) while `lshal` is not, so `lshal` is the one that could fail this way. Both need `-p`/`-m`
# for binder, so they stay as they are, and `ns_run` below is what makes their failure visible.)
#
# `/proc/<pid>/root/<abs path>` needs none of that: the KERNEL resolves the path through the target's
# mount namespace and root, and the tool doing the reading (`ls`, `[ -e ]`) is the HOST's own. It is
# the same mechanism section 1 has always used for the store paths, and the only one whose answer
# means what it says. `$H` and `$A` are the same mount namespace (section 1 prints both), and the HAL
# is the process whose own access() decides the question, so the pid used here is the HAL's.
halpath() { # $1 = a path as the CONTAINER sees it; prints the path to read it from HERE
  if [ -n "$H" ]; then printf '/proc/%s/root%s' "$H" "$1"; else printf '%s' "$1"; fi
}
#
# Why the nine failures were the `test` ones and not, say, the `ls` ones (docs 117): the search uses
# the caller's PATH -- /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin (the UT rootfs's
# /etc/environment) -- and with `-m` those names are looked up in the CONTAINER's tree. The answer is
# per-APPLET, and it is a fact about the image, not about namespaces: measured against the system
# partition this device runs (the 2026-06-07 staged system.img; the halium candidate image agrees),
# the applet directory has ls, mkdir, chown, chmod, ps, rmdir, grep, awk, sed, tr, lshal, logcat,
# service, getprop -- and **no `test` and no `[`**, because mksh provides `test` as a shell BUILTIN and
# toybox's applet is not installed. That is the whole difference: `test -e` could not run, `ls -l`
# could. (Which directory the container's PATH search lands in -- /bin, or /system/bin if the container
# root spells it that way -- does not change this: both are the same image, and that image has no
# `test` in either.) It also means the ONE write mode's guard was the only broken part:
# `nsenter -m -- mkdir -p` WOULD have run, so that `[ -e ]` never protected anything and always took
# the "it is missing, create it" branch (see the note above Usage).
#
# --- and the rule that replaces it, for the calls that must still use nsenter --------------------
#
# A command that cannot run and a command that found nothing produce the SAME empty string, and on
# this device both are reachable. Where the emptiness is read as a finding -- `service list`, logcat,
# lshal -- it must therefore be split. `nsenter` prints `nsenter: failed to execute <cmd>: No such
# file or directory` and exits 127 in that case, so:
ns_run() { # $1 = nsenter flags (e.g. '-p -m'); $2... = the command, as the CONTAINER resolves it
           # Prints its output, and -- when nsenter could not exec the command -- a line
           #     NSENTER-EXEC-FAIL: nsenter: failed to execute <cmd>: No such file or directory
           # INSTEAD of whatever empty output that would otherwise be read as a finding.
           #
           # The marker is printed into the OUTPUT rather than set in a variable, and that is not a
           # style choice: every one of these calls is `x=$(ns_run ...)`, a command substitution is a
           # SUBSHELL, and a variable ns_run sets is lost the moment the substitution ends. (Measured:
           # the first version set NS_FAIL and the probe died three sections later on `NS_FAIL:
           # parameter not set`, which is at least a loud way to find out.) The caller tests the
           # captured text:
           #     case "$out" in *NSENTER-EXEC-FAIL:*) ... ;; esac
  ns_flags=$1; shift
  ns_body=$(nsenter -t "$A" $ns_flags -- "$@" 2>&1)
  case "$ns_body" in
  *"nsenter: failed to execute "*)
    printf 'NSENTER-EXEC-FAIL: %s\n' "$(printf '%s\n' "$ns_body" | grep -a 'failed to execute' | head -1)" ;;
  esac
  printf '%s\n' "$ns_body" | grep -av '^nsenter: failed to execute'
}

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
# **Read what biometryd reads, not what the device knows.** biometryd does not query the Android
# property area: it shells out to an ABSOLUTE path on the UT side
# (halium/biometryd src/biometry/util/property_store.cpp:26)
#
#     core::posix::exec("/usr/bin/getprop", {key}, {}, core::posix::StandardStream::stdout)
#
# and on this port /usr/bin/getprop is the v63 boot hook's /bin/sh stub (docs 50/93). So both
# properties come back empty, api_level stays "", atoi("") is 0, and the <=27 branch is taken -- for
# a reason that has nothing to do with what the device reports.
#
# That matters here because this section decides the ONE path section 5 is allowed to create. The
# earlier version read the *container's* /system/bin/getprop, which is NOT what biometryd reads: on a
# device whose first_api_level were >27 and whose UT getprop worked, biometryd would take the >27
# branch while that version still answered from the container's value -- the wrong path, stated with
# full confidence. So: read biometryd's own source of truth, then cross-check it against the device's
# Android properties, and print the disagreement when there is one, because on this port the
# disagreement is the whole content of the decision (both land on <=27, so the target is certain --
# but "certain because two independent readings agree" is a different statement from "certain").
GP=/usr/bin/getprop
gp_is_stub=0
if [ -f "$GP" ]; then
  head -c 2 "$GP" 2>/dev/null | grep -q '#!' && gp_is_stub=1
  grep -qa 'no-attach diagnostic' "$GP" 2>/dev/null && gp_is_stub=1
fi
if [ -x "$GP" ]; then
  fal=$("$GP" ro.product.first_api_level 2>/dev/null | tr -d '\r')
  sdk=$("$GP" ro.build.version.sdk 2>/dev/null | tr -d '\r')
else
  fal=; sdk=
fi
lvl=${fal:-$sdk}
# The verdict has to come from what it ANSWERED, not from a guess about the file: the v63 stub is a
# shell script, but so is any other replacement, so a shebang proves nothing on its own. (The first
# draft of this said "THE v63 STUB, so every read below is empty" and then printed a value when a
# test substituted a shell script that does answer -- a sentence contradicting the lines under it.)
gpn="a real binary"
[ "$gp_is_stub" = 1 ] && gpn="a shell script (the v63 stub's shape)"
if [ -z "$lvl" ]; then
  printf '   biometryd execs %s -- %s, and it answers NOTHING\n' "$GP" "$gpn"
  printf '     -> that is what makes the <=27 branch automatic: not the device, its own broken read\n'
else
  printf '   biometryd execs %s -- %s, and it DOES answer (so the level below is a real read)\n' "$GP" "$gpn"
fi
printf '     ro.product.first_api_level -> %s\n     ro.build.version.sdk      -> %s\n' "${fal:-<unset>}" "${sdk:-<unset>}"
case "$lvl" in
  ''|*[!0-9]*) echo "   -> both empty/garbage, so atoi(\"\")=0 and biometryd takes the <=27 branch:"
               echo "      /data/system/users/0/fpdata/    (biometryd's ACTUAL reason on this port)"
               TARGET=/data/system/users/0/fpdata ;;
  *) if [ "$lvl" -le 27 ] 2>/dev/null; then
       echo "   -> level $lvl <= 27: biometryd passes /data/system/users/0/fpdata/"
       TARGET=/data/system/users/0/fpdata
     else
       echo "   -> level $lvl > 27: biometryd passes /data/vendor_de/0/fpdata/  (check THAT one above)"
       TARGET=/data/vendor_de/0/fpdata
     fi ;;
esac
# The cross-check, and it is worth reading even when it agrees: the vendor.img build.prop in the
# 2026-06-07 backup set says ro.product.first_api_level=23, which is the same branch. Two independent
# readings landing on one path is what makes the write in section 5 safe.
if [ -n "$A" ]; then
  cfal=$(nsenter -t "$A" -p -- /system/bin/getprop ro.product.first_api_level 2>/dev/null | tr -d '\r')
  csdk=$(nsenter -t "$A" -p -- /system/bin/getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')
  clvl=${cfal:-$csdk}
  printf '   the Android side, for cross-check only (biometryd never reads this):\n'
  printf '     ro.product.first_api_level -> %s     [2026-06-07 vendor.img build.prop: 23]\n' "${cfal:-<unset>}"
  printf '     ro.build.version.sdk      -> %s\n' "${csdk:-<unset>}"
  case "$clvl" in
    ''|*[!0-9]*) echo "   -> (the container's own read is empty too; the offline evidence stands alone)" ;;
    *) if [ "$clvl" -le 27 ] 2>/dev/null; then
         [ "$TARGET" = /data/system/users/0/fpdata ] \
           && echo "   -> AGREES with the reading above (both <=27): /data/system/users/0/fpdata/ is certain" \
           || echo "   -> DISAGREES with the reading above: biometryd will pass $TARGET, the device reports <=27."
       else
         [ "$TARGET" = /data/vendor_de/0/fpdata ] \
           && echo "   -> AGREES with the reading above (both >27): /data/vendor_de/0/fpdata/ is certain" \
           || echo "   -> DISAGREES with the reading above: biometryd will pass $TARGET, the device reports >27."
       fi ;;
  esac
else
  echo "   (no container -- the container's properties cannot be cross-checked; the reading above stands alone)"
fi

# --- 3. under the wrapper: which module loads, and the daemon it needs --------------------------
#
# New in docs 98, and it is the part nobody had read out of the images: the wrapper HAL above is only
# the OUTER third of the chain, and the two halves below it each have their own store and their own
# way of failing. All of this was established offline from the vendor image (docs 98 section 2):
#
#   BiometricsFingerprint::setActiveGroup           <- the access(W_OK) gate, section 1 above
#     -> FingerprintDaemonProxy::setActiveGroup     <- in-process binder, same binary
#       -> mDevice = hw_get_module("fingerprint")   <- AOSP hw_get_module, variant order:
#            ro.hardware, ro.product.board=msm8996, ro.board.platform=msm8996, ro.arch
#          => /vendor/lib64/hw/fingerprint.msm8996.so   WINS (the variant matches; its SONAME is
#             libfingerprint5118m.default.so). It carries the Goodix sensor glue itself --
#             goodix_sensor_init/enroll/match, "Fp::connect failed!", Init goodix sensor failed! --
#             and hardcodes "/data/system/users/0/fpdata/". Its binder client is one library down:
#          => /vendor/lib64/hw/gxfingerprint5118m.default.so  only reached as ".default"
#          -> libfp_client5118m.so  getService("FingerPrintService"), whose interface descriptor is
#             android.hardware.IFpService; "FingerPrint, getService failed, try again later."
#         -> gx_fpd  (/vendor/bin/gx_fpd, class late_start, user system) provides FingerPrintService
#              -> libfpservice5118m.so calls hw_get_module("gxfingerprint5118m")
#                 => /vendor/lib64/hw/gxfingerprint5118m.default.so
#                    EIGHT hardcoded /data/gf_data/... roots, fs_mkdirs, chdir,
#                    links libQSEEComAPI.so and libfpnav5118m.so, opens /dev/goodix_fp, /dev/ion
#                       -> the TEE, via /dev/qseecom (the rc chmod 0666's it)
#
# The wrapper's own rc says why it is late_start: "class hal causes a race condition on some devices
# due to files created in /data. As a workaround, postpone startup until later in boot once /data is
# mounted." The vendor knew about the /data dependency; what no rc in this tree does is CREATE the
# directory (section 5's other candidate is /data/gf_data, which the HAL mkdirs itself).
#
# So there are TWO stores, not one, and the second one is created by the HAL itself. Getting the
# wrapper's path past access() is therefore necessary and not sufficient, and the two questions that
# decide what happens next -- did hw_get_module pick the module we think, and is the daemon that
# module calls actually up -- are both answerable here.

echo "== which module hw_get_module('fingerprint') picks for THIS container"
if [ -z "$A" ]; then
  echo "   (no container: both the properties and /vendor are the container's, so there is nothing to read)"
else
  # The variant order is AOSP's (hardware/libhardware/hardware.c: variant_keys). Read the four
  # properties inside the container, because the host's getprop is a stub (docs 50).
  # No temp files: this script is read-only and stays that way. The candidate names are accumulated
  # in a plain variable, which also means a failed property read cannot leave a stale list behind.
  variants=""
  for k in ro.hardware ro.product.board ro.board.platform ro.arch; do
    v=$(nsenter -t "$A" -p -- /system/bin/getprop "$k" 2>/dev/null | tr -d '\r')
    printf '   %-20s = %s\n' "$k" "${v:-<unset>}"
    [ -n "$v" ] && variants="$variants $v"
  done
  # /vendor here is the CONTAINER's tree, not the host's: this script runs on the UT side, where
  # /vendor is a different (or absent) tree. Every path below is therefore read through halpath(),
  # i.e. /proc/<hal-pid>/root/... -- `test -f /vendor/...` on the HOST would report every module
  # MISSING and read as "the HAL is not installed", which is the failure this section exists to rule
  # out. (The first draft of this section made precisely that mistake, and the SECOND draft moved it
  # from `test -f` on the host to `nsenter -m -- test`, which failed the other way: see halpath().)
  pick=""
  for v in $variants; do
    for d in /vendor/lib64/hw /system/lib64/hw /odm/lib64/hw; do
      if [ -z "$pick" ] && [ -f "$(halpath "$d/fingerprint.$v.so")" ]; then
        pick="$d/fingerprint.$v.so"
      fi
    done
  done
  if [ -n "$pick" ]; then
    echo "   -> variant match: $pick"
    case "$pick" in
    *fingerprint.msm8996.so)
      echo "      that module carries the Goodix sensor glue for the msm8996 variant and is a binder"
      echo "      CLIENT (via libfp_client5118m.so) of the service 'FingerPrintService'. It also"
      echo "      hardcodes /data/system/users/0/fpdata/ -- the same path biometryd passes and the"
      echo "      wrapper access()es, so that path is not only a gate: it is the outer store too." ;;
    *) echo "      (an unexpected variant: the offline read is docs 98 section 2; do not trust it here)" ;;
    esac
  else
    echo "   -> no variant match; AOSP would fall back to fingerprint.default.so"
  fi
  # What is actually on disk, so "which module" is an observation and not a guess. Size only: readelf
  # and strings are host tools and are NOT in the device rootfs, so the ELF/linkage facts stay where
  # they were measured (scripts/host/zl1-vendor-link-audit.sh, offline against the images).
  echo "   the modules present, as the container sees them:"
  for d in /vendor/lib64/hw /system/lib64/hw; do
    ls -l "$(halpath "$d")" 2>/dev/null |
      awk -v d="$d" '/finger|gxfinger/ { printf "   %s/%s  %s bytes\n", d, $NF, $5 }'
  done
  [ -e "$(halpath /vendor/lib64/hw/fingerprint.default.so)" ] ||
    echo "   (no fingerprint.default.so: AOSP's fallback would fail outright, not silently)"
fi

echo "== the daemon the loaded module needs: gx_fpd, and its binder service"
gxp=0
for p in /proc/[0-9]*; do
  [ -r "$p/cmdline" ] || continue
  c=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
  case "$c" in *gx_fpd*) gxp=${p#/proc/}; break ;; esac
done
if [ "$gxp" != 0 ]; then
  echo "   gx_fpd: pid $gxp  uid=$(awk '/^Uid:/{print $2}' "/proc/$gxp/status" 2>/dev/null)"
else
  echo "   gx_fpd: NOT RUNNING. The module that gets loaded is a client of the binder service it"
  echo "   provides, so its absence is a second, independent reason setActiveGroup cannot work --"
  echo "   and it is silent in the wrapper: Fp::connect just fails, one layer down."
fi
if [ -n "$A" ]; then
  # The binder namespace is the container's, which is why this needs nsenter -p and why the host's
  # own `service list` would answer "nothing" (docs 51's rule).
  sl=$(ns_run '-p' /system/bin/service list)
  case "$sl" in
  *NSENTER-EXEC-FAIL:*)
    echo "   COULD NOT RUN: ${sl#*NSENTER-EXEC-FAIL: }"
    echo "   -> the 'not registered' verdict is NOT printed: it would be about this, not the container"
    n=0 ;;
  *) n=$(printf '%s\n' "$sl" | grep -aic 'finger')
     printf '   FingerPrintService on the container binder: %s\n' \
       "$(printf '%s\n' "$sl" | grep -ai 'finger' | head -3 | tr '\n' ' ')"
     [ "$n" -gt 0 ] || echo "      -> not registered: the loaded module's Fp::connect has nothing to talk to" ;;
  esac
fi

echo "== the second store: /data/gf_data (the innermost Goodix HAL's own, NOT in /proc/<hal>/root only)"
if [ -n "$A" ]; then
  for p in /data/gf_data /data/gf_data/enroll /data/system/users/0/fpdata; do
    if [ -e "$(halpath "$p")" ]; then
      printf '   EXISTS   %-32s %s\n' "$p" "$(ls -ldn "$(halpath "$p")" 2>/dev/null | awk '{printf "mode=%s uid=%s gid=%s", $1,$3,$4}')"
    else
      echo "   MISSING  $p"
    fi
  done
  echo "   (the HAL creates /data/gf_data itself with fs_mkdirs; it never reads the path biometryd"
  echo "    passes, so a missing /data/gf_data is a DIFFERENT failure from the access() gate above)"
fi

echo "== the device nodes the innermost HAL opens"
for d in /dev/goodix_fp /dev/qseecom /dev/ion; do
  if [ -e "$d" ]; then ls -ld "$d" 2>/dev/null | sed 's/^/   /'
  else echo "   MISSING $d"; fi
done
echo "   (the vendor rc's 'on boot' chmods /dev/qseecom 0666 and chowns /dev/goodix_fp to system --"
echo "    if that section did not run in the container, the perms here are the ones the HAL sees)"

# --- 4. the log, split by which process could have written it ----------------------------------

# **A log string can only appear in the log of the process whose address space contains it**, so the
# counts below are split by owner. This section used to count all thirteen patterns in the container's
# logcat, and that made the ONE comparison its own header asks for unreadable:
#
#   the header says the device log shows the *caller's* "setActiveGroup failed: SYS_EINVAL" and nothing
#   from the HAL, because the access() branch is silent. That caller is **biometryd**, and the string
#   lives in **libbiometry.so.2.0.0 -- on the UT side**, so it goes to biometryd's journal. Counted in
#   logcat it was structurally 0, i.e. the old comment's rule ("'Bad path length' = 0 while
#   'setActiveGroup failed' > 0 means the access() branch") could never be satisfied, and a reader
#   would have concluded the HAL never got the call at all -- the opposite of what the header says.
#
# Five more patterns were in no binary of any of the three images, two of them because the real string
# says **Can't**, not "Can not" -- in a probe whose whole subject is a line that is missing, that is
# the worst possible defect: a count that is 0 no matter what the device does.
# Where each string was found (offline, grep over the images this port ships -- evidence:
# docs/ubuntu-touch/evidence/fp-log-owners-2026-09-23.log):
#
#   logcat (a process in the Android container)
#     android.hardware.biometrics.fingerprint@2.0-service.leeco_zl1
#                              Bad path length        AOSP's BiometricsFingerprint.cpp -- the
#                                                     precondition, and the reason a >0 here means the
#                                                     path never even reached access()
#                              Start biometrics       service.cpp, ALOGE: openHal() got this far
#                              Opening fingerprint hal library
#                              Can't open fingerprint HW Module
#                              Can't create instance of BiometricsFingerprint
#     fingerprint.msm8996.so   Fp::connect failed     the innermost wrapper
#     libsecureui_svcsock.so   getService failed      kept, but note it is a generic string that also
#                                                     appears in two unrelated blobs in this Android
#                                                     image, so a >0 is not necessarily this chain
#   logcat too, but they are NOT binary strings -- and they belong here anyway:
#     fps_hal, gx_fpd   a logcat line's TAG is the process name, so a daemon that logs under its own
#                       name shows up without that name existing in any binary. This is the one
#                       exception to the rule at the top, and it is why these two are not removed.
#   journal of biometryd.service (the UT-side caller, and the library it loads)
#     libbiometry.so.2.0.0   setActiveGroup failed: %s        <-- the line the header quotes
#                            Failed to instantiate device.
#                            Cannot construct Forwarding device for null impl.
#                            Clearing template store:
#                            Failed to enroll template, aborting ...
#   neither, and that is why they are gone:
#     'Unable to get FP service' / 'Connected to IBiometricsFingerprint' /
#     'Unable to get IBiometricsFingerprint'   in no file of any of the three images. The second one
#                                              was ALSO the string the self-test's own logcat fixture
#                                              contained, so it was the harness that made it look real
#     'Can not open fingerprint HW Module' / 'Can not create instance of BiometricsFingerprint'
#                                              the strings in the service binary say Can't (above)

echo "== the log, split by which process could have written it (the HAL's silent branch is the point --"
echo "   a missing line is evidence, and WHICH log it is missing from is the other half)"
if [ -n "$A" ]; then
  dump=$(ns_run '-p -m' /system/bin/logcat -d -v brief)
  case "$dump" in
  *NSENTER-EXEC-FAIL:*)
    echo "   COULD NOT RUN: ${dump#*NSENTER-EXEC-FAIL: }"
    echo "   -> every count below is 0 for THAT reason, and 0 is a FINDING here: read nothing into"
    echo "      these numbers. An instrument that cannot report is worse than none (docs 99/109), and"
    echo "      this is exactly the shape that made the self-test's logcat section pass on an empty"
    echo "      dump for months (docs 103 section 5)." ;;
  esac
  echo "   --- logcat (the container's vendor service and the modules it loads) ---"
  for pat in 'Bad path length' \
             'Start biometrics' \
             'Opening fingerprint hal library' \
             "Can't open fingerprint HW Module" \
             "Can't create instance of BiometricsFingerprint" \
             'Fp::connect failed' \
             'getService failed' \
             'fps_hal' \
             'gx_fpd' ; do
    printf '   %-52s %s\n' "$pat" "$(printf '%s\n' "$dump" | grep -acF "$pat")"
  done
  echo "   -- the last 10 lines mentioning finger/biometric:"
  printf '%s\n' "$dump" | grep -aiE 'finger|biometric|fp_|goodix' | tail -10 | cut -c1-150 | sed 's/^/   | /'
else
  echo "   --- logcat: skipped (no container: lxc-info gave nothing) ---"
fi

# The UT side. `journalctl -b -u` is boot-scoped rather than time-scoped, which is the only kind of
# journal query that survives a wrong clock (this device has no working RTC, docs 69).
echo "   --- journal of biometryd (the caller biometryd, and the library it loads) ---"
jdump=$(journalctl -b -u biometryd --no-pager -o cat 2>/dev/null)
if [ -z "$jdump" ]; then
  echo "   (empty or unreadable -- if biometryd is active and this is empty, that itself is the finding:"
  echo "    it writes its device and HAL messages to stderr, which systemd journals)"
fi
for pat in 'setActiveGroup failed' \
           'Failed to instantiate device' \
           'Cannot construct Forwarding device' \
           'Clearing template store' \
           'Failed to enroll template' ; do
  printf '   %-52s %s\n' "$pat" "$(printf '%s\n' "$jdump" | grep -acF "$pat")"
done
echo "   -- the pair that decides it, now readable because both halves are in the same place:"
echo "      'Bad path length' > 0                  -> the path never reached access() (too long/empty)"
echo "      'Bad path length' = 0 AND the caller's"
echo "      'setActiveGroup failed' > 0            -> the access(W_OK) branch, which logs NOTHING"
echo "                                                (BiometricsFingerprint.cpp:221-223), so the HAL"
echo "                                                has no line of its own on that path -- which is"
echo "                                                exactly why the caller's line is the evidence"
echo "   -- 'Start biometrics' is an ALOGE in service.cpp, so it always lands in logcat: it means"
echo "      openHal() got as far as registering the HIDL service, which puts the failure after open."

# --- 5. the HIDL service and the device node ---------------------------------------------------

echo "== HIDL registration (lshal needs nsenter -p -m; and it is resolved through the container's PATH,"
echo "   which is the mechanism that failed for the module test above -- so its failure is now printed)"
if [ -n "$A" ]; then
  # ONE call, read twice. It used to run lshal twice, which is two chances to differ, and grep's exit
  # status on an empty listing is what decides the verdict below -- so an exec failure would have read
  # as "no fingerprint service registered", the finding this section exists to make.
  sl=$(ns_run '-p -m' lshal)
  case "$sl" in
  *NSENTER-EXEC-FAIL:*)
    echo "   COULD NOT RUN: ${sl#*NSENTER-EXEC-FAIL: }"
    echo "   -> the registration question is UNANSWERED, not answered 'no' (docs 110: a row in"
    echo "      lshal's first table means hwservicemanager lists it, so an absent listing is not a row)" ;;
  *)
    printf '%s\n' "$sl" | grep -ai 'fingerprint' | sed 's/^/   /'
    n=$(printf '%s\n' "$sl" | grep -aci 'fingerprint')
    [ "$n" -gt 0 ] || echo "   (no fingerprint service registered)" ;;
  esac
fi

echo "== the fingerprint device node(s)"
for d in /dev/goodix_fp /dev/qseecom /sys/devices/soc/soc:fpc_fpc1020; do
  [ -e "$d" ] && ls -ld "$d" 2>/dev/null | sed 's/^/   /' || echo "   MISSING $d"
done

echo "== SELinux (if it is enforcing, a newly created directory needs the right label)"
for f in /sys/fs/selinux/enforce /sys/fs/selinux/mls; do
  [ -r "$f" ] && printf '   %-26s %s\n' "$f" "$(cat "$f" 2>/dev/null)" || echo "   $f unreadable/absent"
done

# --- 6. the one write, only when asked ---------------------------------------------------------

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
  # Through the HAL's own root: /proc/<pid>/root makes /data mean the container's /data, and unlike
  # `nsenter -m` it does not need to exec something inside a mount table that has no /usr/bin.
  if [ -e "$(halpath "$TARGET")" ]; then
    echo "   exists already: $TARGET"
    ls -ldn "$(halpath "$TARGET")" 2>/dev/null | sed 's/^/   /'
  else
    mkdir -p "$(halpath "$TARGET")" && echo "   created $TARGET"
    # chown only if the HAL is not root: root can write anything, so the mode is then irrelevant.
    if [ -n "$uid" ] && [ "$uid" != 0 ]; then
      chown "$uid:$gid" "$(halpath "$TARGET")" 2>/dev/null && echo "   chown $uid:$gid $TARGET"
      chmod 0700 "$(halpath "$TARGET")" 2>/dev/null && echo "   chmod 0700 $TARGET"
    fi
    ls -ldn "$(halpath "$TARGET")" 2>/dev/null | sed 's/^/   now: /'
  fi
  echo "   NOT created: $OTHER (section 2 says biometryd passes $TARGET, so nothing would ever read the"
  echo "   other one; if the evidence later contradicts section 2, make it by hand. The pid in these"
  echo "   lines is the HAL's ON THIS BOOT -- find the current one with:"
  echo "     ps -eo pid,args | grep -i [b]iometrics.fingerprint"
  echo "     mkdir -p /proc/<that-pid>/root$OTHER"
  echo "   UNDO: rmdir /proc/<that-pid>/root$TARGET   (only if it is still empty)"
  echo "   then restart whatever reports the failure and re-read the logcat counts above."
fi
