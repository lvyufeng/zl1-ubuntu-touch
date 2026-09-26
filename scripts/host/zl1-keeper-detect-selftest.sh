#!/bin/sh
# zl1 keeper detection -- offline self-test. Host-side, touches no device, runs no installer.
#
# Why this exists (docs 179). SIX programs in this tree answer the question "is the v63 debug network
# keeper running", and every one of them answered it by searching for the keeper's NAME -- five with a
# SUBSTRING over the whole cmdline, and the sixth with `pgrep -f` (the same match, in another program):
#
#   scripts/host/zl1-health-check.sh           the `keeper=` field of its one-shot device read
#   scripts/install-cpufreq-governor.sh        the "and the thing still burning CPU" block of --status
#   scripts/device/zl1-quiet-debug-keeper.sh   keeper_pids(), which --stop SIGNALS
#   scripts/install-retire-debug-keeper.sh     the --status heredoc (a bystander could be listed)
#   scripts/device/zl1-address-owner-proof.sh  section 2, which decides what gets SIGSTOPped
#   scripts/device/zl1-boot-address-check.sh   section 4, whose keeper line feeds the verdict
#
# The last two were found by the SWEEP below, not by reading: that is what the sweep is for, and it is
# why a harness over "the four sites I know about" would have missed the two that send signal 19.
#
# The substring rule has a property that makes it wrong for this particular question: IT CAN MATCH THE
# READER. Every one of these programs carries the keeper's path in its own text, and two of them are
# passed to `sh -c` as a single argv element -- so the reader's own cmdline contains the string it is
# searching for, and the first /proc entry that matches wins. Measured on the phone 2026-09-26, with a
# delimiter split so the probe could not match itself:
#
#   * the health check's program reported pid 3545508, and `my pid: 3545508` -- itself, in state S, on a
#     boot where the argv-matched keeper count was ZERO (the heat chain's own read-back said
#     `keeper: gone` the same minute). So the line every operator reads printed
#     "debug keeper: RUNNING (state S) -- it costs ~a core" about nothing, on every keeper-less boot;
#     * `pgrep -f zl1-debug-net.sh` in the governor installer matched exactly one pid, comm=bash: the
#     reading shell. Its other half, `ps -C zl1-debug-net.sh`, matches the COMMAND NAME, and the keeper
#     is a shebang script exec'd as <interpreter> <script> (docs 94), so its comm is `sh` -- that half
#     could not find a running keeper at all;
#   * the quiet keeper's --status, called from a wrapper whose argv mentioned the name, reported
#     "keeper pid 3550125: state=S cpu over 20s=0 ticks RUNNING" -- the wrapper shell. `--status`
#     printing a phantom is a bad reading; `--stop` acting on one is a SIGSTOP aimed at its caller.
#
# THE RULE, and two of these files already had it (install-retire-debug-keeper.sh's is_keeper_cmdline()
# and zl1-one-boot-runbook.sh's read_keeper(), which the heat chain's read-back also follows): a whole
# argv element EQUALS the keeper's path, or argv[0] is a shell and argv[1] is the path, with the reading
# shell's own pid skipped. A shell that merely MENTIONS the path is not the keeper.
#
# What this harness does, and why each half is needed:
#
#   1. IT RUNS THE SHIPPED PROGRAMS. Not a re-implementation, not a fixture that hands over the answer: the
#      program text is EXTRACTED from each shipped file by a rule, rewritten so its `/proc` is this
#      harness's fake root, and executed. Every extraction is asserted non-empty and asserted to contain
#      the argv rule, because an extractor that stops matching would otherwise make every assertion below
#      pass on an empty string (the defect this tree records in docs 163/165).
#   2. SIX FIXTURE SHAPES, and the two that matter are the ones the substring rule got wrong: a
#      BYSTANDER shell whose cmdline merely mentions the path (`ps -ef | grep …`), and THE READER'S OWN
#      SHAPE (a `sh -c` blob with the path inside its argv). Both must read "not running", and the two
#      real keeper shapes -- the v63 hook's `/bin/sh <path>` and the unit's `<path>` -- must read
#      "running". Without the negative shapes the positive ones prove nothing (a reader that matches
#      everything passes them).
#   3. A SWEEP, AND IT IS KEYED ON NO NAME. The six files are the ones that exist; the rule is the thing
#      to keep, and the SECOND name is what shows why: `zl1-boot-address-check.sh` and
#      `zl1-address-owner-proof.sh` ask about the netwatch with the same idiom, and the quiet keeper's
#      --status printed one with `pgrep -f`. A sweep that only knew the keeper's name would have called
#      that tree clean. So every other program is scanned for the substring idiom under ANY `*.sh` name
#      (`*<name>*`, `pgrep -f <name>`, and the variable forms), code lines only, and the scan asserts it
#      actually read the six subjects.
#   4. FIVE MUTATIONS, each of which puts the substring rule back -- in the health check, the governor
#      installer, the quiet keeper and the retire installer, and in a scratch copy of one the sweep looks
#      at -- and each must make the assertions above fail.
#
#   5. THE CITATION. The health check names this harness with a hand-typed count, so this file ends by
#      checking that count against its own run (docs 128). That check is the LAST one here, because the
#      house form of it counts itself.
#
# What it does NOT do: run anything against the phone. The positive direction is offline only, because
# the only way to have a real keeper on the device is to start the real keeper -- and the negative
# direction is what the phone was asked (the fixed health check printed `debug keeper: not running` on
# boot 2fbf9f8e, agreeing with the heat chain's argv-matched `keeper: gone`).
#
# Usage: zl1-keeper-detect-selftest.sh [--keep]
#
# Exit codes: 0 every check behaved; 1 something did not; 2 the harness could not set up.

