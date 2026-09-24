#!/bin/sh
# zl1 modem probe -- is the modem firmware anywhere the kernel can load it, and did it load? Read-only.
#
# Why this exists (docs 120). Telephony is the one subsystem on this port nobody has looked at: every
# other peripheral has an instrument, and the note that covers them all ends with "Not tested at all:
# modem/telephony beyond ofono being active". It is also the subsystem where a port most easily has a
# silent, total gap -- because the modem is not a driver you can poke, it is a separate CPU running
# firmware that the KERNEL has to hand it at probe time.
#
# What reading this device offline says (all of it checkable, none of it measured on the device yet):
#
#   * The device tree asks for it by name. From the zl1's own DTB:
#         soc/qcom,mss@2080000    compatible = qcom,pil-q6v55-mss
#                                 qcom,firmware-name = "modem"
#                                 qcom,pil-self-auth          <- secure PIL: TZ authenticates it
#                                 status = ok
#     So the kernel's peripheral-image-loader will call the firmware API for the file named `modem`,
#     i.e. `modem.mdt` and its `modem.b00..b18` segments.
#   * The firmware is NOT in the Android vendor image. `/vendor/firmware` there holds `modem_pr/` (RF
#     configuration: mcfg_sw_att.mbn and friends) and the OTHER DSPs (a530_zap, cppf, venus, adsp) --
#     no `modem.b*` and no `mba.mbn`.
#   * It is on the dedicated `modem` partition, which is a FAT16 filesystem whose ROOT holds `IMAGE/` and
#     `VERINFO/`: the files are `IMAGE/MODEM.B00 .. IMAGE/MODEM.B18`, `IMAGE/MBA.MBN` and 300-odd others
#     (301 files / 78.2 MiB, walked from the partition image without mounting it). Android mounts it
#     read-only with `shortname=lower`, so those become `image/modem.mdt` and so on, and the port's own
#     fstab says exactly where:
#         /dev/block/bootdevice/by-name/modem   /vendor/firmware_mnt   vfat  ro,shortname=lower,...
#   * The boot image ALREADY names that directory, and names it correctly. Every zl1 cmdline on this
#     device carries (the stock one is recorded in docs 20; the v63 images inherited it verbatim)
#         firmware_class.path=/vendor/firmware_mnt/image
#     and `image/` is precisely where the file is. So this is NOT "the kernel was never told where to
#     look" -- the first version of this header said that, and the cmdline refuted it.
#   * What the kernel was told is written in the UT rootfs's own shape: `/vendor` there is a SYMLINK to
#     `/android/vendor`, so `firmware_class.path` resolves -- if and only if something mounted the modem
#     partition at `/android/vendor/firmware_mnt` on this boot. The UT rootfs has no `/lib/firmware` at
#     all (checked in the rootfs image: neither `/lib/firmware` nor `/usr/lib/firmware` exists), so that
#     mount is the ONLY way the firmware can be reached.
#   * And on the UT boot it is halium that would make the mount: `scripts/halium` mounts Android's
#     partitions by reading `fstab*` at the root of the Android ramdisk it extracted, and mounting each
#     entry under `/android`. `cat ${fstab}` with an unexpanded glob FAILS, so an absent fstab is not an
#     error message -- it is a mount loop that mounts nothing, silently. Whether that file exists on this
#     device is one `ls` away, and section 3 takes it.
#
# That is a hypothesis with a named mechanism, not a finding: the mount may be made by halium's loop, by
# the Android container's own init (a different mount namespace, which would NOT help the kernel), or by
# something this port does that is not visible in the images. This probe is what measures which. What it
# does NOT do is infer the answer from the images: every reading below is taken on the device, and a
# reading that could not be taken says so instead of reading as a "no" (docs 117 -- the rule that three
# earlier instruments had to learn one at a time).
#
# THE SAFETY LINE, and it is absolute. This script:
#   * writes NOTHING: no partition, no sysfs node, no module load/unload, no service restart;
#   * never opens a block device, not even to read one -- it looks at MOUNT POINTS and the files inside
#     them, because `modemst1`/`modemst2`/`fsg`/`fsc`/`persist` hold the device's calibration and IMEI,
#     and the difference between "read the modem partition to inspect it" and "write it" is one typo;
#   * does not unbind, reset or restart anything: unbinding the cnss driver on this device drops it
#     straight into EDL (docs 49), and the same class of move must never be scripted.
# A probe that could brick the phone to answer a question is not a probe worth having.
#
# Usage (on the device, as root):
#   zl1-modem-probe.sh [--status] [--quiet] [--explain]
#     --status   (default) the readings and the verdict
#     --quiet    the section headings, the boot identity and the verdict -- no readings at all
#     --explain  print why each reading is the one that decides, and change nothing
#
# Exit codes: 0 the readings were taken (the verdict says what they mean); 1 a reading could not be
#             taken, so the verdict is UNANSWERED; 2 not the zl1.

