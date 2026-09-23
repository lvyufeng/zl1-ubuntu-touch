#!/usr/bin/env bash
# Which Android executable on this port cannot link, and is anything actually starting it?
#
# Why this exists (docs 90): the container's log has been looping on candidate answers for weeks --
#
#     F linker  : CANNOT LINK EXECUTABLE "/vendor/bin/vsimd": library "libQSEEComAPI.so" not found
#
# with the obvious refutation sitting next to it, "but /vendor/lib64/libQSEEComAPI.so exists". Docs 66
# and 70 filed that under the linker-namespace family (doc 66's DT_NEEDED transitivity, doc 55's
# pc=0x0), i.e. as something that must be diagnosed on a live device. It is not: it is decided entirely
# by what is inside the two images this port already has on the host, and the answer is the least
# interesting one -- `/vendor/bin/vsimd` is **ELF32** and the only `libQSEEComAPI.so` on the device is
# **ELF64**. A 32-bit process cannot load an ELF64 library at any search path, so the linker's "not
# found" is literal and no namespace rule can change it.
#
# That question generalises into one an image can answer for the whole Android side: **for every ELF in
# the vendor/system trees, does each DT_NEEDED resolve to a library of the same class that is actually
# present?** Two things make the output actionable rather than a list of files:
#
#   * an *executable* with an unresolved DT_NEEDED fails at exec time, every time init starts it, and
#     init keeps starting it -- that is a real, repeating failure;
#   * a *library* with an unresolved DT_NEEDED is usually a dead file left behind by a vendor-set
#     change, and whether it matters is decided by a second question: does anything in the tree
#     reference it at all? If nothing does, it is noise in a directory listing and nothing else.
#
# So the audit reports both, cross-references each broken executable against the init .rc that starts
# it, and cross-references each broken library against its consumers. The verdict is "no init-started
# executable is broken" or "these are", not a count.
#
# Read-only by construction: it reads two image files (or two already-mounted trees) and runs readelf
# and grep on them. It never writes to an image, never mounts read-write (mount is `ro,noload`, so
# not even a journal replay), and never touches the device -- /mnt/data backups are all it needs. Run
# it on the host while the phone is in EDL, which is exactly when the other instruments are useless.
#
# Usage: zl1-vendor-link-audit.sh [--images DIR] [--vendor DIR] [--system DIR] [--exec-only] [--quiet]
#   default        mount the images read-only, audit, unmount
#   --vendor DIR   audit an already-mounted tree instead (needs --system too, or just one)
#   --images DIR   where vendor.img / system.img live
#                  (default /mnt/data/zl1-backups/2026-06-07-adb-root-staged)
#   --exec-only    skip the library section: only what init starts
#   --quiet        one line per finding, no headers
#
# Exit codes: 0 nothing that init starts is broken; 1 at least one init-started executable cannot link;
#             2 the images/trees are not usable (missing, or a corrupt backup copy).

set -uo pipefail

MNT=/mnt/zl1-link-audit
# The -staged copy specifically. The 2026-06-07-adb-root-exact capture of these same partitions passes
# its own SHA256SUMS (31/31 OK) and still cannot be mounted -- `mount(2): Structure needs cleaning`,
# with debugfs seeing garbage in the inode table -- while the -staged copy of the same date opens
# fine. A checksum verifies the bytes; it does not verify that the bytes are a filesystem. Don't offer
# the corrupt one as a default, and say so if someone points at it (docs 90 section 7).
IMAGES=${ZL1_IMAGES:-/mnt/data/zl1-backups/2026-06-07-adb-root-staged}
VENDOR_DIR=${ZL1_VENDOR_DIR:-}
SYSTEM_DIR=${ZL1_SYSTEM_DIR:-}
EXEC_ONLY=0
QUIET=0
DID_MOUNT=0