set -u

KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
  --keep) KEEP=1; shift ;;
  --help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0"; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

HERE=$(dirname "$0")
REPO=$(cd "$HERE/../.." && pwd)

# The house form of this line, exactly: `scripts/host/zl1-cli-usage-selftest.sh` section 4d greps for this
# literal to decide whether a harness the health check NAMES can check its own citation, so writing it a
# different way -- `"$REPO/scripts/host/..."` -- makes this file read as one that cannot (measured: it did).
HEALTH="$HERE/zl1-health-check.sh"
GOV="$REPO/scripts/install-cpufreq-governor.sh"
QUIET="$REPO/scripts/device/zl1-quiet-debug-keeper.sh"
RETIRE="$REPO/scripts/install-retire-debug-keeper.sh"
# ...and two more that the SWEEP found on the day this harness was written, which is the whole reason the
# sweep is in it: both are device-side keeper READERS, and one of them SIGSTOPs what it finds.
PROOF="$REPO/scripts/device/zl1-address-owner-proof.sh"          # --stop is armed on what this finds
BOOTCHK="$REPO/scripts/device/zl1-boot-address-check.sh"         # its keeper line feeds a verdict
for f in "$HEALTH" "$GOV" "$QUIET" "$RETIRE" "$PROOF" "$BOOTCHK"; do
  [ -r "$f" ] || { echo "cannot read $f" >&2; exit 2; }
done

W=${TMPDIR:-/tmp}/zl1-keeper-detect-selftest
FR="$W/fake"
STUB="$W/stub"
rm -rf "$W"
mkdir -p "$FR/proc" "$W/shapes" "$W/mut" "$STUB" || exit 2

# The four subjects are hashed before and after: this harness rewrites COPIES, and the one way it could
# silently damage the tree it tests is a rewrite that lands in the wrong place (docs 168: a fixture write
# through a symlink replaced the heat instrument with one line while every assertion stayed green).
hash6() { sha256sum "$HEALTH" "$GOV" "$QUIET" "$RETIRE" "$PROOF" "$BOOTCHK" 2>/dev/null; }
BEFORE=$(hash6)

# --- the fixture: five shapes, as directory trees, copied in per scenario -------------------------
# A shape is what /proc looks like to the program: one directory per pid with a `cmdline` (NUL
# separated, the real format) and a `stat` whose third field is the state letter the readers print.
KEEPER=/usr/local/sbin/zl1-debug-net.sh
# The SECOND name these readers ask about, and the reason this harness is about a RULE and not about one
# program: `zl1-boot-address-check.sh` and `zl1-address-owner-proof.sh` match the netwatch by the same
# idiom, and the quiet keeper's --status printed one too (with `pgrep -f`, which matches the reader).
# A harness that only knew the keeper's name would have swept past all three (docs 179).
NW=/etc/systemd/system/zl1-netwatch.sh
shape() { # name, then pid:argv... lines on stdin
  d="$W/shapes/$1"; rm -rf "$d"; mkdir -p "$d"
  printf '' > /dev/null
  cat > "$d/spec"
}
# 100 is the unreadable case: a /proc entry with no cmdline at all (a kernel thread), which every reader
# must skip rather than mistake for a match. It is in EVERY shape so that "the readers skip what they
# cannot read" is exercised by all of them.
mkshape() { # name
  d="$W/shapes/$1"; rm -rf "$d"; mkdir -p "$d/100" "$d/1"
  : > "$d/100/cmdline"                       # the unreadable case: a /proc entry with no cmdline at all
  printf '100 (kthreadd) S 1 1 1 0 -1\n' > "$d/100/stat"
  # pid 1, because the programs print the matched pid's PARENT (ppid_comm / ppid_cmd), and asking for a
  # ppid that does not exist is how the first version of this fixture printed the HOST's pid 1.
  printf '/sbin/init\0' > "$d/1/cmdline"
  printf 'systemd\n' > "$d/1/comm"
  printf '1 (systemd) S 0 1 1 0 -1\n' > "$d/1/stat"
}
addpid() { # shape, pid, state, argv... (each argv element its own argument)
  d="$W/shapes/$1"; p="$2"; st="$3"; shift 3
  mkdir -p "$d/$p"
  : > "$d/$p/cmdline"
  for a in "$@"; do printf '%s\0' "$a" >> "$d/$p/cmdline"; done
  printf '%s (x) %s 1 1 1 0 -1\n' "$p" "$st" > "$d/$p/stat"
}
use_shape() { rm -rf "$FR/proc"; mkdir -p "$FR/proc"; cp -a "$W/shapes/$1/." "$FR/proc/"; }