set -u

MODE=status
QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
  --status) MODE=status; shift ;;
  --quiet) QUIET=1; shift ;;
  --explain) MODE=explain; shift ;;
  --help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0" ; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

# `say` carries the readings, `hdr` the headings, and `always` the two things a reader must see whether or
# not they asked for the readings: WHICH boot this is (a verdict with no boot identity is not attributable
# to anything) and the verdict itself. `hdr` prints even under --quiet, because a --quiet output that is
# one unlabelled paragraph of conclusions is worse than no --quiet at all -- the headings are what make
# the verdict readable next to the log it came from.
say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
hdr() { printf '\n== %s\n' "$*"; }
always() { printf '%s\n' "$*"; }

# The device guard. `compatible` and not `model`: this device's model string is the one the health check
# matches too, but msm8996 is what the port's own location probe refuses on, and a probe that runs on
# the wrong phone reads a different modem and reports it as this one's.
grep -qa msm8996 /proc/device-tree/compatible 2>/dev/null ||
  { echo "not the zl1 (no msm8996 in /proc/device-tree/compatible) -- refusing" >&2; exit 2; }

# Reading a file that does not exist and reading one that is empty are different, and so is a command
# that could not run. `rd` prints the file's contents, or the literal `UNREADABLE` -- never an empty
# string, which is what a missing file and a successful-but-empty read both look like.
rd() { # $1 = path
  if [ -r "$1" ]; then
    v=$(tr -d '\n' < "$1" 2>/dev/null)
    printf '%s' "${v:-EMPTY}"
  else
    printf 'UNREADABLE'
  fi
}
# Existence, as a word, so it cannot be confused with an empty answer.
ex() { [ -e "$1" ] && printf 'present' || printf 'MISSING'; }
# Print the matching lines of a file, or a named "(none)" line. NOT `grep ... | sed ... || say none`:
# in a pipeline the `||` applies to the LAST command, and `sed` succeeds on empty input, so the
# none-branch would never fire and a pattern that matched nothing would print nothing at all -- the
# silent-empty-output shape this repo has had to fix in four other instruments.
show() { # $1 = file, $2 = ERE, $3 = the "(none: ...)" text, $4 = tail -n
  [ "$QUIET" = 1 ] && return 0
  local out
  out=$(grep -aiE -- "$2" "$1" 2>/dev/null | tail -n "${4:-15}")
  if [ -n "$out" ]; then printf '%s\n' "$out" | sed 's/^/   | /'; else printf '   | %s\n' "$3"; fi
}

if [ "$MODE" = explain ]; then
  cat <<'EOF'