while [ $# -gt 0 ]; do
  case "$1" in
  --images) IMAGES="${2:?}"; shift 2 ;;
  --vendor) VENDOR_DIR="${2:?}"; shift 2 ;;
  --system) SYSTEM_DIR="${2:?}"; shift 2 ;;
  --mount)
    # accepted for symmetry; mounting is what the default path does anyway
    shift ;;
  --exec-only) EXEC_ONLY=1; shift ;;
  --quiet) QUIET=1; shift ;;
  --help | -h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0"; exit 0 ;;
    # --help prints this file's own header: the header IS the manual (it carries the Usage line),
    # and the length of it is not something a fixed line range can know.
    --help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0" ; exit 0 ;;
  *) echo "unknown argument $1 (try --help)" >&2; exit 2 ;;
  esac
done

say() { [ "$QUIET" = 1 ] && return 0; printf '%s\n' "$*"; }
hdr() { [ "$QUIET" = 1 ] && return 0; printf '\n== %s\n' "$*"; }

# --- get two readable trees -----------------------------------------------------------------------

cleanup() {
  [ "$DID_MOUNT" = 1 ] || return 0
  for d in "$MNT/vendor" "$MNT/system"; do
    mountpoint -q "$d" 2>/dev/null && sudo umount "$d" 2>/dev/null
  done
  # sudo: the mount points were created by sudo, so an unprivileged rmdir fails and leaves an empty
  # /mnt/zl1-link-audit behind after every run.
  sudo rmdir "$MNT/vendor" "$MNT/system" "$MNT" 2>/dev/null
}
trap cleanup EXIT

if [ -z "$VENDOR_DIR" ] || [ -z "$SYSTEM_DIR" ]; then
  for f in "$IMAGES/vendor.img" "$IMAGES/system.img"; do
    [ -f "$f" ] || { echo "missing image: $f (use --images DIR)" >&2; exit 2; }
  done
  case "$IMAGES" in
  *adb-root-exact*)
    echo "WARNING: $IMAGES is the capture whose inode tables do not parse; it will not mount." >&2
    echo "         Use 2026-06-07-adb-root-staged (same date, checksums of both verify)." >&2
    ;;
  esac
  sudo mkdir -p "$MNT/vendor" "$MNT/system" || exit 2
  sudo mount -o loop,ro,noload "$IMAGES/vendor.img" "$MNT/vendor" || { echo "cannot mount vendor.img read-only" >&2; exit 2; }
  sudo mount -o loop,ro,noload "$IMAGES/system.img" "$MNT/system" || { echo "cannot mount system.img read-only" >&2; exit 2; }
  DID_MOUNT=1
  VENDOR_DIR=$MNT/vendor
  SYSTEM_DIR=$MNT/system
  say "# trees: $IMAGES/vendor.img -> $VENDOR_DIR (ro,noload)"
  say "#        $IMAGES/system.img -> $SYSTEM_DIR (ro,noload)"
fi
[ -d "$VENDOR_DIR/lib" ] || [ -d "$VENDOR_DIR/lib64" ] || { echo "not a vendor tree: $VENDOR_DIR" >&2; exit 2; }

# --- the sweep ------------------------------------------------------------------------------------

# The search paths an Android linker actually uses for each class. Deliberately only the two real ones
# per class: on this port there is no /odm, no /vendor/lib*/vndk-*, and no egl dir that anything in
# bin/ links against (checked in doc 90). If one is added later, add it here rather than widening the
# grep -- a fuzzy answer here is worse than a missing directory.
sonames() {
  for d in "$@"; do [ -d "$d" ] && ls "$d" 2>/dev/null; done | sort -u
}
L32=$(sonames "$VENDOR_DIR/lib" "$SYSTEM_DIR/lib")
L64=$(sonames "$VENDOR_DIR/lib64" "$SYSTEM_DIR/lib64")
# Space-joined, with a leading and trailing space, so a membership test is a `case` pattern match
# rather than `printf | grep -qx`. That is not a micro-optimisation: the grep version was measured
# *flaky* here -- the same image, audited twice, reported different unrelated executables as broken
# (run to run, libcutils/libm/libdl "missing" from files that plainly resolve), because the pipeline's
# exit status under `set -o pipefail` is not a reliable boolean when the writer can be signalled. A
# `case` match has one exit status and no writer. Trusting the flaky version would have meant
# publishing a list of port faults that do not exist.
SP32=" $(printf '%s' "$L32" | tr '\n' ' ') "
SP64=" $(printf '%s' "$L64" | tr '\n' ' ') "