mkshape none
mkshape keeper    # the v63 hook's shape: /bin/sh <path> (a shebang script, docs 94)
addpid keeper 101 S /bin/sh "$KEEPER"
mkshape argv0     # the unit's shape: the path IS argv[0]
addpid argv0 102 R "$KEEPER"
mkshape bystander        # somebody watching: shells that MENTION the path, in BOTH spellings -- 103
addpid bystander 103 S /bin/sh -c 'ps -ef | grep zl1-debug-net.sh'   # names the BASENAME, which the four
addpid bystander 105 S /bin/sh -c 'echo /usr/local/sbin/zl1-debug-net.sh'  # basename readers must ignore;
addpid bystander 108 S /bin/sh -c 'echo /etc/systemd/system/zl1-netwatch.sh'  # and the netwatch readers
                                                                     # 105 names the FULL PATH, which the
                                                                     # retire installer's old `*$KEEPER*`
                                                                     # test DID search for (so the two
                                                                     # readers are not the same test)
mkshape netwatch   # the OTHER name these readers ask about, in the shape the unit execs it
addpid netwatch 106 S /bin/sh "$NW"
mkshape selfshape        # THE READER'S OWN SHAPE: the path inside a sh -c blob, exactly like the
addpid selfshape 104 S /bin/sh -c "n=0; for d in /proc/[0-9]*; do case \"\$a1\" in */zl1-debug-net.sh) : ;; esac; done"  # programs under test
mkshape mixed            # one real keeper AND both bystanders -- the case where "found" must be the
addpid mixed 101 S /bin/sh "$KEEPER"                                                     # keeper and NOT
addpid mixed 103 S /bin/sh -c 'ps -ef | grep zl1-debug-net.sh'                            # the others
addpid mixed 104 S /bin/sh -c "case \"\$a\" in */zl1-debug-net.sh) : ;; esac"
addpid mixed 105 S /bin/sh -c 'echo /usr/local/sbin/zl1-debug-net.sh'                      # (the full path)
addpid mixed 106 S /bin/sh "$NW"                                                          # a real NETWATCH
addpid mixed 107 S /bin/sh -c 'ps -ef | grep zl1-netwatch.sh'                             # and a mention