zl1 modem probe -- what each reading decides, and why it is this reading

  1. THE DEVICE TREE'S OWN NAME FOR THE FIRMWARE.
     /proc/device-tree/soc/qcom,mss@2080000/qcom,firmware-name is what the kernel's PIL driver passes
     to request_firmware(). It is read from the device, not from a DTB in this repo, because the port
     may boot a different DTB than the one that was analysed offline.

  2. THE FIRMWARE SEARCH PATH, and whether the file is on it.
     request_firmware() looks in the kernel's built-in list (/lib/firmware, /lib/firmware/updates,
     each with a /<uname -r> form) plus whatever /sys/module/firmware_class/parameters/path holds.
     TWO readings of that parameter are printed, because they answer different questions: the cmdline's
     `firmware_class.path=` is what this BOOT was told (what was in force when the modem was probed) and
     the sysfs file is what the kernel has NOW. Then each directory is asked whether it holds the file by
     name. "The directory does not exist" and "the directory exists but the file is not in it" are
     different answers to different problems, so they are printed differently.

  3. WHERE THE FIRMWARE ACTUALLY IS.
     The modem partition, mounted -- and the SYMLINK CHAIN first, because on this port `/vendor` is a
     symlink to `/android/vendor`, so the path the kernel was given and the path a mount creates are the
     same place only if that symlink is followed to the mounted one. The partition is a vfat with
     shortname=lower, which is why the file the kernel asks for (`modem.mdt`) is lower-case while the FAT
     directory entry is `MODEM.MDT` -- and why its directory is `image/`: the FAT root holds IMAGE/ and
     VERINFO/, so the file is one component below the mount point, and this probe asks BOTH levels for
     that reason. If nothing has mounted it on this boot, the files cannot be reached by name at all --
     which is a complete explanation for a dead modem and needs no further theory.
     AND THE MECHANISM THAT WOULD MOUNT IT is read too: on the UT boot, halium mounts Android's
     partitions from an fstab at the root of the Android ramdisk it extracted, and an ABSENT fstab makes
     its `cat` fail silently, so the loop mounts nothing and the boot continues. That file's presence and
     its modem line are printed, because they are the difference between "the port does not mount this"
     and "the port mounts it and something else is wrong".

  4. DID IT LOAD. The kernel log for this boot, for the PIL and the modem subsystem. Counted per
     pattern, and the counts say which log they came from. A pattern whose owner cannot write it is
     not evidence (docs 102) -- so these are all kernel lines, read from one log.

  5. THE PLUMBING THAT ONLY EXISTS IF IT LOADED. /sys/bus/msm_subsys (the Qualcomm subsystem-restart
     view) and /dev/qmi*, plus rmnet netdevs. These are downstream of a successful load: their absence
     is a consequence, not a cause, and reading them first is how a diagnosis ends up one layer too
     low.

  6. THE UT SIDE. ofono's unit state and whether org.ofono owns a name on the system bus. ofono being
     "active" is what the peripheral note could say and no more: it says a daemon started, not that it
     has a modem to talk to.

  7. THE VERDICT names the rung the evidence stops at. The interesting one is the third and fourth:
     firmware present but not loaded points at TZ/signature (qcom,pil-self-auth is set), and load
     attempted but failing points at the loader path.
EOF
  exit 0
fi

always "zl1 modem probe (read-only)"
always "  boot: $(rd /proc/sys/kernel/random/boot_id)"
always "  kernel: $(rd /proc/sys/kernel/osrelease)"

# ==================================================================================================
hdr "1. what the device tree asks the kernel to load"
# ==================================================================================================
# The node name is written out rather than globbed: a glob would silently match a differently-named node
# on another kernel and read the wrong firmware name, and this is the one string every later reading is
# compared against.
MSS_DIR=/proc/device-tree/soc/qcom,mss@2080000
MSS_COMPAT=$(rd "$MSS_DIR/compatible")
FW_NAME=$(rd "$MSS_DIR/qcom,firmware-name")
SELF_AUTH=$(ex "$MSS_DIR/qcom,pil-self-auth")
MSS_STATUS=$(rd "$MSS_DIR/status")
say "   $MSS_DIR"
say "     compatible       ${MSS_COMPAT}"
say "     qcom,firmware-name ${FW_NAME}"
say "     qcom,pil-self-auth ${SELF_AUTH}   (present = TZ authenticates the image)"
say "     status           ${MSS_STATUS}"
case "$FW_NAME" in
UNREADABLE|EMPTY)
  say "     -> the node did not answer. This kernel may not have this node at all, which is itself the"
  say "        finding -- do not assume the firmware is called 'modem' on a kernel that did not say so."
  FW_NAME=""
  ;;
esac
if [ -n "$FW_NAME" ]; then
  say "     -> so the kernel will ask the firmware API for '${FW_NAME}' (${FW_NAME}.mdt + ${FW_NAME}.b00..)"
else
  say "     -> the firmware NAME is unknown on this boot; sections 2 and 3 are reported but the"
  say "        comparison against a name cannot be made, and the verdict says so."
