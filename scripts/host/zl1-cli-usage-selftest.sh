#!/bin/sh
# zl1 CLI usage -- offline self-test. Host-side, touches no device, installs nothing, runs no sudo.
#
# Why this exists: on 2026-09-23 a sweep of the tree found that **17 scripts printed their usage with a
# hard-coded line range** (`sed -n '2,53p' "$0"`). Docs 104 had already named that defect and "fixed" the
# one site it was looking at (by changing 52 to 53 -- the number moved with the header, so the defect
# survived its own fix), and docs 108 replaced two sites with the read-the-comments form. The other 17
# were never swept -- the same shape docs 86 recorded when a fix corrected one site and left its twin. Two of the 17 were not merely at risk: they were already broken
# on the day of the sweep:
#
#   * `install-retire-debug-keeper.sh --help` printed **12 lines of its own shell code** (its `HOST=`,
#     its `SSH=` line, `D=`, the lot) instead of stopping at the header, because the range ran to 84
#     while the header ends at line 72.
#   * `zl1-thermal.sh --help` printed `set -u` and two blank lines.
#
# `--help` is the one command that is always safe to type, and this project's headers ARE the manual --
# they carry the Usage line, the exit codes and the reasoning. So a tool that cannot print its own
# header is an instrument that cannot report, which is a defect family this repo keeps finding
# (docs 107). The fix is `awk 'NR==1{next} /^#/{print; next} {exit}' "$0"` -- the header, whatever its
# length.
#
# **The rule this harness enforces is self-maintaining, and that is the point:** every script that
# `scripts/host/zl1-health-check.sh` tells a person to run must answer `--help` with its own header and
# nothing but its header. Adding a step to the health check therefore brings its script into the sweep
# automatically, instead of relying on the next author to remember this file.
#
# **The static gate in section 2 is not a nicety, and this sweep learned it the hard way.** Before this
# file existed, the same sweep was run by hand from a shell loop -- and that loop had no gate, so it
# executed `--help` on every script in two directories including ones with no handler at all. Most just
# refused, but `scripts/hybris-shims/make-lsc-wrapper.sh` **wrote its output file** and
# `build-hybris-shims.sh` ran a linker. Nothing was damaged (the regenerated wrapper was byte-identical
# to the committed one, sha256 f3e1b842...), but the lesson is the one this repo keeps re-learning: a
# sweep that executes things must first read which of them it is allowed to execute.
#
# It is also a property test, not a spot check: for every script it covers, it appends a comment line to
# a COPY and requires the printed block to grow. A hard-coded range cannot pass that, however long the
# header happens to be today -- which is exactly how the fixed-range versions survived the fix that
# named them.
#
# Usage: zl1-cli-usage-selftest.sh [--keep] [--sweep-root DIR]
#   --keep            leave the rewritten copies in place for inspection
#   --sweep-root DIR  sweep DIR's scripts/ instead of this repo's (how the mutations are run)
#
# Exit codes: 0 every covered script answers --help with its own header; 1 something did not;
#             2 the harness itself could not run.

set -u

KEEP=0
ROOT=""
while [ $# -gt 0 ]; do
  case "$1" in
  --keep) KEEP=1; shift ;;
  --sweep-root) ROOT="${2?--sweep-root needs a DIRECTORY}"; shift 2 ;;
  --help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0" ; exit 0 ;;
  *) echo "unknown argument $1 (try --help)" >&2; exit 2 ;;
  esac
done

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
[ -n "$ROOT" ] || ROOT="$REPO"
# The repo case uses the same assignment every other harness here uses, so that the sweep in section 4d
# -- "a harness the health check names must carry the citation drift guard" -- covers this file too. It
# caught this one on the section's first run, which is the reason the assignment is written this way
# rather than as one unconditional path.
if [ "$ROOT" = "$REPO" ]; then
  HEALTH="$HERE/zl1-health-check.sh"
else
  HEALTH="$ROOT/scripts/host/zl1-health-check.sh"
fi
[ -d "$ROOT/scripts" ] || { echo "no $ROOT/scripts -- nothing to sweep" >&2; exit 2; }
[ -r "$HEALTH" ] || { echo "$HEALTH is unreadable: the covered set comes from it" >&2; exit 2; }

W=${TMPDIR:-/tmp}/zl1-cli-usage-selftest
rm -rf "$W"; mkdir -p "$W" || exit 2

PASS=0
FAIL=0
SKIP=0
ok()  { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }

# The header, independently of how any script prints it. This is the expected value in section 2, and
# it is computed by the harness -- not read out of the script under test, which would make the whole
# thing a self-comparison.
header_of() { awk 'NR==1{next} /^#/{print; next} {exit}' "$1"; }

echo "zl1 CLI usage -- offline self-test"
echo "  repo:        $ROOT"

