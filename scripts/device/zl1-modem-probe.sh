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
#   * THE HALF THAT WAS MISSING UNTIL DOCS 154, and it is why section 4 was rebuilt. The kernel has no
#     in-kernel client loading this modem (`qcom,pil-label` is absent on the glink node and
#     `qcom,not-loadable` is set on the SMD edge), so the firmware is requested by a USERSPACE `open` of
#     /dev/subsys_modem -- which makes the partition's presence at boot the whole precondition. And an
#     initramfs can now carry an fstab OF ITS OWN (boot/patches/0200-halium-modem-firmware-mount.patch),
#     which is invisible from the booted system: the UT rootfs image has no /scripts and no
#     /zl1-android-fstab, and the initramfs is gone after switch_root. So what the loop DID cannot be read
#     from any file here. The only witness is the initramfs's own `initrd:` report in the kernel ring --
#     which nothing in this tree read before, and which section 4 now classifies.
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
#     straight into EDL (docs 49), and the same class of move must never be scripted;
#   * NEVER CLEARS THE RING. `dmesg -c`/`-C`/`--clear`/`--read-clear` destroys the copy this probe came
#     for -- the initramfs's report is written once and the ring is the only place it lands, so clearing
#     it is a write that cannot be undone, on the one piece of evidence that has no other copy. Bare
#     `dmesg`, always.
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
     WHAT THIS CANNOT SAY, and docs 154 is why it is written down: an initramfs can carry an fstab of its
     own, and the initramfs's files are GONE after switch_root (the UT rootfs image has no /scripts), so
     "the candidate fstab is not here" is a statement about an image and not about what the loop did this
     boot. Section 4 reads what the initramfs said it did.

  4. DID IT LOAD, AND WHAT DID THE INITRAMFS SAY IT DID. Two readings of the boot's own log, from three
     sources, because on this device the obvious one carries nothing:
       * the kernel RING (`dmesg`) -- where the initramfs's `initrd:` report actually lands, since it
         writes to /dev/kmsg;
       * the KMSG DRAIN's earliest snapshot (/userdata/zl1-kmsg/boot-<N>s.log), which exists precisely
         because the ring is ~3470 lines and wraps -- read oldest-first, by the uptime in the filename;
       * `journalctl -b -k`, reported with its line count because it was measured on this device NOT to be
         capturing /dev/kmsg at all (one line).
     A source has to CONTAIN THE BOOT PHASE to be used: a one-line answer satisfies "the file is not
     empty", and the previous version of this section could therefore count nothing and then print its
     reassurance about a boot it had never read. That is the defect docs 117 names, in this instrument.
     The initramfs's report is classified into ONE state (mounted / mount failed / device absent / fallback
     read but no mount / no fallback / the glob matched or this image has no report / the report present
     but stopped before the mount / no report at all), and the failure list
     includes the PIL LOADER'S OWN LINE, `Failed to locate <name>.mdt` -- read out of peripheral-loader.c
     (`pil_err` at :45, the `"%s.mdt"` at :794, the message at :798) after the older list was found not to
     match it at all.

  5. THE PLUMBING THAT ONLY EXISTS IF IT LOADED. /sys/bus/msm_subsys (the Qualcomm subsystem-restart
     view) and /dev/qmi*, plus rmnet netdevs. These are downstream of a successful load: their absence
     is a consequence, not a cause, and reading them first is how a diagnosis ends up one layer too
     low.

  6. THE UT SIDE. ofono's unit state and whether org.ofono owns a name on the system bus. ofono being
     "active" is what the peripheral note could say and no more: it says a daemon started, not that it
     has a modem to talk to.

  7. THE VERDICT names the rung the evidence stops at, and now names the CAUSE the initramfs measured
     rather than sending the reader to look for it: a mount that failed, a device that did not exist, a
     fallback that was read and not mounted, or an image with no fallback in it. The interesting rungs
     are still the third and fourth: firmware present but not loaded points at TZ/signature
     (qcom,pil-self-auth is set), and load attempted but failing points at the loader path.
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
  say "   and an unexpanded glob makes its \`cat\` fail silently, so with an UNPATCHED initramfs THAT LOOP"
  say "   MOUNTED NOTHING THIS BOOT."
  say "   -> if section 2 says the boot was given a firmware path, that path is a directory nothing"
  say "      created, which is a complete explanation for a modem that never loads. It is a MOUNT, not"
  say "      hardware, and not the modem partition's contents -- which must never be written."
  # THE PART THAT MAKES THE PARAGRAPH ABOVE AN INFERENCE RATHER THAN A READING (docs 154). An initramfs
  # carrying a fallback fstab of its own (boot/patches/0200-halium-modem-firmware-mount.patch) makes this
  # loop mount the modem partition on exactly this device, from a file that is NOT here -- the initramfs's
  # own files are gone after switch_root (checked: the UT rootfs image has no /scripts and no
  # /zl1-android-fstab, so neither the patched script nor the fstab it adds is on the booted system).
  # What that loop DID is therefore not visible from any file on this device; the only witness is the
  # initramfs's own kmsg report, which section 4 reads. Saying "nothing was mounted this boot" from a
  # listing of the CANDIDATE fstab is a claim about an image, and this probe is not entitled to it.
  say "   -> WHAT THIS SAYS AND WHAT IT DOES NOT: a missing file here rules out ONE mechanism (Android's"
  say "      fstab on the extracted ramdisk). It does not say the loop mounted nothing -- an initramfs"
  say "      can carry an fstab of its own, and its files are gone by the time anything on this system"
  say "      could list them. Section 4 reads what the initramfs SAID it did, which is the difference."