fi

# ==================================================================================================
hdr "2. the firmware search path, and whether the file is on it"
# ==================================================================================================
KREL=$(rd /proc/sys/kernel/osrelease)
FWPARAM=$(rd /sys/module/firmware_class/parameters/path)
say "   firmware_class.path: ${FWPARAM}"
[ "$FWPARAM" = EMPTY ] && say "     (empty = only the kernel's built-in list below is searched)"
[ "$FWPARAM" = UNREADABLE ] && say "     -> could not be read: /sys/module/firmware_class may not be loaded here, so the"
[ "$FWPARAM" = UNREADABLE ] && say "        path is UNKNOWN rather than empty. Do not read this as 'no custom path'."

# The SAME parameter as the BOOT asked for it, and these are two different readings that can disagree.
# The sysfs file is what the kernel has NOW -- something may have rewritten it during this boot -- while
# /proc/cmdline is the only record of what the boot was told. That second one is what was in force at
# probe time, which is when the modem firmware was requested, so it is the one that explains a failure.
if [ -r /proc/cmdline ]; then
  CMDPATH=$(tr ' ' '\n' < /proc/cmdline 2>/dev/null | sed -n 's#^firmware_class.path=##p' | head -n 1)
  [ -n "$CMDPATH" ] || CMDPATH=EMPTY
else
  CMDPATH=UNREADABLE
fi
say "   firmware_class.path on the BOOT cmdline:      ${CMDPATH}"
case "$CMDPATH" in
EMPTY) say "     -> this boot was given no path at all, so only the built-in list below applies";;
UNREADABLE)
  say "     -> /proc/cmdline could not be read, so what THIS BOOT was told is UNKNOWN. That is not"
  say "        'no path was set' (docs 117), and it is exactly the reading a probe must not invent.";;
*)
  case "$FWPARAM" in
  UNREADABLE|EMPTY|"$CMDPATH") ;;
  *) say "     -> and the RUNNING parameter does not match it: the value was changed after boot, so the"
     say "        two lines above are two different answers to two different questions.";;
  esac
  # Resolved the way a path is resolved, through its symlinks -- which on this port is the whole point:
  # `/vendor` in the UT rootfs is a SYMLINK to `/android/vendor`, so the kernel's path and the mount
  # point halium would create are the same place only if the symlink is followed to the mounted one.
  RSV=$(readlink -f "$CMDPATH" 2>/dev/null)
  say "     -> resolves to: ${RSV:-<NOT RESOLVED: readlink is missing, or the path does not exist>}"
  say "        $(printf '%-40s' "$CMDPATH") $(ex "$CMDPATH")"
  ;;
esac

# The built-in list, in the kernel's own order (fw_path, fw_path_para, then the extra path). The cmdline's
# path is added FIRST when there is one: on this device it is the only entry that is expected to hold the
# file, and a reader should meet it before four directories that never will. The list starts with a SPACE
# and `for d in $PATHS` ignores it -- the space is what makes every element a " /lib/firmware..." for the
# offline harness's path rewriter, and the harness has a check that would fail if one element escaped it.
PATHS=" /lib/firmware/updates/$KREL /lib/firmware/updates /lib/firmware/$KREL /lib/firmware"
case "$CMDPATH" in UNREADABLE|EMPTY) ;; *) PATHS="$CMDPATH $PATHS" ;; esac
# The running parameter is added only if it is not the same string: the boot's value and the sysfs value
# are usually identical, and printing the same directory twice would read as two independent sightings.
case "$FWPARAM" in
UNREADABLE|EMPTY) ;;
*) [ "$FWPARAM" = "$CMDPATH" ] || PATHS="$PATHS $FWPARAM" ;;
esac
# NOTE on the LEVEL of the question below: the kernel's list is searched literally, so each entry is asked
# for the file DIRECTLY in it (`<dir>/modem.mdt`) -- which is right for `/lib/firmware` and right for the
# cmdline's `/vendor/firmware_mnt/image`, whose whole reason for ending in `image` is that the FAT keeps
# the file in its `IMAGE/` subdirectory. Section 3 asks the two-level question, because a MOUNT POINT is a
# directory whose layout this probe must not assume.
FOUND_AT=""
for d in $PATHS; do
  [ -n "$FW_NAME" ] || { say "   $(printf '%-34s' "$d") (not checked: the firmware name is unknown)"; continue; }
  mdt=$(ex "$d/$FW_NAME.mdt")
  b00=$(ex "$d/$FW_NAME.b00")
  say "   $(printf '%-34s' "$d") ${FW_NAME}.mdt=${mdt} ${FW_NAME}.b00=${b00}"
  if [ "$mdt" = present ] || [ "$b00" = present ]; then FOUND_AT="$d"; fi