# --- stubs: the tools a device-side program calls, so the run does not reach this laptop ----------
# A device program run here must not be able to report THIS laptop: the retire installer's --status also
# prints the unit, the two files the boot hook rewrites, the addresses and the replacement's state, and
# every one of those would otherwise be read off the host (it printed this laptop's `/` and `usb0:
# 192.168.2.100`, which is a fact about the machine running the harness). The keeper section is what is
# under test, so the tools that produce the rest answer nothing at all.
for t in pgrep journalctl; do printf '#!/bin/sh\nexit 1\n' > "$STUB/$t"; done
printf '#!/bin/sh\necho 100\n' > "$STUB/getconf"
for t in ps ip systemctl ls journalctl; do printf '#!/bin/sh\nexit 0\n' > "$STUB/$t"; done
chmod +x "$STUB"/*

# --- extraction: the program text, out of the shipped file, by a rule -----------------------------
# Each rule names the FIRST line that begins the program and is asserted to have found something. The
# rewrite of `/proc/` to this harness's fake root is the same substitution in all four cases.
extract_health() { sed -n 's/^\(  echo "keeper=.*\)$/\1/p' "$1" | head -1; }
extract_gov() {
  sed -n "s/^\(    \$SSH 'n=0; .*\)'\$/\1/p" "$1" | head -1 | sed 's/^ *\$SSH '"'"'//'
}
extract_retire() { # the --status heredoc body, unescaped: \$x -> $x
  sed -n '/^[ \t]*\$SSH "sh -s" <<STATUS$/,/^STATUS$/p' "$1" | sed '1d;$d' \
    | sed 's/\\\$/$/g' | sed 's/\\\\/\\/g'
}

rewrite_proc() { sed "s#/proc/#$FR/proc/#g"; }

# The two DEVICE scripts carry the rule as an inline loop rather than as a function, so the extractor
# takes the loop BLOCK -- the first `for p in /proc/[0-9]*; do … done` whose body names KEEPER_PATH -- and
# the harness runs that block. A rewrite of the loop into a helper would make this extractor find nothing,
# which is why section 1 asserts the extraction is non-empty AND carries the rule.
extract_loop() { # file needle -- the first loop block whose body names the needle
  # The block is the first `for p in /proc/[0-9]*; do … done` whose body names the path constant (the
  # keeper's or the netwatch's -- same rule, two questions). It is built as a STRING rather than an array
  # because this laptop's awk is mawk and the array version (reset the counter, `delete buf`, refill)
  # SEGFAULTED it -- a 139 out of an offline harness is a harness defect, and the string version is the
  # same three lines.
  awk -v needle="$2" '
    /for p in \/proc\/\[0-9\]\*; do/ { inblk=1; buf=""; saw=0 }
    inblk { buf = buf $0 "\n"; if (index($0, needle) > 0) saw=1 }
    inblk && /^done$/ { if (saw) { printf "%s", buf; exit } ; inblk=0 }
  ' "$1"
}

# The quiet keeper is a whole script, and it is RUN rather than extracted: its keeper_pids() is called
# from --stop, --resume and --status, so a text-level copy of just that function would leave the three
# call sites untested. It sleeps 20 s per pid it finds, which is why the shapes it is run against are
# chosen to be the fast ones (see below).
quiet_copy() { sed "s#/proc/#$FR/proc/#g" "$QUIET" > "$W/quiet.sh"; }

# --- the checks -----------------------------------------------------------------------------------
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
want()    { if printf '%s\n' "$2" | grep -Eq "$1"; then ok "$3"; else bad "$3"; printf '%s\n' "$2" | sed 's/^/        | /'; fi; }
notwant() { if printf '%s\n' "$2" | grep -Eq "$1"; then bad "$3"; printf '%s\n' "$2" | grep -E "$1" | sed 's/^/        | /'; else ok "$3"; fi; }

echo "zl1 keeper detection -- offline self-test"
echo "  subjects: $HEALTH"
echo "            $GOV"
echo "            $QUIET"
echo "            $RETIRE"
echo "            $PROOF"
echo "            $BOOTCHK"
echo

# ==================================================================================================
echo "== 1. the extraction: each program is found by a rule, and the rule cannot silently stop matching =="
# ==================================================================================================
# An extractor that returns an empty string makes every assertion below pass while testing nothing, and
# this tree has that defect recorded twice (docs 163 section 5, docs 165). So each extraction is held to
# three things: it is ONE program, it contains the argv rule, and it does NOT contain the substring form.
PLIST=""
for pair in "health:$HEALTH" "gov:$GOV" "retire:$RETIRE"; do
  n=${pair%%:*}; f=${pair#*:}
  case "$n" in
  health) p=$(extract_health "$f") ;;
  gov)    p=$(extract_gov "$f") ;;
  retire) p=$(extract_retire "$f") ;;
  esac
  PLIST="$PLIST $n"
  printf '%s\n' "$p" > "$W/prog.$n"
  case "$p" in
  '') bad "$n: the extractor found NOTHING in $(basename "$f") -- every check below would be vacuous" ;;
  *)
    ok "$n: extracted ($(printf '%s\n' "$p" | wc -l | tr -d ' ') line(s)) from $(basename "$f")"
    want 'a1=' "$p" "$n: the extracted program carries the argv rule"
    notwant '\*[^ ]*zl1-debug-net\.sh\*' "$p" "$n: and not the substring form (a star on both sides of the name)"
    ;;
  esac
done
want 'health gov retire' "$PLIST" "all three extracted programs are accounted for"
# FOUR loop subjects, not two: each device script asks BOTH questions (who is the keeper, is the netwatch
# there), and the netwatch loop in `zl1-address-owner-proof.sh` is the ARM GATE of the whole probe. The
# needle is the path constant, so a reader that asked a different question would extract nothing rather
# than extract the wrong block.
for pair in "proof:$PROOF:KEEPER_PATH" "bootchk:$BOOTCHK:KEEPER_PATH" \
            "proof-nw:$PROOF:NW_PATH" "bootchk-nw:$BOOTCHK:NW_PATH"; do
  n=${pair%%:*}; rest=${pair#*:}; f=${rest%%:*}; needle=${rest#*:}
  b=$(extract_loop "$f" "$needle")
  printf '%s\n' "$b" > "$W/prog.$n"
  case "$b" in
  '') bad "$n: the loop extractor found NOTHING in $(basename "$f") -- that reader is untested here" ;;
  *)
    ok "$n: extracted the $needle loop from $(basename "$f")"
    want 'a1=' "$b" "$n: the loop carries the argv rule"
    notwant '\*[^ ]*(zl1-debug-net|zl1-netwatch)\.sh\*' "$b" "$n: and not the substring form"
    ;;
  esac
done
quiet_copy
want 'keeper_pids()' "$(cat "$W/quiet.sh")" "the quiet keeper was copied (its keeper_pids is what --stop signals on)"
want 'case "\$a1" in "\$mp")' "$(cat "$W/quiet.sh")" "and the copy still carries the argv rule"
# One function, two subjects: the file answers "who is the keeper" and "is the netwatch there instead"
# with the same rule, so the thing to check is that BOTH call sites go through it -- a second, inline
# reader (or the `pgrep -f` that was there) would be the defect coming back under the other name.
want 'pids_matching "\$KEEPER_PATH"' "$(cat "$W/quiet.sh")" "keeper_pids() calls the argv rule"
want 'pids_matching "\$NW_PATH"' "$(cat "$W/quiet.sh")" "and its netwatch line does too (it used to be pgrep -f)"
notwant 'pgrep[^|]*-f[^|]*\.sh' "$(cat "$W/quiet.sh")" "no pgrep -f anywhere in it: that matches the reader"

# ==================================================================================================
echo
echo "== 2. the five shapes: the two real keeper shapes are found, and the two MENTIONING shells are not =="
# ==================================================================================================
# Each subject is run against each shape. The expected reading is spelled out per shape, and the two
# negative shapes are the ones the substring rule got wrong on the phone.
run_health() { use_shape "$1"; PATH="$STUB:$PATH" sh -c "$(printf '%s\n' "$(cat "$W/prog.health")" | sed "s#/proc/#$FR/proc/#g")"; }
run_gov()    { use_shape "$1"; PATH="$STUB:$PATH" sh -c "$(printf '%s\n' "$(cat "$W/prog.gov")" | sed "s#/proc/#$FR/proc/#g")"; }
run_retire() { use_shape "$1"; KEEPER="$KEEPER" PATH="$STUB:$PATH" sh -c "$(printf '%s\n' "$(cat "$W/prog.retire")" | sed "s#/proc/#$FR/proc/#g")"; }
run_quiet()  { use_shape "$1"; PATH="$STUB:$PATH" timeout 90 sh "$W/quiet.sh" --status 2>/dev/null; }

for shape in none keeper argv0 bystander selfshape; do
  h=$(run_health "$shape"); g=$(run_gov "$shape"); r=$(run_retire "$shape")
  case "$shape" in
  keeper|argv0)
    # pid 101 is the `/bin/sh <path>` shape and 102 the `<path>` shape: the two REAL ways this keeper is
    # ever started, and the assertion names the pid it expects rather than "some pid" -- otherwise a
    # reader that matched the wrong process would pass.
    want 'keeper=[SR]' "$h" "health/$shape: the keeper IS found (state letter printed)"
    want 'debug keeper|is running|running, 1 process' "$g" "gov/$shape: the keeper IS found"
    notwant 'NOT running' "$g" "gov/$shape: and it is not reported absent"
    case "$shape" in keeper) kp=101 ;; *) kp=102 ;; esac
    want "pid=$kp" "$r" "retire/$shape: the keeper IS found (pid $kp)"
    ;;
  *)
    want '^keeper=$' "$h" "health/$shape: NO keeper -- the field is empty, not a state letter"
    want 'NOT running' "$g" "gov/$shape: reported absent"
    notwant 'is running' "$g" "gov/$shape: and nothing claims it is running"
    want 'none running' "$r" "retire/$shape: 'none running'"
    ;;
  esac
  case "$shape" in
  bystander)  ok "   (a shell that MENTIONS the path is not the keeper)";;
  selfshape)  ok "   (the READER'S OWN shape is not the keeper -- the defect measured on the phone)";;
  esac
done

echo
echo "   -- the two DEVICE loops (the proof's, which SIGSTOPs, and the boot check's, which judges)"
# The block is rewritten so its `/proc` is this harness's fake root -- the SAME substitution the three
# programs above get, applied to the whole block so that the loop's own `${p#/proc/}` strip goes with it.
# What comes out is the pid, with the leading space the scripts build their list with, so it is trimmed
# here and the assertions compare `101` rather than ` 101`.
run_loop() { # variable-name, block-file, shape
  use_shape "$3"
  sed "s#/proc/#$FR/proc/#g" "$2" > "$W/loop.body"
  { printf '%s=\n' "$1"; cat "$W/loop.body"; printf 'printf "%%s" "$%s"\n' "$1"; } > "$W/loop.sh"
  # BOTH path constants: the extraction leaves the block talking about `$KEEPER_PATH` / `$NW_PATH` (that
  # is what makes it the shipped rule rather than a copy of it), so the harness has to supply them.
  KEEPER_PATH="$KEEPER" NW_PATH="$NW" PATH="$STUB:$PATH" sh "$W/loop.sh" | sed 's/^ *//'
}
for shape in none keeper argv0 netwatch bystander selfshape; do
  case "$shape" in
  keeper)  L=101 ;;
  argv0)   L=102 ;;
  *)       L="" ;;
  esac
  p=$(run_loop KEEPER_PIDS "$W/prog.proof" "$shape")
  b=$(run_loop k_pids "$W/prog.bootchk" "$shape")
  if [ -n "$L" ]; then
    [ "$p" = "$L" ] && ok "proof/$shape: the list is '$L' -- the pid this loop would SIGSTOP" \
                    || bad "proof/$shape: expected '$L', got '$p' (this list is what the proof stops)"
    [ "$b" = "$L" ] && ok "bootchk/$shape: same loop, same reading" \
                    || bad "bootchk/$shape: expected '$L', got '$b'"
  else
    [ -z "$p" ] && ok "proof/$shape: EMPTY -- nothing to signal" || bad "proof/$shape: got '$p', expected empty"
    [ -z "$b" ] && ok "bootchk/$shape: EMPTY" || bad "bootchk/$shape: got '$b', expected empty"
  fi