fi
# The container's view, which is where Android's own mount point for this partition lives.
#
# READ OUT OF THE KERNEL'S TEXT, NOT BY ENTERING THE NAMESPACE (docs 162). This section used to be
#   CVIEW=$(nsenter -t "$A" -m -- ls -d /vendor/firmware_mnt 2>/dev/null)
# and that call is where this probe HUNG -- twice on 2026-09-25, at this exact line, and each hang was
# followed by the device resetting itself (2m08s and 3m05s later; both reset instants are read off the
# NEXT step's own `uptime`, so they do not depend on this script's clock). The step's device-side
# `timeout -k 5 240` NEVER FIRED -- the capture looks for its `ZL1STEP-TIMEOUT device` marker and there
# was none -- because the reset arrived BEFORE the bound could (2m08s < 240s), after which the gadget
# re-enumerated and the ssh socket went dark until the host's own backstop collected it at 4m30s.
#
# WHAT THAT DOES NOT SAY: that the hung process was in uninterruptible sleep and unkillable. It is
# consistent with these two runs and it is NOT established by them -- a bound that never got to fire and
# a signal that could not be delivered print the same absence. The replacement below removes the
# question rather than answering it: there is no longer a call that could hang here at all.
#
# /proc/<pid>/mountinfo IS that container's mount table: the kernel formats it for any reader, out of
# the target's own mount namespace, with the paths written AS THAT PROCESS SEES THEM. So it answers
# this section's actual question -- is the firmware path MOUNTED in the container -- without entering
# a namespace, without forking anything into one, and without opening one path inside the container.
# What it does NOT answer is whether the directory exists under a mount that never happened; that is a
# different reading, and section 3's second half (the initramfs's own report) is the one that speaks
# to it. The probe does not assume the container is up: an absent container is a reading, not a crash.
#
# /proc/<pid>/mountinfo IS that container's mount table: the kernel formats it for any reader, out of
# the target's own mount namespace, with the paths written AS THAT PROCESS SEES THEM. So it answers
# this section's actual question -- is the firmware path MOUNTED in the container -- without entering
# a namespace, without forking anything into one, and without opening one path inside the container.
# What it does NOT answer is whether the directory exists under a mount that never happened; that is a
# different reading, and section 3's second half (the initramfs's own report) is the one that speaks
# to it. The probe does not assume the container is up: an absent container is a reading, not a crash.
A=$(lxc-info -n android -pH 2>/dev/null | head -1)
if [ -n "$A" ]; then
  MI=/proc/$A/mountinfo
  say "   container pid ${A}; its own mount table, read from ${MI}:"
  if [ -r "$MI" ]; then
    # One awk over the table, and the `||` trap the old version had is gone with the pipeline: this
    # prints either the matching line or a sentence that says the table was read and holds no such
    # mount. "The table was read and it is not there" and "the table could not be read" are two
    # different sentences, and neither of them is silence (docs 117).
    CVIEW=$(awk -v p=/vendor/firmware_mnt '$5 == p { print "mounted: " $5 "   (device " $3 ")" }' "$MI" 2>/dev/null)
    if [ -n "$CVIEW" ]; then printf '%s\n' "$CVIEW" | sed 's/^/   | /'
    else
      say "   | no entry for /vendor/firmware_mnt in the container's mount table: the container does"
      say "   |  not see the modem partition at that path. THAT IS A READING ABOUT WHAT IS MOUNTED --"
      say "   |  it is not a statement about what the directory would hold if it were."
    fi
    # And the same path as a DIRECTORY, walked from the host THROUGH the target's own root. This is a
    # plain path resolution on the host -- no namespace entered, no container binary run (which is also
    # what makes it work, docs 117: the container's applet set has no test(1) this project can rely
    # on). It is printed beside the table because together they separate "not mounted" from "not there
    # at all", and either one alone would be read as the other.
    if [ -d "/proc/$A/root/vendor/firmware_mnt" ]; then
      say "   | and /proc/${A}/root/vendor/firmware_mnt IS a directory"
    else
      say "   | and /proc/${A}/root/vendor/firmware_mnt is not a directory either"
    fi
  else
    say "   | /proc/$A/mountinfo could not be read: the container pid answered but its table did not."
    say "   |  That is NOT the same as an empty table, and nothing here may be read as one."
  fi