done
# Three answers, not two. With no name from the device tree, no directory above was ever asked for the
# file -- so concluding "the firmware is not on the search path" would be reporting a question that was
# never put as a negative answer, which is the same defect as reading an unreadable log as a quiet boot.
if [ -z "$FW_NAME" ]; then
  say "   -> NOT CONCLUDED: the firmware name is unknown on this boot, so no directory above was asked"
  say "      for the file. This is not 'the firmware is not there'; it is 'the question was not asked'."
elif [ -n "$FOUND_AT" ]; then
  say "   -> the firmware IS reachable by name, at ${FOUND_AT}"
else
  say "   -> the firmware is NOT on the kernel's search path (nothing above has it)"
fi

# The MBA, which is a separate image and a separate call. Named without a suffix guess: the driver's
# default is mba.mbn, and `mba` alone is checked too because some trees ask for it that way.
for d in $PATHS; do
  case "$(ex "$d/mba.mbn")" in
  present) say "   $(printf '%-34s' "$d") mba.mbn=present   (the MBA image is here too)";;
  esac
done

# ==================================================================================================
hdr "3. where the modem firmware actually is"
# ==================================================================================================
# Mount POINTS, never block devices. See the safety line in the header: opening the modem partition to
# inspect it is one keystroke away from writing it, and the mount point answers the same question.
BYNAME=$(ex /dev/block/bootdevice/by-name/modem)
say "   /dev/block/bootdevice/by-name/modem exists: ${BYNAME}   (NOT opened by this script)"
# Same pipeline trap as `show` above, and the same fix: a grep that matches nothing must still print
# its line, because "no mount mentions the modem" is one of the two readings this section exists for.
MOUNT_HITS=$(mount 2>/dev/null | grep -aE "on .*(firmware|modem)")
if [ -n "$MOUNT_HITS" ]; then printf '%s\n' "$MOUNT_HITS" | sed 's/^/   | /'; else say "   | (no mount line mentions firmware or modem)"; fi
# Counted once, here, and reused by the verdict: re-running `mount` down there would make the verdict
# depend on a second reading of a live table, and hide which sample the verdict was made from.
MOUNTED=$(printf '%s\n' "$MOUNT_HITS" | grep -ac . 2>/dev/null || true)
[ -n "$MOUNTED" ] || MOUNTED=0

# The symlink chain FIRST, because on this port the two spellings of the same path are not
# interchangeable: the UT rootfs's `/vendor` is a symlink to `/android/vendor`, and `/firmware` to
# `/android/firmware`. A path that "exists" through a symlink and a mount that was made at the target are
# two facts, and the firmware question needs both.
for sl in /vendor /android /firmware; do
  rl=$(readlink -f "$sl" 2>/dev/null)
  say "   $(printf '%-22s' "$sl") -> ${rl:-<unresolved: not a symlink and not a directory, or readlink is missing>}"
done