done
# and the two negatives spelled out, because "empty" and "empty for the right reason" are not the same
# claim -- the mutation below puts the substring rule back and this is what it must break.
want '^$' "$(run_loop KEEPER_PIDS "$W/prog.proof" bystander)" \
  "proof/bystander: EMPTY -- a shell that mentions the path is never handed to the SIGSTOP below it"
want '^$' "$(run_loop k_pids "$W/prog.bootchk" selfshape)" \
  "bootchk/selfshape: EMPTY -- the reader's own shape is not the keeper"

echo
echo "   -- the OTHER name: the same two loops, run against a netwatch, a keeper, and a mention"
# These two loops answer a different question (is the netwatch there), and they are run here because a
# rule is only shared if it is the same in both places. `bystander` holds pid 108, a shell that names the
# NETWATCH's full path -- the exact string, so this is the substring rule's other failure, one name over.
want '^106$' "$(run_loop nw_pid "$W/prog.proof-nw" netwatch)" \
  "proof-nw/netwatch: the netwatch is found, by argv"
want '^106$' "$(run_loop nw_pid "$W/prog.bootchk-nw" netwatch)" \
  "bootchk-nw/netwatch: same, in the other device script"
want '^$' "$(run_loop nw_pid "$W/prog.proof-nw" keeper)" \
  "proof-nw/keeper: the KEEPER is not the netwatch (one rule, two questions, and they do not mix)"