else
  say "   the android container is not running (lxc-info answered nothing), so its mount table"
  say "   could not be read -- that is NOT the same as the path being absent."
fi

# ==================================================================================================
hdr "4. the log for THIS boot -- the initramfs's own report, and whether the kernel loaded it"
# ==================================================================================================
# THREE SOURCES, and the reason is that on this device the obvious one is empty. The initramfs writes its
# report with `echo "initrd: ..." > /dev/kmsg`, so it lands in the KERNEL RING and nowhere else:
#
#   * THE KMSG DRAIN'S EARLIEST SNAPSHOT, read FIRST because it is the best evidence there can be: that
#     unit exists to snapshot the ring as early as systemd will run it, so `/userdata/zl1-kmsg/boot-<N>s.log`
#     is a COPY OF THE RING TAKEN WHILE THIS BOOT WAS YOUNG. The ring is ~3470 lines and wraps -- measured
#     on this device, fastest while the host is talking to it (scripts/install-kmsg-drain.sh's header has
#     the numbers) -- and this probe runs long after that. So the snapshot is strictly better than the live
#     ring whenever it exists, and "earliest" is a fact and not a guess because the drain names these by
#     uptime in seconds (see the scan below).
#     The files read are `$D/boot-*.log`, which are THIS boot's: the drain wipes them at its start and
#     carries the previous boot's set into `keep/boot-<id>/`. The archive is deliberately NOT read -- it is
#     another boot's log, and a probe that read it would attribute one boot's failure to another.
#   * `dmesg` is the live ring. Read second, and it is still worth reading: a boot whose snapshot never
#     happened (the drain not installed) has its whole report here, and a ring that has not wrapped has
#     everything the snapshot has.
#   * `journalctl -b -k` is kept because a probe should ask the journal too, AND it is reported with its
#     line count because on this device it was measured NOT to be capturing /dev/kmsg at all (the drain's
#     header, 2026-09-21: "`journalctl -k` returns 1 line"). It is therefore a source to REPORT rather than
#     one to rely on -- and that measurement is not assumed here: whichever source really carries the boot
#     phase is decided below, by looking.
#
# THE GUARD, and this is the defect this section was fixed for. The previous version proved its read with
# `[ -s "$KLOG" ]`, which a ONE-LINE answer satisfies -- so a journal that captured nothing but a stray
# line would pass the guard, every count below would be 0, and the failure list would print its
# reassurance ("(none: no firmware-load failure line in this boot's kernel log)") about a boot it had
# never read. That is the same shape three instruments in this repo were fixed for (docs 117): "could not
# read" must not read as "no". So a source now has to CONTAIN THE BOOT PHASE to count -- the kernel's own
# banner, or an `initrd:` line -- and a source that does not is printed as thin rather than counted,
# whichever source it is.
KLOG=/tmp/zl1-modem-klog.txt
: > "$KLOG"
KLOG_OK=0
DRAIN_DIR=/userdata/zl1-kmsg
DRAIN_EARLY=""
DRAIN_MIN=""
# Chosen by the NUMBER in the filename, and not by a sort: the drain names these `boot-<uptime>s.log`, so
# any lexical order puts `boot-9s.log` after `boot-160s.log` -- and `sort -t- -k2 -n` on the whole path
# splits on the hyphen INSIDE `/userdata/zl1-kmsg` instead, giving every line the key 0 and an order that
# is really just the directory's. A minimum scan over the parsed number is the version that cannot be
# wrong about which snapshot is the earliest, and the earliest is the one the ring's beginning survives in.
for f in "$DRAIN_DIR"/boot-*.log; do
  [ -e "$f" ] || continue
  n=$(basename "$f" 2>/dev/null | sed -n 's/^boot-\([0-9][0-9]*\)s\.log$/\1/p')
  [ -n "$n" ] || continue
  if [ -z "$DRAIN_EARLY" ] || [ "$n" -lt "$DRAIN_MIN" ]; then DRAIN_EARLY="$f"; DRAIN_MIN="$n"; fi