for mp in /vendor/firmware_mnt /lib/firmware /android/vendor/firmware_mnt /firmware; do
  say "   $(printf '%-34s' "$mp") $(ex "$mp")"
  [ -d "$mp" ] || continue
  [ -n "$FW_NAME" ] || continue
  # TWO LEVELS, and the second one is a defect this probe was fixed for before it ever ran on a device.
  # The modem partition's FAT root holds `IMAGE/` and `VERINFO/` (walked from the partition image: 301
  # files, and MODEM.MDT is `IMAGE/MODEM.MDT`, MBA.MBN is `IMAGE/MBA.MBN`), so on a mounted partition the
  # file is `image/modem.mdt` -- ONE DIRECTORY BELOW the mount point. Asking only `$mp/$FW_NAME.mdt`
  # reports MISSING for firmware that is right there: a false negative manufactured by the instrument,
  # which is the failure mode this repository keeps finding. `/lib/firmware` is the other way round (its
  # files sit directly in it), so both levels are asked and neither answer is assumed.
  say "     $(printf '%-36s' "$FW_NAME.mdt") $(ex "$mp/$FW_NAME.mdt")"
  say "     $(printf '%-36s' "image/$FW_NAME.mdt") $(ex "$mp/image/$FW_NAME.mdt")"
  say "     $(printf '%-36s' "image/mba.mbn") $(ex "$mp/image/mba.mbn")"
done

# THE MECHANISM THAT WOULD MAKE THAT MOUNT. On the UT (non-Android) boot it is halium's own script that
# mounts Android's partitions: it reads an fstab at the ROOT OF THE ANDROID RAMDISK it extracted, and
# mounts every entry under `/android`. Read the shipped script and the two shapes that matter are:
#     cat ${fstab} | while read line; do ... mount $path ${mount_root}/$2 ...; done
#     mount_android_partitions "${rootmnt}/var/lib/lxc/android/rootfs/fstab*" ${rootmnt}/android ...
# so an ABSENT fstab is not an error message: the glob does not expand, `cat` fails, the loop body never
# runs, and NOTHING is mounted while the boot carries on. That is a silent, total gap of exactly the kind
# this probe exists to distinguish from a hardware fault -- and it is one `ls` away on the device.
HALIUM_FSTAB=""
for f in /var/lib/lxc/android/rootfs/fstab*; do
  [ -e "$f" ] || continue
  HALIUM_FSTAB="$f"
  break
done
if [ -n "$HALIUM_FSTAB" ]; then
  say "   ${HALIUM_FSTAB} exists; the line halium would mount this partition with:"
  show "$HALIUM_FSTAB" '(^|[[:space:]])(modem|/vendor/firmware_mnt)' \
    "(none: that fstab has no modem or firmware_mnt line -- halium would mount nothing for the modem)" 5
else
  say "   /var/lib/lxc/android/rootfs/fstab*: NO SUCH FILE. This is the glob halium's mount loop reads,"
  # The backticks around `cat` are ESCAPED, and it is not cosmetic: this `say` is a double-quoted
  # string, so an unescaped backtick would COMMAND-SUBSTITUTE -- `cat` with no arguments reads STDIN,
  # so on the device it would eat the ssh channel and print whatever it swallowed into this probe's
  # output (measured on 2026-09-24: with a pipe carrying data the sentence came out with the pipe's
  # contents in the middle of it, and the word `cat` gone). Found by sweeping the whole tree for the
  # shape after the health check was caught executing its own prose (docs 122).
  say "   and an unexpanded glob makes its \`cat\` fail silently, so THAT LOOP MOUNTED NOTHING THIS BOOT."
  say "   -> if section 2 says the boot was given a firmware path, that path is a directory nothing"
  say "      created, which is a complete explanation for a modem that never loads. It is a MOUNT, not"
  say "      hardware, and not the modem partition's contents -- which must never be written."
fi
# The container's view, which is where Android's own mount point for this partition lives. Read with
# nsenter -m because that is the mount table the path means in; the probe does not assume the container
# is up (docs: an absent container is a reading, not a crash).
A=$(lxc-info -n android -pH 2>/dev/null | head -1)
if [ -n "$A" ]; then
  say "   container pid ${A}; its own view of the firmware mount:"
  # Same pipeline trap once more, and this one was live in the first draft: `nsenter ... | sed || say ...`
  # never fires its right-hand side, because the `||` applies to sed and sed succeeds on empty input. An
  # nsenter that could not run would then print NOTHING, which reads exactly like a clean listing of no
  # mount -- the "a command that could not run is not a zero" shape (docs 117), in the one section where
  # the answer lives in another mount namespace.
  CVIEW=$(nsenter -t "$A" -m -- ls -d /vendor/firmware_mnt 2>/dev/null)
  if [ -n "$CVIEW" ]; then printf '%s\n' "$CVIEW" | sed 's/^/   | /'
  else
    say "   | (the container's mount namespace answered nothing for /vendor/firmware_mnt -- that is not"
    say "   |  the same as the path being absent there)"
  fi