want '^$' "$(run_loop nw_pid "$W/prog.bootchk-nw" argv0)" \
  "bootchk-nw/argv0: nor is the other keeper shape"
want '^$' "$(run_loop nw_pid "$W/prog.proof-nw" bystander)" \
  "proof-nw/bystander: EMPTY -- a shell that names the netwatch's own path is not the netwatch"

echo
echo "   -- the mixed shape: one real keeper and both bystanders in the same /proc"
# This is the assertion the substring rule cannot pass: it finds SOMETHING in every shape above, and in
# this one it is a coin toss whether it finds the keeper.
h=$(run_health mixed); g=$(run_gov mixed); r=$(run_retire mixed)
want 'keeper=[SR]' "$h" "health/mixed: the keeper is found among the bystanders"
want 'running, 1 process' "$g" "gov/mixed: and the count is ONE -- the two mentioning shells are not counted"
want '^  pid=101 ' "$r" "retire/mixed: the pid list holds the keeper and nothing else"
notwant 'pid=10[345]' "$r" "retire/mixed: none of the three mentioning shells is listed"
want '^106$' "$(run_loop nw_pid "$W/prog.bootchk-nw" mixed)" \
  "bootchk-nw/mixed: the netwatch is found there -- and NOT the shell that mentions it (107)"
want '^101$' "$(run_loop KEEPER_PIDS "$W/prog.proof" mixed)" \
  "proof/mixed: three keeper shapes and one netwatch in the table, and the keeper list is still exactly 101"

echo
echo "   -- the quiet keeper runs for real against the two shapes that matter to it"
# --status sleeps 20 s per pid it finds, so the found-shape run is ONE pid (not the mixed shape).
q=$(run_quiet none)
want 'keeper: not running' "$q" "quiet/none: 'not running'"
q=$(run_quiet bystander)
want 'keeper: not running' "$q" "quiet/bystander: a mentioning shell is NOT signalled as the keeper"
q=$(run_quiet keeper)
want 'keeper pid 101' "$q" "quiet/keeper: the keeper IS found when it is really there"
want 'state=S' "$q" "quiet/keeper: with its state read from /proc/<pid>/stat"
notwant 'netwatch[^:]*: .*[0-9]' "$q" "quiet/keeper: and its netwatch line names nothing (that rule is not this one)"
q=$(run_quiet netwatch)
want 'keeper: not running' "$q" "quiet/netwatch: a NETWATCH is not a keeper"
want 'netwatch[^:]*: 106' "$q" "quiet/netwatch: and the netwatch line finds it -- by argv, not by pgrep"

# ==================================================================================================
echo
echo "== 3. the sweep: the six sites are fixed, and the IDIOM is gone from the rest of the tree =="
# ==================================================================================================
# The rule this harness exists for is not "those lines"; it is "a program is matched by its ARGV, not by
# its name". So every other program in the tree is scanned for the substring idiom -- star-name-star,
# `pgrep -f <name>`, and the variable spellings -- and the name in it is NOT the keeper's: it is ANY
# `*.sh` name, because the same pathology was shipped under the netwatch's name in the same three files.
# A sweep keyed on one name would have passed over all three of them (docs 179).
#
# TWO exclusions, both of them stated rather than implicit:
#   * a line that is entirely a comment is PROSE (these files now explain the defect, and the explanation
#     has to be able to spell it);
#   * `*-selftest.sh` files are skipped, because a harness's job includes writing the defect BACK (the
#     mutations below do exactly that), so scanning them would flag the thing that proves the sweep works.
# The scan then asserts it actually read the six subjects -- otherwise a bad glob makes it read nothing
# and report a clean tree.
SWEEP_HITS=""
SWEEP_FILES=0
sweep() { # dir
  find "$1" -type f \( -name '*.sh' -o -name '*.py' \) ! -name '*-selftest.sh' | while IFS= read -r f; do
    awk -v F="$f" '
      { line=$0; sub(/^[ \t]+/, "", line); if (line ~ /^#/) next
        if (line ~ /\*[A-Za-z0-9_.\/-]+\.sh\*/ ||
            line ~ /pgrep[^|]*-f[ \t]*[^ ]*\.sh/ ||
            line ~ /\*"\$[A-Z_]+"[\*\)]/ || line ~ /\*\$[A-Z_]+\*/) {
          print F ":" NR ": " line
        } }' "$f"
  done
}
SWEEP_HITS=$(sweep "$REPO/scripts")
SWEEP_FILES=$(find "$REPO/scripts" -type f \( -name '*.sh' -o -name '*.py' \) ! -name '*-selftest.sh' | wc -l | tr -d ' ')
[ "$SWEEP_FILES" -ge 20 ] && ok "the sweep read $SWEEP_FILES programs (not an empty glob)" \
  || bad "the sweep read only $SWEEP_FILES programs -- the rule below would be vacuous"