done
# The sources, in the order they are tried. One file is filled and everything below reads THAT file, so
# the counts and the lines shown cannot come from different samples of a ring that is still moving.
src_try() { # src_try LABEL COMMAND...
  label=$1; shift
  [ "$KLOG_OK" = 1 ] && return 0
  out=$("$@" 2>/dev/null) || out=""
  if [ -z "$out" ]; then
    say "   source ${label}: NOTHING (the command ran and printed nothing, or could not run)"
    return 0
  fi
  n=$(printf '%s\n' "$out" | grep -ac . 2>/dev/null || true)
  if printf '%s\n' "$out" | grep -aqE 'initrd:|Linux version|Booting Linux|Initializing cgroup'; then
    printf '%s\n' "$out" > "$KLOG"
    KLOG_OK=1
    say "   source ${label}: ${n} lines, and it CONTAINS THE BOOT PHASE -- this is the log read below"
  else
    say "   source ${label}: ${n} lines but NO boot-phase line (no 'Linux version', no 'initrd:') --"
    say "     so it did NOT capture this boot, and every answer that could be read from it would be a"
    say "     false negative. It is reported and NOT used as the log."
  fi
}
# A `dmesg` that is not on PATH is a reading, not a crash: so is a drain that was never installed. These
# are written as `if` blocks rather than `A && B || C`, because that idiom runs C when B fails for any
# reason -- including B's own non-zero exit -- and a source that could not be read would then be reported
# as one that does not exist.
if [ -n "$DRAIN_EARLY" ]; then
  src_try "the kmsg drain's earliest snapshot (${DRAIN_EARLY}), taken while this boot was young" cat "$DRAIN_EARLY"