else
  say "   the android container is not running (lxc-info answered nothing), so its mount namespace"
  say "   could not be read -- that is NOT the same as the path being absent."
fi

# ==================================================================================================
hdr "4. did the kernel load it -- the log for THIS boot"
# ==================================================================================================
# One log, read once, and the read is proved before it is counted: `journalctl -k` that fails prints
# nothing, which is exactly what a quiet boot prints, and the counts below would then read as "the
# driver said nothing" (docs 117). So the read has a success test of its own.
KLOG=/tmp/zl1-modem-klog.txt
if journalctl -b -k --no-pager -o cat > "$KLOG" 2>/dev/null && [ -s "$KLOG" ]; then
  say "   journalctl -b -k: $(wc -l < "$KLOG") lines (saved to $KLOG)"
  for pat in 'pil-q6v5' 'pil-q6v55' 'q6v5' 'mss' 'subsys' 'MBA' 'firmware' 'modem'; do
    say "$(printf '   %-16s %4s' "$pat" "$(grep -aci -- "$pat" "$KLOG" 2>/dev/null)")"
  done
  say "   the lines themselves (modem/mss/pil only, capped):"
  show "$KLOG" 'pil-q6v5|q6v55|mss|subsys-pil' \
    "(none: the PIL driver logged nothing about the modem on this boot)"
  say "   any firmware-load FAILURE, named:"
  show "$KLOG" 'request_firmware|Direct firmware load|failed to (load|get) firmware|firmware.*(timed out|not found)' \
    "(none: no firmware-load failure line in this boot's kernel log)" 10
  KLOG_OK=1
else
  say "   COULD NOT READ THE KERNEL LOG. Every count below is 0 for THAT reason and is not printed."
  say "   -> the load question is UNANSWERED, not answered 'no' (docs 117)."
  KLOG_OK=0
fi

# ==================================================================================================
hdr "5. the plumbing that only exists if it loaded"
# ==================================================================================================
# Names first, state second: on this SoC the subsystem-restart driver exposes one directory per
# remoteproc, and an empty directory list is a reading about the KERNEL, while a directory whose state
# is OFFLINE is a reading about the modem.
if [ -d /sys/bus/msm_subsys/devices ]; then
  for d in /sys/bus/msm_subsys/devices/*/; do
    [ -d "$d" ] || continue
    say "   msm_subsys $(rd "$d/name"): state=$(rd "$d/state")"
  done
else
  say "   /sys/bus/msm_subsys/devices does not exist (this kernel may use mainline remoteproc instead)"
fi
if [ -d /sys/class/remoteproc ]; then
  for d in /sys/class/remoteproc/*/; do
    [ -d "$d" ] || continue
    say "   remoteproc $(basename "$d"): name=$(rd "$d/name") state=$(rd "$d/state") firmware=$(rd "$d/firmware")"
  done
else
  say "   /sys/class/remoteproc does not exist"
fi
QMI=$(ls /dev/qmi* 2>/dev/null | tr '\n' ' ')
say "   /dev/qmi*: ${QMI:-none}"
RMNET=$(ls -d /sys/class/net/rmnet* 2>/dev/null | wc -l | tr -d ' ')
say "   rmnet netdevs: ${RMNET}"
[ "$RMNET" -gt 0 ] && say "     $(ls -d /sys/class/net/rmnet* 2>/dev/null | tr '\n' ' ')"

# ==================================================================================================
hdr "6. the UT side: is anything there to talk to a modem"
# ==================================================================================================
# ofono's unit state is what the peripheral note could already say. The bus name is the stronger
# reading: an ofono that started but has no modem will not own `org.ofono` with a modem object under it.
OFONO=$(systemctl is-active ofono 2>/dev/null || true)
say "   systemctl is-active ofono: ${OFONO:-<no answer>}"
if command -v gdbus >/dev/null 2>&1; then
  OWNER=$(gdbus call --system --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
    --method org.freedesktop.DBus.GetNameOwner org.ofono 2>/dev/null | sed -n "s/.*'\(.*\)'.*/\1/p")
  say "   org.ofono on the system bus: ${OWNER:-not owned}"
  [ -z "$OWNER" ] && say "     -> nobody owns org.ofono: an ofono that is 'active' without the bus name is a"
  [ -z "$OWNER" ] && say "        daemon that did not get far enough to publish anything."