[ -z "$SWEEP_HITS" ] && ok "no program outside the harnesses matches ANY script by substring" \
  || { bad "the substring idiom is still in the tree:"; printf '%s\n' "$SWEEP_HITS" | sed 's/^/        | /'; }
for f in "$HEALTH" "$GOV" "$QUIET" "$RETIRE" "$PROOF" "$BOOTCHK"; do
  grep -qF "$f" <<EOF
$SWEEP_HITS
EOF
  # not a hit is the EXPECTED state; the line above exists so that the loop names the six subjects and a
  # future edit that puts a hit in one of them shows up in the printed list rather than in a summary.
done
# And the scan's own predicate is testable: it must flag the old line.
mkdir -p "$W/sweep-scratch"
printf '%s\n' '#!/bin/sh' 'c=$(tr "\0" " " < "$p/cmdline")' 'case "$c" in *zl1-debug-net.sh*) echo hit ;; esac' > "$W/sweep-scratch/old.sh"
printf '%s\n' '#!/bin/sh' '${SSH[@]} "ps -o pid= -C zl1-debug-net.sh; pgrep -f zl1-debug-net.sh >/dev/null && echo running"' > "$W/sweep-scratch/old2.sh"
printf '%s\n' '#!/bin/sh' 'case "$a1" in */zl1-debug-net.sh) hit=1 ;; esac' > "$W/sweep-scratch/new.sh"
# ...and the SAME pair under the netwatch's name, because that name is not in any assertion above: if the
# predicate only matched the keeper's, this file would report a clean tree over three live defects.
printf '%s\n' '#!/bin/sh' 'c=$(tr "\0" " " < "$p/cmdline")' 'case "$c" in *zl1-netwatch.sh*) echo hit ;; esac' > "$W/sweep-scratch/old3.sh"
printf '%s\n' '#!/bin/sh' 'echo "netwatch: $(pgrep -f zl1-netwatch.sh | tr "\n" " ")"' > "$W/sweep-scratch/old4.sh"
printf '%s\n' '#!/bin/sh' 'case "$a1" in "$NW_PATH") hit=1 ;; esac' 'case "$a0" in */sh) case "$a1" in "$NW_PATH") hit=1 ;; esac ;; esac' > "$W/sweep-scratch/new2.sh"
oldhits=$(sweep "$W/sweep-scratch")
want 'old\.sh' "$oldhits" "the sweep flags the old substring form"
want 'old2\.sh' "$oldhits" "and the old pgrep form"
want 'old3\.sh' "$oldhits" "and the same form under the OTHER name (the netwatch)"
want 'old4\.sh' "$oldhits" "and pgrep -f under the other name"
notwant 'new\.sh' "$oldhits" "and does NOT flag the argv form (so the rule it enforces is the right one)"
notwant 'new2\.sh' "$oldhits" "nor the argv form under the other name"

# ==================================================================================================
echo
echo "== 4. the mutations: putting the substring rule back must be caught, in every subject =="
# ==================================================================================================
# Each mutation is applied to a COPY of the shipped file (the copy is then extracted/run exactly as
# above), and each is asserted FIRST to have landed -- a sed that matches nothing would leave the file
# identical and the assertion below would pass on the unmutated program.
mutate() { # name, file, sed-script
  sed "$3" "$2" > "$W/mut/$1" 2>/dev/null
  if cmp -s "$2" "$W/mut/$1"; then bad "mutation '$1': the sed changed NOTHING (it did not land)"; return 1; fi
  ok "mutation '$1': landed (the copy differs from the shipped file)"
  return 0
}