# --- 1. the covered set, derived from the health check -------------------------------------------
#
# Two shapes, because the page uses both. It spells most scripts out as a path, and it names four by
# bare basename (`zl1-boot-address-selftest.sh, 24 checks`). The page also WRAPS its prose, and one of
# those names sits where the wrap falls:
#     always "       Its parsers are pre-verifiable without the device and without a hand: scripts/host/"
#     always "       zl1-orientation-axes-selftest.sh"
# so a path grep alone silently drops it -- which is how an earlier version of this section came to
# check 7 harnesses while reporting that all of the ones the page names were fine. Both shapes are
# extracted, and the split between them is printed, so neither can quietly go to zero.
grep -oE 'scripts/[A-Za-z0-9_./-]+\.sh' "$HEALTH" | sort -u > "$W/covered"
n_path=$(wc -l < "$W/covered" | tr -d ' ')

# The basename form is resolved under scripts/ and must resolve to exactly one file; an ambiguous
# basename is reported rather than silently resolved to whichever one find happened to print first.
n_bare=0
for b in $(grep -oE '(^|[^A-Za-z0-9_./-])[A-Za-z0-9_-]+\.sh' "$HEALTH" |
           sed -e 's/^[^A-Za-z0-9_-]*//' | sort -u); do
  hits=$(find "$ROOT/scripts" -name "$b" 2>/dev/null | sort)
  n_hits=$(printf '%s\n' "$hits" | grep -c .)
  case "$n_hits" in
  0) : ;;   # e.g. zl1-debug-net.sh: a device-side artifact the page mentions and this repo does not hold
  1)
    rel=${hits#"$ROOT"/}
    if ! grep -qxF "$rel" "$W/covered"; then printf '%s\n' "$rel" >> "$W/covered"; n_bare=$((n_bare + 1)); fi
    ;;
  *) bad "$b is named by the health check but is ambiguous in this tree: $(printf '%s' "$hits" | tr '\n' ' ')" ;;
  esac
done
sort -u "$W/covered" -o "$W/covered"
n_from_health=$(wc -l < "$W/covered" | tr -d ' ')
# A floor, so a change to the health check's formatting cannot quietly empty this file and turn every
# check below into a no-op that passes.
if [ "${n_from_health:-0}" -ge 20 ]; then
  ok "the health check names $n_from_health scripts (a floor of 20, so an empty extract cannot pass)"
else
  bad "the health check names only ${n_from_health:-0} scripts -- the extract is broken, not the scripts"
fi
# Its own reading: "the path form found 24" and "the basename form added 4" are two numbers a reader
# can check against the page, not one number that cannot be checked.
ok "  of those, $n_path came from a path the page spells out and $n_bare from a bare basename it resolves to"
# Kept before the extras are added: section 4d's rule is about the harnesses THE PAGE names, and the
# extras are by definition the ones it does not.
cp "$W/covered" "$W/named"

# The scripts this sweep converted which the health check does NOT name. They are listed here explicitly
# rather than left out, because otherwise the fix would be the only thing in this window covered by
# nothing but a syntax check -- and "it parses" is not a behaviour. Keeping them in the covered set is
# also how the next reader sees which scripts were touched beyond the ones the page names.
for extra in scripts/hybris-shims/install-container-desabotage.sh \
             scripts/hybris-shims/install-hybris-shims.sh \
             scripts/hybris-shims/install-host-hybris-fix.sh \
             scripts/hybris-shims/install-platform-api-libs.sh \
             scripts/hybris-shims/install-wlan-bringup.sh \
             scripts/hybris-shims/free-container-display.sh \
             scripts/hybris-shims/free-gpu-devices.sh \
             scripts/tlsfix/install-tlsfix.sh \
             scripts/device/zl1-audio-test.sh \
             scripts/device/zl1-orientation-watch.sh \
             scripts/device/zl1-sensorfw-probe.sh \
             scripts/device/zl1-sensors-recover.sh \
             scripts/host/zl1-edl-postmortem-selftest.sh \
             scripts/host/zl1-installers-selftest.sh \
             scripts/host/zl1-screenshot.sh \
             scripts/host/zl1-vendor-link-audit.sh \
             scripts/install-cpufreq-governor.sh; do
  grep -qxF "$extra" "$W/covered" || printf '%s\n' "$extra" >> "$W/covered"
done
sort -u "$W/covered" -o "$W/covered"
n_covered=$(wc -l < "$W/covered" | tr -d ' ')
echo "  covered set: $n_covered scripts = the $n_from_health the health check names + $((n_covered - n_from_health)) this sweep converted outside it"
echo