else
  say "   gdbus is not on this device, so the bus name was NOT read -- that is not 'not owned'."
fi
MM=$(systemctl is-active ModemManager 2>/dev/null || true)
say "   ModemManager: ${MM:-<not present or no answer>}"

# ==================================================================================================
hdr "7. verdict"
# ==================================================================================================
# The rungs, in the order the evidence descends. Each branch names what it is based on, and the two
# "could not measure" branches come BEFORE any negative one -- a probe that reports an unread log as a
# quiet boot is the defect three earlier instruments in this repo had to be fixed for.
if [ -z "$FW_NAME" ]; then
  always "   -> UNANSWERED: this boot did not name the modem firmware (section 1 read UNREADABLE or"
  always "      EMPTY), so the file names every later check compares against are unknown. Nothing here"
  always "      says the modem is broken. Re-run on a boot whose device tree has the mss node."
  exit 1
elif [ "$KLOG_OK" = 0 ]; then
  always "   -> UNANSWERED: the kernel log could not be read, so the load question has no answer. The"
  always "      static readings above (sections 1-3) are still valid; the verdict is not."
  exit 1
elif [ -n "$FOUND_AT" ]; then
  always "   -> THE FIRMWARE IS REACHABLE at ${FOUND_AT}, and the kernel log above says what happened"
  always "      next. Read the pil/mss lines: if the load is failing, the reason is there and the"
  always "      firmware would be the wrong thing to suspect; qcom,pil-self-auth is set on this node, so"
  always "      a signature/TZ failure is the first candidate and it logs."
  exit 0
elif [ "$MOUNTED" -gt 0 ]; then
  always "   -> THE PARTITION IS MOUNTED somewhere but the firmware is not on the kernel's search path."
  always "      This is the shape to expect when a mount WAS made but the path this boot was TOLD is a"
  always "      different one -- and section 2's two headings are what tell those apart: the cmdline's"
  always "      path is what was in force at probe time, the sysfs parameter is what the kernel has now."
  always "      The fix is at the MOUNT: halium's fstab-driven loop (section 3), or a bind mount of the"
  always "      firmware directory onto the path the cmdline names. It is NOT a change to the boot image"
  always "      -- this device's cmdline already names the right directory -- and it is NEVER a write to"
  always "      the modem partition, which holds the calibration and the IMEI."
  exit 0
else
  always "   -> THE FIRMWARE IS NOT REACHABLE AND NOTHING HAS MOUNTED THE MODEM PARTITION on this boot."
  always "      That is a complete explanation for a modem that never comes up, and it is a port"
  always "      problem (a mount), not a hardware one. Confirm against the log: a request_firmware"
  always "      failure naming ${FW_NAME} is the corroboration, and ${FW_NAME}.mdt is on the modem"
  always "      partition as IMAGE/MODEM.MDT (the FAT root holds IMAGE/, so the mounted path has one"
  always "      more component than the partition root)."
  case "$CMDPATH" in
  UNREADABLE)
    always "      What this boot was told is UNKNOWN (/proc/cmdline could not be read), so the probe does"
    always "      not say whether the path it was given exists. That is a reading to take again, not a no.";;
  EMPTY)
    always "      This boot was given no firmware_class.path at all, so the kernel searched only its"
    always "      built-in list and none of those directories exists on this rootfs.";;
  *)
    always "      What this boot WAS given points at:"
    always "        ${CMDPATH}   ($(ex "$CMDPATH"))"
    always "      so the kernel looked in a directory that nothing had created. Two mechanisms can do that"
    always "      and section 3 measures both: halium's mount loop reading an fstab that is not on this"
    always "      device at all, or a container that mounted the partition in a mount namespace the kernel"
    always "      does not resolve firmware paths in.";;
  esac
  exit 0
fi