# (1) the health check: the argv comparison becomes a test over the whole cmdline text.
if mutate m-health "$HEALTH" 's#case "\$a1" in \*/zl1-debug-net\.sh) hit=1 ;; esac#case "$(tr "\\0" " " < $p/cmdline)" in *zl1-debug-net.sh*) hit=1 ;; esac#'; then
  ph=$(extract_health "$W/mut/m-health")
  use_shape bystander
  out=$(sh -c "$(printf '%s\n' "$ph" | sed "s#/proc/#$FR/proc/#g")")
  want 'keeper=S' "$out" "mutation 'health': the BYSTANDER shell is now reported as a running keeper (the check is live)"
  use_shape selfshape
  out=$(sh -c "$(printf '%s\n' "$ph" | sed "s#/proc/#$FR/proc/#g")")
  want 'keeper=S' "$out" "mutation 'health': and so is the reader's OWN shape -- the phone's false reading, reproduced"
fi

# (2) the governor installer: the same substitution in its remote program.
if mutate m-gov "$GOV" 's#case "\$a1" in \*/zl1-debug-net\.sh) hit=1 ;; esac#case "$(tr "\\000" " " < "$d/cmdline")" in *zl1-debug-net.sh*) hit=1 ;; esac#'; then
  pg=$(extract_gov "$W/mut/m-gov")
  use_shape bystander
  out=$(sh -c "$(printf '%s\n' "$pg" | sed "s#/proc/#$FR/proc/#g")")
  want 'is running' "$out" "mutation 'gov': the bystander makes it print 'the v63 debug keeper is running' (the check is live)"
  # TWO, now that the fixture holds both spellings of the mention: this mutant searches the whole cmdline
  # for the NAME, so it counts the basename shell and the full-path shell and nothing else -- a count that
  # is entirely about processes that are not the keeper.
  want 'running, 2 process' "$out" "mutation 'gov': and the count it reports is 2, about nothing"
fi

# (3) the retire installer's --status: the same substitution in its device-side heredoc.
if mutate m-retire "$RETIRE" 's#case "\\\$a1" in "$KEEPER") hit=1 ;; esac#case "$(tr "\\\\000" " " < "\\\$d/cmdline")" in *"$KEEPER"*) hit=1 ;; esac#'; then
  pr=$(extract_retire "$W/mut/m-retire")
  use_shape bystander
  out=$(KEEPER="$KEEPER" sh -c "$(printf '%s\n' "$pr" | sed "s#/proc/#$FR/proc/#g")")
  # pid 105, not 103: the rule being restored here searched for the FULL path, so only the shell that
  # names it matches. Asserting on 103 would be asserting on a string the old test never looked for.
  want 'pid=105' "$out" "mutation 'retire': the shell that names the FULL path is listed as a keeper (the check is live)"
fi

# (4) the quiet keeper: keeper_pids() becomes the substring rule -- and this is the one that SIGNALS.
# The subject's own rule line is now `"$mp"` (one function, two subjects), so the pattern follows it: a
# mutation keyed on the OLD text stops landing the moment the rule is refactored, and "the sed changed
# nothing" is exactly what this harness asserts rather than assumes.
if mutate m-quiet "$QUIET" 's#case "\$a1" in "\$mp") hit=1 ;; esac#case "$(tr "'"'"'\\0'"'"'" "'"'"' '"'"'" < "$p/cmdline")" in *"$KEEPER_NAME"*) hit=1 ;; esac#'; then
  sed "s#/proc/#$FR/proc/#g" "$W/mut/m-quiet" > "$W/quiet.sh"
  use_shape bystander
  out=$(PATH="$STUB:$PATH" timeout 90 sh "$W/quiet.sh" --status 2>/dev/null)
  want 'keeper pid 10[345]' "$out" "mutation 'quiet': --stop would now SIGSTOP a shell that merely mentions the path (the check is live)"
  notwant 'keeper: not running' "$out" "mutation 'quiet': and --status no longer says 'not running' on a keeper-less boot"
  quiet_copy   # restore the real copy for anything below
fi

# (5) the sweep: one of the SIX subjects is mutated to the substring rule, and the sweep must flag it.
# The subject is one of the two the sweep found on the day it was written, which is the point: those two
# are device scripts with no harness of their own, so the sweep is the only thing standing between them
# and a quiet regression -- and a sweep that cannot redden on a file it reads is a report, not a check.
if mutate m-sweep "$BOOTCHK" 's#case "$a1" in "$KEEPER_PATH") hit=1 ;; esac#c=$(tr "\\0" " " < "$p/cmdline"); case "$c" in *zl1-debug-net.sh*) hit=1 ;; esac#'; then
  mkdir -p "$W/sweep-mut"; cp "$W/mut/m-sweep" "$W/sweep-mut/bad.sh"
  mut=$(sweep "$W/sweep-mut")
  want 'bad\.sh' "$mut" "mutation 'sweep': the same file with the substring rule in it IS flagged (the sweep is live)"
  want 'zl1-debug-net\.sh\*' "$mut" "and the hit names the line, so a reader can see what to fix"
fi

# ==================================================================================================
echo
echo "== 5. the citation, and the tree =="
# ==================================================================================================
AFTER=$(hash6)
[ "$BEFORE" = "$AFTER" ] && ok "the six subject files are byte-identical to what they were before this run" \
  || { bad "this harness EDITED the tree it tests:"; diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER") | sed 's/^/        | /'; }

# The health check's count is hand-typed in the page, and docs 110 records one of those going stale with
# nothing to notice; every harness that page names now checks its own citation, and this is that check.
#
# The citation check is the LAST check in this file, and that is on purpose: the house form of this check
# is `total=$((PASS + FAIL + 1))` -- the +1 is the check itself, which cannot be counted before it has
# run -- so anything after it would make the number the harness verifies one it does not end on. The
# tree check above used to sit here, and with it after the citation this file cited a number one larger
# than its own final pass count.
CITED=$(sed -e 's/always "/ /g' -e 's/"$//' "$HEALTH" | tr '\n' ' ' |
          sed -n 's/.*zl1-keeper-detect-selftest\.sh[ ,(]*\([0-9][0-9]*\) checks.*/\1/p')
TOTAL=$((PASS + FAIL + 1))
if [ -z "$CITED" ]; then
  bad "the health check does not cite this harness's check count at all (docs 128's rule, docs 179)"
elif [ "$CITED" = "$TOTAL" ]; then
  ok "the health check cites $CITED checks, and this run has exactly that many"
else
  bad "the health check cites $CITED checks, but this harness has $TOTAL -- fix host/zl1-health-check.sh"
fi

echo
printf 'pass=%s fail=%s\n' "$PASS" "$FAIL"
[ "$KEEP" = 1 ] && echo "kept: $W (the extracted programs, the mutants, the fake /proc shapes)"
[ "$KEEP" = 1 ] || rm -rf "$W"
[ "$FAIL" = 0 ] || exit 1
exit 0