echo "== 2. every covered script answers --help with its own header, and nothing else =="
n_checked=0
while read -r rel; do
  f="$ROOT/$rel"
  if [ ! -f "$f" ]; then
    bad "$rel is named by the health check and does not exist"
    continue
  fi
  case "$(head -1 "$f")" in
  *bash*) RUN=bash ;;
  *)      RUN=sh ;;
  esac
  # Static gate BEFORE running anything: this harness executes scripts, so it only executes one whose
  # --help branch it has already seen. Without this, a script with no handler would be run with
  # `--help` and would do whatever it normally does -- which for this tree includes flashing.
  if ! grep -q -- '--help|-h)' "$f"; then
    bad "$rel is named by the health check but does not answer --help at all"
    continue
  fi
  n_checked=$((n_checked + 1))
  out=$("$RUN" "$f" --help 2>&1); rc=$?
  want=$(header_of "$f")
  if [ "$rc" != 0 ]; then
    bad "$rel --help exited $rc"; continue
  fi
  if [ -z "$out" ]; then
    bad "$rel --help printed nothing"; continue
  fi
  if printf '%s\n' "$out" | grep -qv '^#'; then
    bad "$rel --help printed a line that is not a comment:"
    printf '%s\n' "$out" | grep -v '^#' | head -3 | sed 's/^/        | /'
    continue
  fi
  if [ "$out" = "$want" ]; then
    ok "$rel: --help printed its whole header ($(printf '%s\n' "$out" | wc -l | tr -d ' ') lines) and nothing else"
  else
    bad "$rel: --help did not print its own header (wanted $(printf '%s\n' "$want" | wc -l | tr -d ' ') lines, got $(printf '%s\n' "$out" | wc -l | tr -d ' '))"
    # POSIX sh: no process substitution. `diff <(...) <(...)` is a bashism and this file is a
    # `#!/bin/sh` script -- which is not a style point, it is why the first run of this harness died
    # with "Syntax error: ( unexpected" on its own line 126.
    printf '%s\n' "$want" > "$W/diff.want"
    printf '%s\n' "$out"  > "$W/diff.got"
    diff "$W/diff.want" "$W/diff.got" | head -6 | sed 's/^/        | /'
  fi
  # The Usage line is the reason the header exists; a print that drops it is a manual that lost its
  # manual. Only checked where the header has one, so this stays a fact about the file, not a style.
  if grep -q '^# *Usage' "$f"; then
    case "$out" in
    *Usage*) ok "$rel: and it still carries the Usage line" ;;
    *) bad "$rel: the printed header lost its Usage line" ;;
    esac
  fi
done < "$W/covered"
[ "$n_checked" -gt 0 ] || bad "no covered script was actually run -- every check above is vacuous"

# --- 3. the property: the header's length is not hard-coded ---------------------------------------
#
# This is the check that would have caught the 17 sites on the day docs 104 fixed the first four. It
# does not care how a script prints its usage; it only asks whether the output grows when the header
# does. A `sed -n '2,53p'` cannot grow.

echo
echo "== 3. the printed header GROWS when the header grows (the hard-coded range cannot) =="
n_prop=0
while read -r rel; do
  f="$ROOT/$rel"
  [ -f "$f" ] || continue
  grep -q -- '--help|-h)' "$f" || continue
  case "$(head -1 "$f")" in
  *bash*) RUN=bash ;;
  *)      RUN=sh ;;
  esac
  cp "$f" "$W/grow.sh"
  before=$("$RUN" "$W/grow.sh" --help 2>&1 | wc -l | tr -d ' ')
  # Append a comment line to the header's END: find the last leading comment line and insert after it,
  # so the new line is inside the block the printer is supposed to stop at.
  awk 'NR==1{next} /^#/{last=NR; next} {exit} END{print last+0}' "$f" > "$W/last"
  last=$(cat "$W/last")
  [ "${last:-0}" -ge 2 ] || continue
  awk -v n="$last" 'NR==n{print; print "# (added by zl1-cli-usage-selftest: the header grew by one line)"; next} {print}' \
      "$f" > "$W/grow.sh"
  after=$("$RUN" "$W/grow.sh" --help 2>&1 | wc -l | tr -d ' ')
  n_prop=$((n_prop + 1))
  if [ "$after" = "$((before + 1))" ]; then
    :
  else
    bad "$rel: adding one line to the header changed the printed block by $((after - before)) lines, not 1 -- the printer's end is hard-coded"
  fi
done < "$W/covered"
if [ "$n_prop" -gt 0 ]; then
  ok "all $n_prop covered scripts gained exactly one printed line when their header gained one"
else
  bad "the growth test ran on no script -- it proves nothing"
fi

# --- 4. the whole tree, not only the covered set --------------------------------------------------