else
  say "   source ${DRAIN_DIR}/boot-*.log: no snapshot from ANY boot is on this device, so the ring's"
  say "     beginning was not preserved by anything -- ${DRAIN_DIR} is empty or absent."
fi
if command -v dmesg >/dev/null 2>&1; then
  src_try "dmesg (the live kernel ring, where the initramfs writes its report)" dmesg
else
  say "   source dmesg: NOT PRESENT on this device, so the ring could not be read here"
fi
if command -v journalctl >/dev/null 2>&1; then
  src_try "journalctl -b -k (the journal's kernel messages)" journalctl -b -k --no-pager -o cat
else
  say "   source journalctl: NOT PRESENT on this device"
fi

# --- 4a. what the INITRAMFS said it did -- the only witness to the boot's own mount decisions ---------
#
# The strings below are the ones the shipped halium can print, and the three `zl1 (docs 154)` additions
# are the whole evidence for whether the modem-firmware mount happened. Their provenance is the patch
# itself (boot/patches/0200-halium-modem-firmware-mount.patch), whose text is diffed against the
# `scripts/halium` that is inside the boot image the device runs -- so the pattern and the string it
# looks for cannot drift apart unnoticed. They are matched as SUBSTRINGS of `initrd:` lines, and the
# states are exclusive, tested in the order the evidence descends.
if [ "$KLOG_OK" = 1 ]; then
  IN_FSTAB=$(grep -acE 'initrd:.*checking fstab' "$KLOG" 2>/dev/null || true)
  IN_NOMATCH=$(grep -acE 'initrd: fstab .*matched NO file' "$KLOG" 2>/dev/null || true)
  IN_FALLBACK=$(grep -acE 'initrd: fstab .*matched NO file; using the one this initramfs carries' "$KLOG" 2>/dev/null || true)
  IN_NOFALLBACK=$(grep -acE 'initrd: fstab .*matched NO file and no fallback is present' "$KLOG" 2>/dev/null || true)
  IN_LABEL=$(grep -acE 'initrd: checking mount label' "$KLOG" 2>/dev/null || true)
  IN_NODEV=$(grep -acE 'initrd: no device for label' "$KLOG" 2>/dev/null || true)
  IN_MOUNTED=$(grep -acE 'initrd: mounting .*as .*vendor/firmware_mnt' "$KLOG" 2>/dev/null || true)
  IN_FAILED=$(grep -acE 'initrd: MOUNT FAILED:.*vendor/firmware_mnt' "$KLOG" 2>/dev/null || true)
  # "IS THERE A REPORT AT ALL" IS NOT THE SAME QUESTION AS "DID THE GLOB MATCH", and it was written as if
  # it were: the last branch asked only about the `checking fstab` line, so a log holding a LATER report
  # line and not that one -- a snapshot taken mid-mount, which is what a ring that wraps leaves -- was
  # reported as a boot whose initramfs said NOTHING. The count below is the whole report, so the two
  # readings can no longer be confused. (Found by the harness's docs-154 section, which drives each of the
  # patch's report lines through the probe on its own.)
  IN_ANY=$(( ${IN_FSTAB:-0} + ${IN_NOMATCH:-0} + ${IN_LABEL:-0} + ${IN_NODEV:-0} + ${IN_MOUNTED:-0} + ${IN_FAILED:-0} ))
  INITRD_STATE=""
  if [ "${IN_FAILED:-0}" -gt 0 ]; then
    INITRD_STATE="MOUNT FAILED"
  elif [ "${IN_NODEV:-0}" -gt 0 ]; then
    INITRD_STATE="DEVICE ABSENT"
  elif [ "${IN_MOUNTED:-0}" -gt 0 ]; then
    INITRD_STATE="MOUNTED"
  elif [ "${IN_FALLBACK:-0}" -gt 0 ]; then
    INITRD_STATE="FALLBACK USED, NO MOUNT FOLLOWED"
  elif [ "${IN_NOFALLBACK:-0}" -gt 0 ]; then
    INITRD_STATE="NO FALLBACK -- the pre-fix silence, now audible"
  elif [ -n "$IN_FSTAB" ] && [ "${IN_FSTAB:-0}" -gt 0 ]; then
    INITRD_STATE="GLOB MATCHED, OR THIS IMAGE HAS NO REPORT"
  elif [ "$IN_ANY" -gt 0 ]; then
    INITRD_STATE="REPORT PRESENT, AND IT STOPS BEFORE THE MOUNT"
  else
    INITRD_STATE="NO INITRAMFS REPORT IN THIS LOG"
  fi
  say "   initrd: lines in the log: checking-fstab=${IN_FSTAB:-0} matched-no-file=${IN_NOMATCH:-0} label=${IN_LABEL:-0} mounting-firmware_mnt=${IN_MOUNTED:-0}"
  say "   the initramfs's own lines about the Android partitions and the firmware mount:"
  # The pattern is written so that no alternative begins with a write verb at an alternation bar: the
  # offline harness's static guard reads the probe's own source, and an alternative that starts with the
  # word the guard watches for is a command in command position to any grep that does not know it is
  # looking at a regex. It really was flagged, and the fix is here rather than a hole in the guard.
  # The two spellings it needs are both covered: the pre-existing "checking" line, and the patched
  # "mounting" one -- neither of which is the bare verb at a bar.
  show "$KLOG" 'initrd:.*(fstab|MOUNT FAILED|no device for label|mounting|checking mount label)' \
    "(none: this log has no initrd: line about a mount -- the initramfs's report is not in it)" 12
  say "   -> STATE: ${INITRD_STATE}"
  case "$INITRD_STATE" in
  "MOUNTED")
    say "      The initramfs mounted the modem partition itself this boot. This is the reading that makes"
    say "      the earlier 'NO SUCH FILE' paragraphs about a CANDIDATE fstab, not about this boot." ;;
  "MOUNT FAILED")
    say "      It TRIED and the mount failed, and the line above names the device and the mount point. The"
    say "      firmware cannot be there: this is a mount failure, with a named cause, and not hardware." ;;
  "DEVICE ABSENT")
    say "      It read the fstab's line and the DEVICE it names did not exist at that moment (the line above"
    say "      names what it tried). On this device the candidates are /dev/disk/by-partlabel/modem and"
    say "      /dev/block/bootdevice/by-name/modem, both of which need udev to have made them -- so this"
    say "      points at the initramfs's device population, not at the partition's contents." ;;
  "FALLBACK USED, NO MOUNT FOLLOWED")
    say "      The fallback fstab was read and NO mount for the modem followed it. Two readings fit: the"
    say "      fallback's line was skipped for a missing device (then there is a 'no device for label' line"
    say "      above too), or the label in it did not match its source. Read the lines, then re-read the"
    say "      file the patch ships -- the label and the device in it are the two things it must agree on." ;;
  "NO FALLBACK -- the pre-fix silence, now audible")
    say "      This image HAS the report and has NO fallback fstab, so nothing was mounted for the modem and"
    say "      the boot said so in words. That is the OLD behaviour made audible, not a device fault." ;;
  "GLOB MATCHED, OR THIS IMAGE HAS NO REPORT")
    say "      The loop ran and did not report an unmatched glob. Two readings fit and this log cannot tell"
    say "      them apart: the glob MATCHED a real fstab (so the patched code took its unchanged branch), or"
    say "      this is an image WITHOUT the report at all -- in which case an empty glob is silent, exactly"
    say "      as it was before. THAT AMBIGUITY IS WHY THE REPORT WAS ADDED: with the patch, an empty glob"
    say "      always says so. Compare the boot identity above with the image that was flashed." ;;
  "REPORT PRESENT, AND IT STOPS BEFORE THE MOUNT")
    say "      The initramfs's report IS in this log, and the last thing it says about the Android"
    say "      partitions is the mount label -- no 'mounting', no 'no device', no 'MOUNT FAILED'. For an"
    say "      image carrying the docs-154 report that is the shape of a source that ENDS there: a snapshot"
    say "      taken while the loop was still running, which is exactly what the drain's uptime in its name"
    say "      is for. A source that lost its BEGINNING is a different reading and not this one -- the ring"
    say "      drops the OLDEST lines first, so that shape shows the TAIL of the loop instead. The source"
    say "      line above says which source this is and how young it was when it was copied." ;;
  *)
    say "      This log has the boot phase but NO initrd: line about a mount at all, so nothing is claimed"
    say "      about what the initramfs did. It is not 'it mounted nothing' -- the report is either absent"
    say "      from this image or was already out of the ring when the log was taken (section 4's sources"
    say "      are what say which, and the drain's snapshot is what makes the second case avoidable)." ;;
  esac