# readelf, not `file`: we need the ELF class the *linker* will use, and a truncated or wrongly-copied
# file must count as unknown rather than be guessed at. One `readelf -hd` per file returns both the
# header and the dynamic section, which halves the process count -- over ~1500 executables and ~2000
# libraries that is the difference between an audit and a coffee break. No sudo: everything under
# lib*/ and bin*/ in both images is world-readable (the one exception is build.prop, which is 0600 and
# which this audit has no reason to open).
ELF_CLASS=""
ELF_NEEDED=""
elf_info() {
  local info
  info=$(readelf -hd "$1" 2>/dev/null) || return 1
  [ -n "$info" ] || return 1
  ELF_CLASS=$(printf '%s\n' "$info" | awk -F: '/Class:/{gsub(/ /,"",$2); print $2}')
  [ -n "$ELF_CLASS" ] || return 1
  ELF_NEEDED=$(printf '%s\n' "$info" | sed -n 's/.*NEEDED.*\[\(.*\)\].*/\1/p' | tr '\n' ' ')
  return 0
}

# Print "<class> <space-separated missing>" on stdout, empty if it resolves.
missing_deps() {
  local a m="" n
  elf_info "$1" || return 0
  case "$ELF_CLASS" in
  ELF32) a=$SP32 ;;
  ELF64) a=$SP64 ;;
  *) return 0 ;;
  esac
  for n in $ELF_NEEDED; do
    case "$a" in *" $n "*) ;; *) m="$m $n" ;; esac
  done
  [ -n "$m" ] && printf '%s %s' "${ELF_CLASS#ELF}" "$m"
  return 0
}

# Which init .rc would start this binary? Vendor/system rc files name the *in-container* path, so the
# mount prefix has to be stripped or the lookup silently finds nothing (which is how a first draft of
# this audit reported vsimd as "not started" while init was restarting it every few seconds).
init_rc_for() {
  local rel=$1
  grep -rl " $rel$" "$VENDOR_DIR/etc/init" "$SYSTEM_DIR/etc/init" 2>/dev/null | head -1 |
    sed "s#$VENDOR_DIR#/vendor#; s#$SYSTEM_DIR#/system#"
}

# Is this library referenced by anything at all? A plain byte grep is enough and is much faster than
# readelf on ~2000 files: an Android DT_NEEDED is a literal string in .dynstr, so a consumer contains
# the soname verbatim. `--binary-files=text` keeps grep from skipping ELFs. Only the bin/lib trees are
# searched -- the rest of the system image (4 GB of framework and apps) cannot hold a DT_NEEDED, and
# scanning it would turn this audit into a coffee break.
#
# Each referencer is printed with *its* ELF class, because a soname in DT_NEEDED is class-free: a
# 64-bit library that needs "libdsi_netctrl.so" gets the 64-bit one, whatever the 32-bit directory
# holds. Without that column the list reads as "these four programs are broken", when in fact all four
# are ELF64 and resolve fine from lib64 -- and the 32-bit copy they appear to need is simply not
# anybody's dependency. A same-class referencer is the only one that makes the file above a fault;
# a different-class one is evidence that a working sibling exists.
consumers_of() {
  local n=$1 c f
  grep -rl --binary-files=text -F "$n" \
    "$VENDOR_DIR/bin" "$VENDOR_DIR/lib" "$VENDOR_DIR/lib64" \
    "$SYSTEM_DIR/bin" "$SYSTEM_DIR/lib" "$SYSTEM_DIR/lib64" 2>/dev/null |
    grep -v "/$n\$" | head -6 | while IFS= read -r f; do
    c=$(readelf -h "$f" 2>/dev/null | awk -F: '/Class:/{gsub(/ /,"",$2); print $2}')
    printf '%s (%s)\n' "$(printf '%s' "$f" | sed "s#$VENDOR_DIR#/vendor#; s#$SYSTEM_DIR#/system#")" "${c:-unknown}"
  done
}