echo
echo "== 4. the tree-wide half =="
# (a) The defect class itself. This is a grep, and it is the reason the sweep is repeatable.
# It is restricted to `*.sh`, and the exclusion is on this harness's own file: the pattern is a STRING
# in here, so without it the grep always finds one site -- itself. Two files in this tree spell the
# pattern out in prose, this one and `scripts/README.md` (which documents the fix), and both would
# otherwise be reported as live sites. A grep for a defect's shape matches the text that names it.
RANGE_RE="sed -n '[0-9]+,[0-9]+p' \"\\\$0\""
grep_hits() { grep -rlE --include='*.sh' --exclude=zl1-cli-usage-selftest.sh "$RANGE_RE" "$ROOT/scripts" 2>/dev/null; }
fixed=$(grep_hits | wc -l | tr -d ' ')
if [ "${fixed:-0}" = 0 ]; then
  ok "no script prints its usage with a hard-coded line range"
else
  bad "$fixed script(s) still print usage with a hard-coded range:"
  grep_hits | sed 's/^/        | /' | head -10
fi

# (b) A header that documents a Usage line and a script that ignores --help is a manual nobody can ask
# for. The covered set is where that matters (section 2 checks it there); this only counts how many
# such scripts exist outside it, as a number that is allowed to be non-zero -- it is reported, not
# demanded, because most of the tree is historical stage machinery that is never run by hand.
with_usage=0; no_handler=0
for f in $(find "$ROOT/scripts" -name '*.sh' 2>/dev/null); do
  grep -q '^# *Usage' "$f" || continue
  with_usage=$((with_usage + 1))
  grep -q -- '--help|-h)' "$f" || no_handler=$((no_handler + 1))
done
ok "tree-wide: $with_usage scripts document a Usage line, $no_handler of them (all outside the covered set) cannot print it -- reported, not demanded"

# (c) A script nobody can execute is not a tool. Cheap, and it was true of five scripts on the day of
# the sweep -- including two this window added.
nexec=0
for f in $(find "$ROOT/scripts" -name '*.sh' 2>/dev/null); do
  [ -x "$f" ] || nexec=$((nexec + 1))
done
if [ "$nexec" = 0 ]; then
  ok "every .sh under scripts/ is executable"
else
  bad "$nexec script(s) under scripts/ are not executable:"
  find "$ROOT/scripts" -name '*.sh' ! -perm -u+x 2>/dev/null | sed 's/^/        | /' | head -10
fi

# --- 4d. the same rule, one level up: the health check's number for a harness ------------------------
#
# The health check names each harness WITH a hand-typed check count, and docs 110 records that one of
# those went stale and nothing noticed. The fix was to have each harness check its own citation -- and
# every harness the health check names now does, except that nobody was checking THAT. So it is checked
# here, statically and tree-wide: a harness named by the health check must carry the drift guard. This is
# the same rule as section 2 (the health check's claims about its tools must be checkable by the tools),
# applied to the numbers instead of the usage text.

# The covered set that came from the page (before the extras), filtered to harnesses -- not a fresh
# grep of the raw file. That grep is what this section used to do, with a pattern that required the
# path to be on one line, and it therefore checked **7** of the harnesses the page names while
# reporting that all of them were fine: the page prints three of them by bare basename, and it wraps
# its text, so one path is even split across two string literals. Section 4d now sees the same set
# section 2 does, which is the whole point of the rule.
echo
echo "== 4d. every harness the health check names checks its own citation =="
n_h=0; n_missing=""
for rel in $(grep -- '-selftest\.sh$' "$W/named" | sort -u); do
  f="$ROOT/$rel"
  [ -f "$f" ] || { n_missing="$n_missing $rel(missing)"; continue; }
  n_h=$((n_h + 1))
  grep -q 'HEALTH="\$HERE/zl1-health-check.sh"' "$f" || n_missing="$n_missing ${rel##*/}"
done
if [ -z "$n_missing" ] && [ "$n_h" -gt 0 ]; then
  ok "all $n_h harnesses the health check names carry the citation drift guard"
else
  bad "these named harnesses cannot check their own citation:$n_missing"
fi

# --- 5. this harness's own citation in the health check ------------------------------------------

echo
echo "== 5. the health check cites this harness's count, and that citation cannot drift =="
cited=$(sed -e 's/always "/ /g' -e 's/"$//' "$HEALTH" | tr '\n' ' ' |
          sed -n 's/.*zl1-cli-usage-selftest\.sh[ ,(]*\([0-9][0-9]*\) checks.*/\1/p')
total=$((PASS + FAIL + 1))
if [ -n "$cited" ] && [ "$cited" = "$total" ]; then
  ok "the health check cites $cited checks, and this run has $total (the citation is live)"
else
  bad "the health check cites '${cited:-nothing}' checks for this harness; this run has $total"
fi

[ "$KEEP" = 1 ] || rm -rf "$W"
echo
echo "pass=$PASS fail=$FAIL${SKIP:+ skip=$SKIP}"
[ "$FAIL" = 0 ]