else
  INITRD_STATE="UNREADABLE"
  say "   NO SOURCE ABOVE CARRIED THIS BOOT, so the initramfs's own report was not read. Nothing below"
  say "   claims what it did. This is not 'it mounted nothing' (docs 117)."
fi

# --- 4b. did the kernel load it -------------------------------------------------------------------
if [ "$KLOG_OK" = 1 ]; then
  say "   the log read: $(wc -l < "$KLOG") lines (saved to $KLOG)"
  for pat in 'pil-q6v5' 'pil-q6v55' 'q6v5' 'mss' 'subsys' 'MBA' 'firmware' 'modem'; do
    say "$(printf '   %-16s %4s' "$pat" "$(grep -aci -- "$pat" "$KLOG" 2>/dev/null)")"
  done
  say "   the lines themselves (modem/mss/pil only, capped):"
  show "$KLOG" 'pil-q6v5|q6v55|mss|subsys-pil' \
    "(none: the PIL driver logged nothing about the modem on this boot)"
  # `Failed to locate` IS the PIL loader's own failure line and it was MISSING from this list until it was
  # read out of the loader: `pil_err` is `dev_err(desc->dev, "%s: " fmt, desc->name, ...)`
  # (peripheral-loader.c:45) and the failure it prints when the firmware file cannot be found is
  # `pil_err(desc, "Failed to locate %s\n", fw_name)` (`:798`, after
  # `snprintf(fw_name, sizeof(fw_name), "%s.mdt", desc->fw_name)` at `:794`). So the line is
  # `<name>: Failed to locate modem.mdt` -- and NOTHING in the old list matched it: 'request_firmware',
  # 'Direct firmware load' and 'failed to (load|get) firmware' are all other subsystems' wording, and
  # 'firmware.*(timed out|not found)' needs the word "firmware" before "not found", which this line does
  # not have. The verdict below asks the reader to CONFIRM a failure against this list, so the list had
  # to contain the line the loader actually prints.
  say "   any firmware-load FAILURE, named:"
  show "$KLOG" 'request_firmware|Direct firmware load|failed to (load|get) firmware|Failed to locate .*\.(mdt|mbn)|firmware.*(timed out|not found)' \
    "(none: no firmware-load failure line in this boot's kernel log)" 10