BROKEN_EXEC=0
FOUND_EXEC=0
hdr "executables whose DT_NEEDED cannot resolve (these fail at exec time, every time init starts them)"
while IFS= read -r f; do
  [ -f "$f" ] || continue
  out=$(missing_deps "$f")
  [ -n "$out" ] || continue
  FOUND_EXEC=$((FOUND_EXEC + 1))
  cls=${out%% *}
  miss=${out#* }
  rel=$(printf '%s' "$f" | sed "s#$VENDOR_DIR#/vendor#; s#$SYSTEM_DIR#/system#")
  rc=$(init_rc_for "$rel")
  # Counted before the branch: in --quiet mode there is no per-finding text, and an earlier draft
  # incremented the counter only inside the verbose branch, so `--quiet` printed the finding and then
  # reported "no executable that init starts is broken" with exit 0. The verdict must not depend on
  # how much of the report was printed.
  [ -n "$rc" ] && BROKEN_EXEC=$((BROKEN_EXEC + 1))
  if [ "$QUIET" = 1 ]; then
    printf '%s  ELF%s  missing:%s  %s\n' "$rel" "$cls" "$miss" "${rc:+started by $rc}"
  else
    printf '  %-44s ELF%-3s missing:%s\n' "$rel" "$cls" "$miss"
    if [ -n "$rc" ]; then
      printf '  %-44s -> started by %s\n' "" "$rc"
    else
      printf '  %-44s -> no init .rc references it: nothing starts it, it is a dead file\n' ""
    fi
  fi
done < <(find "$VENDOR_DIR/bin" "$SYSTEM_DIR/bin" -type f 2>/dev/null | sort)
[ "$FOUND_EXEC" != 0 ] || say "  (none)"

if [ "$EXEC_ONLY" != 1 ]; then
  hdr "libraries whose DT_NEEDED cannot resolve (dead unless something loads them)"
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    out=$(missing_deps "$f")
    [ -n "$out" ] || continue
    cls=${out%% *}
    miss=${out#* }
    rel=$(printf '%s' "$f" | sed "s#$VENDOR_DIR#/vendor#; s#$SYSTEM_DIR#/system#")
    base=$(basename "$f")
    cons=$(consumers_of "$base")
    if [ "$QUIET" = 1 ]; then
      printf '%s  ELF%s  missing:%s  %s\n' "$rel" "$cls" "$miss" \
        "$([ -n "$cons" ] && echo "referenced by $(printf '%s' "$cons" | tr '\n' ';')" || echo "referenced by nothing")"
    else
      printf '  %-44s ELF%-3s missing:%s\n' "$rel" "$cls" "$miss"
      if [ -n "$cons" ]; then
        # Line by line: each referencer carries its own ELF class in brackets, so the entry has to
        # survive as one line rather than being word-split into "path" and "(ELF64)".
        while IFS= read -r c; do printf '  %-44s <- referenced by %s\n' "" "$c"; done <<EOF
$cons
EOF
      else
        printf '  %-44s <- referenced by nothing in either tree: dead file, not a fault\n' ""
      fi
    fi
  done < <(find "$VENDOR_DIR/lib" "$VENDOR_DIR/lib64" "$SYSTEM_DIR/lib" "$SYSTEM_DIR/lib64" -maxdepth 1 -type f 2>/dev/null | sort)
fi

hdr "verdict"
if [ "$BROKEN_EXEC" = 0 ]; then
  say "no executable that init starts has an unresolved dependency. Any finding above is a library"
  say "nothing loads, or an executable nothing starts -- record it, do not chase it."
  exit 0
fi
say "$BROKEN_EXEC executable(s) that init starts cannot link. That is a repeating failure, and it is"
say "decided by the images, not by anything on a running device: check the ELF class of the binary"
say "against the class of every library that could satisfy the soname, before suspecting namespaces."
exit 1