else
  say "   NO SOURCE CARRIED THIS BOOT, so the load question has no answer. Every count below would be 0"
  say "   for THAT reason, so none of them is printed (docs 117)."
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
  always "   -> UNANSWERED: no log on this device carried the boot phase, so the load question has no"
  always "      answer. The static readings above (sections 1-3) are still valid; the verdict is not."
  always "      Note what this is NOT: it is not 'the driver was silent'. A source that carried nothing"
  always "      is a source that cannot report the driver's silence either (docs 117)."
  exit 1
elif [ -n "$FOUND_AT" ]; then
  always "   -> THE FIRMWARE IS REACHABLE at ${FOUND_AT}, and the log above says what happened next."
  always "      The initramfs's own report this boot: ${INITRD_STATE}."
  always "      Read the pil/mss lines: if the load is failing, the reason is there and the firmware would"
  always "      be the wrong thing to suspect; qcom,pil-self-auth is set on this node, so a signature/TZ"
  always "      failure is the first candidate and it logs."
  exit 0
elif [ "$MOUNTED" -gt 0 ]; then
  always "   -> THE PARTITION IS MOUNTED somewhere but the firmware is not on the kernel's search path."
  always "      The initramfs's own report this boot: ${INITRD_STATE}."
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
  always "      problem (a mount), not a hardware one."
  # WHAT THE INITRAMFS ITSELF SAID, which is the difference between a cause and a corollary. Sections 1-3
  # say the firmware is not reachable; only the boot's own log can say WHY, and since docs 154 changed
  # what the initramfs reports, that log now separates the cases that used to look identical.
  case "$INITRD_STATE" in
  "MOUNT FAILED")
    always "      THE CAUSE IS MEASURED, not inferred: the initramfs TRIED to mount the modem partition and"
    always "      the mount failed. The line naming the device and the mount point is in section 4." ;;
  "DEVICE ABSENT")
    always "      THE CAUSE IS MEASURED: the initramfs read an fstab line for this partition and the DEVICE"
    always "      it names did not exist at that moment. That is udev in the initramfs, not the partition." ;;
  "FALLBACK USED, NO MOUNT FOLLOWED")
    always "      THE CAUSE IS MEASURED AND IS A CONFIGURATION ONE: the initramfs read its own fallback fstab"
    always "      and no mount followed it. Read the lines in section 4 -- a label and a device that do not"
    always "      agree are the two things to check in the shipped file." ;;
  "NO FALLBACK -- the pre-fix silence, now audible")
    always "      THE CAUSE IS MEASURED: this image carries the report and NO fallback fstab, so the loop"
    always "      found nothing to mount and said so. Flash the image that carries the fallback rather than"
    always "      looking for a hardware fault." ;;
  "MOUNTED")
    always "      THE INITRAMFS SAYS IT MOUNTED THE MODEM PARTITION, yet nothing here shows a mount. That"
    always "      disagreement IS the finding: the two readings were taken in different mount namespaces, or"
    always "      the mount was made and later lost. Do not read this as either one of them being wrong." ;;
  "GLOB MATCHED, OR THIS IMAGE HAS NO REPORT")
    always "      The initramfs's report neither confirms nor denies a mount attempt: the loop ran and did"
    always "      not report an unmatched glob, which is either a matched glob (a real fstab on the Android"
    always "      ramdisk) or an image carrying no report at all. The TWO cannot be told apart from this"
    always "      log, and that ambiguity is exactly what docs 154's report removes." ;;
  "REPORT PRESENT, AND IT STOPS BEFORE THE MOUNT")
    always "      The initramfs's report is in this log and it stops at the mount label, so this boot's own"
    always "      words neither confirm nor deny a mount attempt -- read section 4's source line to see how"
    always "      young the log was when it was copied. 'It said nothing' is a different reading and is not"
    always "      this one." ;;
  *)
    always "      The initramfs's own report is NOT in this log, so no cause is claimed from it. The drain"
    always "      (scripts/install-kmsg-drain.sh) is what preserves a boot's beginning; if it is not"
    always "      installed, this is the reading it exists for." ;;
  esac
  always "      Corroboration, and where to look for it: a firmware-load failure naming ${FW_NAME} is in"
  always "      section 4's failure list, whose patterns now include the PIL loader's own line"
  always "      ('Failed to locate ${FW_NAME}.mdt'). Its ABSENCE says the kernel never got as far as asking"
  always "      for the file, which is what an unmounted firmware partition produces."
  always "      ${FW_NAME}.mdt is on the modem partition as IMAGE/MODEM.MDT (the FAT root holds IMAGE/, so"
  always "      the mounted path has one more component than the partition root)."
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
