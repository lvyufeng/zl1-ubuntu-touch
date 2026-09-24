#!/usr/bin/env bash
# zl1 selftest-family -- offline self-test. Host-side, touches no device, installs nothing, runs no sudo.
#
# The subject (`host/zl1-selftest-family.sh`) exists for two reasons, and both are things a harness
# cannot do about itself: it is the ONE command that runs the whole family and reports the total, so the
# family number stops being hand-typed into documents; and it is the only check in this tree that can
# notice a harness **modifying the repository it tests** -- which is not a defect any assertion inside
# that harness could ever see (docs 128 section 9c: a fixture written through a directory symlink
# replaced `scripts/device/zl1-thermal.sh`, 409 lines, while every assertion stayed green).
#
# So the fixture here is a **real git repository in /tmp** plus a set of tiny harnesses, and the
# scenarios are the states that matter: green, red, silent, slow, and the three ways of touching the
# tree (append to a tracked file, create a new one, delete one). Pointing the subject at THIS repository
# would make every verdict a statement about this laptop -- and, worse, the tree-check scenarios would
# have to damage the real tree to be observable, which is the defect itself. Section 9c of the heat-chain
# harness makes the same argument for the same reason.
#
# The subject is driven by argv only (--root / --harness-dir / --only / --timeout / --no-fingerprint),
# never by a rewritten copy, so what runs here is the shipped file.
#
# Usage: zl1-selftest-family-selftest.sh [--keep]

set -uo pipefail

KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
  --keep) KEEP=1; shift ;;
  --help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0" ; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/zl1-selftest-family.sh"
[ -r "$SRC" ] || { echo "cannot read $SRC" >&2; exit 2; }
REPO=$(cd "$HERE/../.." && pwd)

command -v git >/dev/null 2>&1 || { echo "git(1) is required (the subject's tree check is a git one)" >&2; exit 2; }

W=${TMPDIR:-/tmp}/zl1-selftest-family-selftest
R="$W/repo"        # the fixture repository the subject fingerprints
H="$W/harnesses"   # the fixture harnesses
rm -rf "$W"
mkdir -p "$R" "$H" || exit 2

# --- the fixture repository -------------------------------------------------------------------------
# `git add` and no commit: `git ls-files` reads the INDEX, and a file in the index is "tracked" for
# every question the subject asks. It also keeps the fixture free of any dependency on user.name /
# user.email being configured on the machine running this.
( cd "$R" && git init -q . && printf 'one\n' > tracked.txt && printf 'two\n' > also.txt &&
  git add tracked.txt also.txt ) 2>/dev/null
( cd "$R" && git rev-parse --git-dir >/dev/null 2>&1 ) || { echo "the fixture repository was not created" >&2; exit 2; }

reset_repo() { # a clean baseline, then the working-tree dirt every scenario starts from
  ( cd "$R" && printf 'one\n' > tracked.txt && printf 'two\n' > also.txt && rm -f newfile.txt )
}

# --- the fixture harnesses --------------------------------------------------------------------------
# Each is a real script the subject runs with `bash <path>`, so the subject's own parsing, timeout and
# tree comparison are the code under test rather than anything re-implemented here.
fx() { # name -- body on stdin. The name is prefixed so --only can select a controlled subset.
  cat > "$H/zl1-fx-$1-selftest.sh"
  chmod +x "$H/zl1-fx-$1-selftest.sh"
}

fx green <<'EOF'
#!/usr/bin/env bash
printf 'PASS  a thing\nPASS  another thing\n'
printf 'pass=7 fail=0\n'
exit 0
EOF

fx red <<'EOF'
#!/usr/bin/env bash
printf 'FAIL  the first thing\nFAIL  the second thing\n'
printf 'pass=3 fail=2\n'
exit 1
EOF

fx silent <<'EOF'
#!/usr/bin/env bash
# A harness that lands, runs and prints nothing. "Return 0 is not a measurement."
printf 'I did some work and said nothing about it\n'
exit 0
EOF

fx slow <<'EOF'
#!/usr/bin/env bash
sleep 30
printf 'pass=1 fail=0\n'
exit 0
EOF

fx writes <<'EOF'
#!/usr/bin/env bash
# The defect docs 128 records, in miniature: a fixture write that lands in the tree. Note the exit 0 and
# the green summary -- so the family can only catch this with the fingerprint, never with the summary.
printf 'appended by a harness\n' >> "$FIXTURE_REPO/tracked.txt"
printf 'pass=9 fail=0\n'
exit 0
EOF

fx creates <<'EOF'
#!/usr/bin/env bash
printf 'a file that did not exist\n' > "$FIXTURE_REPO/newfile.txt"
printf 'pass=2 fail=0\n'
exit 0
EOF

fx deletes <<'EOF'
#!/usr/bin/env bash
rm -f "$FIXTURE_REPO/also.txt"
printf 'pass=1 fail=0\n'
exit 0
EOF

fx clean <<'EOF'
#!/usr/bin/env bash
# Green AND harmless: the control for every tree scenario, so a red tree check cannot be explained by
# "the run wrote something" in general.
printf 'pass=11 fail=0\n'
exit 0
EOF

export FIXTURE_REPO="$R"

# --- the checks -------------------------------------------------------------------------------------
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
want()    { if grep -Eq "$1" <<< "$2"; then ok "$3"; else bad "$3"; sed 's/^/        | /' <<< "$2"; fi; }
notwant() { if grep -Eq "$1" <<< "$2"; then bad "$3"; grep -E "$1" <<< "$2" | sed 's/^/        | /'; else ok "$3"; fi; }

# run: the subject against the fixture repo and the fixture harnesses. OUT/RC are the results.
run() { # args...
  reset_repo
  OUT=$(timeout 120 bash "$SRC" --root "$R" --harness-dir "$H" "$@" 2>&1); RC=$?
}

echo "zl1 selftest-family -- offline self-test"
echo "  script under test: $SRC"
echo "  fixture repo:      $R (a real git repository; two files in the index)"
echo

# ==================================================================================================
echo "== 1. --help, and the glob that must not match the runner itself =="
# ==================================================================================================
OUT=$(bash "$SRC" --help 2>&1); RC=$?
[ "$RC" = 0 ] && ok "--help exits 0" || bad "--help exited $RC"
want '^# Usage: zl1-selftest-family\.sh' "$OUT" "and prints the usage block (as a header comment, which is what --help prints here)"
want '^#|^Usage' "$OUT" "and something that reads as a header"
notwant '^set -u' "$OUT" "and stops at the header, not in the code after it"
notwant '^HARNESSES=' "$OUT" "and does not leak its own shell"

# The glob is `zl1-*selftest.sh`; this runner is `zl1-selftest-family.sh`, whose basename does not end in
# `selftest.sh`. A runner that matched its own glob would run itself -- and against the REAL repository,
# which is the only place where that name lives.
OUT=$(bash "$SRC" --list 2>&1); RC=$?
[ "$RC" = 0 ] && ok "--list exits 0" || bad "--list exited $RC"
notwant 'zl1-selftest-family\.sh' "$OUT" "the runner is NOT in its own list (it cannot run itself)"
want 'harness\(es\)' "$OUT" "and the list reports how many it found"
want 'zl1-thermal-selftest\.sh' "$OUT" "and the real family is what it lists by default"
# The count is taken from the directory, not typed: a hand-typed family size inside a harness is the
# very defect this stage removes from the documents, and it would go stale on the next harness added.
shopt -s nullglob; n=0
for _f in "$HERE"/zl1-*selftest.sh; do [ -s "$_f" ] && n=$((n + 1)); done
shopt -u nullglob
want "^$n harness\(es\)" "$OUT" "and the real family is $n harnesses (counted here, not typed)"
want '^scripts/host/zl1-selftest-family-selftest\.sh$' "$OUT" \
  "and this file is one of the harnesses it lists -- inside the family, not beside it"
notwant '^scripts/host/zl1-selftest-family\.sh$' "$OUT" "and the runner itself is NOT (see the check above)"
notwant 'PASS |FAIL |verdict' "$OUT" "--list runs nothing"

# ==================================================================================================
echo
echo "== 2. the refusal: a tree check that cannot be taken is not a clean tree =="
# ==================================================================================================
mkdir -p "$W/notgit"
OUT=$(timeout 60 bash "$SRC" --root "$W/notgit" --harness-dir "$H" --only 'fx-clean' 2>&1); RC=$?
[ "$RC" = 2 ] && ok "a root that is not a git repository: exit 2" || bad "it exited $RC"
want 'REFUSING' "$OUT" "it refuses"
want 'not a git repository' "$OUT" "and names what it could not do"
want 'must not be reported as a clean tree' "$OUT" "and says why that matters"
notwant 'verdict' "$OUT" "and no verdict is printed"

# A git repository whose index is EMPTY is the other way the fingerprint can come back with nothing.
# An empty fingerprint compares equal to an empty fingerprint, so this is the check-that-cannot-fail
# one level up from the harnesses it guards -- and it is refused with its own message, because "your
# repository is not a git repository" would send the operator to fix a thing that is not broken.
( cd "$W" && git init -q "$W/empty-index" ) 2>/dev/null
OUT=$(timeout 60 bash "$SRC" --root "$W/empty-index" --harness-dir "$H" --only 'fx-clean' 2>&1); RC=$?
[ "$RC" = 2 ] && ok "a git repository with an EMPTY index: exit 2" || bad "it exited $RC"
want 'the tree check found 0 tracked files' "$OUT" "refused because the fingerprint took nothing"
want 'would report every run as clean' "$OUT" "and it says what that would have cost"
notwant 'not a git repository' "$OUT" "and it does NOT blame the repository, which is a git repository"

OUT=$(timeout 60 bash "$SRC" --root "$W/notgit" --harness-dir "$H" --only 'fx-clean' --no-fingerprint 2>&1); RC=$?
[ "$RC" = 0 ] && ok "--no-fingerprint runs anyway, and exits 0" || bad "it exited $RC"
want 'tree check was SKIPPED' "$OUT" "and says in the summary that the check did not happen"
want 'says nothing about whether the family edited the repository' "$OUT" "and what that costs"

# ==================================================================================================
echo
echo "== 3. green: the fixture family, and the total is ARITHMETIC =="
# ==================================================================================================
run --only 'fx-green|fx-clean'
[ "$RC" = 0 ] && ok "two green harnesses: exit 0" || bad "it exited $RC"
want '^PASS  zl1-fx-green-selftest\.sh' "$OUT" "the green one is reported as PASS"
want '^PASS  zl1-fx-clean-selftest\.sh' "$OUT" "and so is the harmless one"
want '2 harnesses run, 2 green, 0 not green, 18 checks, 0 failing' "$OUT" \
  "and the total is the SUM of what the harnesses printed (7 + 11), not a number typed here"
want 'verdict: all green' "$OUT" "with a verdict"
want 'the repository is unchanged' "$OUT" "and the tree check reports clean"

# And a pre-existing modification is NOT a change: the baseline is the working tree as found.
( cd "$R" && printf 'dirty before the run\n' > tracked.txt )
OUT=$(timeout 60 bash "$SRC" --root "$R" --harness-dir "$H" --only 'fx-clean' 2>&1); RC=$?
[ "$RC" = 0 ] && ok "a tree that was ALREADY dirty when the run started: exit 0" || bad "it exited $RC"
want 'the repository is unchanged' "$OUT" "because the baseline is the tree as found, not the index"
( cd "$R" && printf 'one\n' > tracked.txt )

# ==================================================================================================
echo
echo "== 4. red, silent and slow are three different states, and none of them is green =="
# ==================================================================================================
run --only 'fx-red'
[ "$RC" = 1 ] && ok "a failing harness: exit 1" || bad "it exited $RC"
want '^FAIL  zl1-fx-red-selftest\.sh +pass=3 fail=2 rc=1' "$OUT" "the harness's own numbers are carried"
want 'the first thing' "$OUT" "and its FAIL lines are surfaced, so the operator need not open the file"
want '1 harnesses run, 0 green, 1 not green, 5 checks, 2 failing' "$OUT" "the failing checks are counted"
want 'verdict: not green' "$OUT" "with the verdict naming the run as not green"
want 'zl1-fx-red-selftest\.sh' "$OUT" "and naming it"

run --only 'fx-silent'
[ "$RC" = 1 ] && ok "a harness that prints no summary: exit 1" || bad "it exited $RC"
want '^NOSUMMARY' "$OUT" "reported as NOSUMMARY, which is not a pass"
want 'cannot be read as green' "$OUT" "with the reason"
notwant '^PASS ' "$OUT" "and it is never printed as a PASS line"

run --only 'fx-slow' --timeout 2
[ "$RC" = 1 ] && ok "a harness that outlasts --timeout: exit 1" || bad "it exited $RC"
want '^TIMEOUT' "$OUT" "reported as TIMEOUT, distinct from a failure of the thing under test"
want 'did not finish' "$OUT" "with timeout(1) named as the cause"

# The refusal when the filter matches nothing: a suite over nothing reports zero failures.
run --only 'fx-does-not-exist'
[ "$RC" = 2 ] && ok "a filter that matches nothing: exit 2" || bad "it exited $RC"
want 'REFUSING: no harness matched' "$OUT" "it refuses rather than reporting a clean empty run"
want 'the check that cannot fail' "$OUT" "and says which defect that would be"

# ==================================================================================================
echo
echo "== 5. the tree check: the one thing no harness can assert about itself =="
# ==================================================================================================
run --only 'fx-writes'
[ "$RC" = 3 ] && ok "a harness that appends to a TRACKED file: exit 3" || bad "it exited $RC"
want 'THE REPOSITORY CHANGED WHILE THE FAMILY RAN' "$OUT" "loudly, in its own words"
want 'tracked\.txt' "$OUT" "naming the file"
want '[Aa] fixture landing in the tree is the defect' "$OUT" "and naming the defect family this is"
want 'THE REPOSITORY IS NOT UNCHANGED' "$OUT" "the summary does not say 'unchanged'"
want 'verdict: THE TREE CHANGED' "$OUT" "and the verdict says which of the two failures it is"
want '1 harnesses run, 1 green, 0 not green' "$OUT" \
  "NOTE: the harness itself was GREEN -- the exit 3 and the summary disagree on purpose, and the tree wins"

run --only 'fx-creates'
[ "$RC" = 3 ] && ok "a harness that CREATES a file in the tree: exit 3" || bad "it exited $RC"
want 'CREATED FILE\(S\) IN THE REPOSITORY ITSELF' "$OUT" "reported as a new file, not as a content change"
want 'newfile\.txt' "$OUT" "naming it"

run --only 'fx-deletes'
[ "$RC" = 3 ] && ok "a harness that DELETES a tracked file: exit 3" || bad "it exited $RC"
want 'MISSING +also\.txt' "$OUT" "reported as MISSING rather than skipped (sha256sum would print to stderr and move on)"

run --only 'fx-clean'
want 'the repository is unchanged' "$OUT" "the control: a green AND harmless harness leaves the tree clean"

# And the skip is what turns it off -- so it must say so, and it must still be reported as not-checked.
run --only 'fx-writes' --no-fingerprint
[ "$RC" = 0 ] && ok "with --no-fingerprint the same harness does not produce exit 3" || bad "it exited $RC"
want 'tree check was SKIPPED' "$OUT" "but the run says, in the summary, that the check did not happen"
want 'says nothing about whether the family edited the repository' "$OUT" "and what that costs the reader"
notwant 'THE TREE CHANGED|the repository is unchanged' "$OUT" "and it claims neither a clean tree nor a changed one"

# ==================================================================================================
echo
echo "== 6. --quiet =="
# ==================================================================================================
run --only 'fx-green|fx-clean' --quiet
want '^PASS  zl1-fx-green-selftest\.sh' "$OUT" "--quiet still prints one line per harness"
want 'verdict: all green' "$OUT" "and the verdict"
notwant 'tree check: on' "$OUT" "and drops the header block"

# ==================================================================================================
echo "== 7. the mutations: each one must change what the checks above observe =="
# ==================================================================================================
# Each mutant is one sed applied to a COPY of the shipped script, and every block first asserts the
# mutant reached the fixtures -- a mutant that dies in its own preflight proves nothing (the sibling
# harnesses record both halves of that failure).
M="$W/mut"
mkdir -p "$M"
mutate() { # name, sed-script
  if cmp -s <(sed "$2" "$SRC" 2>/dev/null) "$SRC"; then
    bad "mutation '$1': its sed matches no line of the SHIPPED script, so nothing is being tested"
    return 1
  fi
  sed "$2" "$SRC" > "$M/$1.sh"
  if cmp -s "$SRC" "$M/$1.sh"; then
    bad "mutation '$1': the sed would change the shipped file but not the copy -- it did not land"
    return 1
  fi
  bash -n "$M/$1.sh" 2>/dev/null || { bad "mutation '$1': the mutant does not parse"; return 1; }
  ok "mutation '$1': landed (it changes a line of the shipped script, and the mutant parses)"
  return 0
}
mutrun() { # mutant-name, args... -- against the same fixtures
  reset_repo
  MOUT=$(timeout 120 bash "$M/$1.sh" --root "$R" --harness-dir "$H" "${@:2}" 2>&1); MRC=$?
}

if mutate notree 's#^  FP_AFTER=\$(fingerprint)$#  FP_AFTER="$FP_BEFORE" #'; then
  mutrun notree --only 'fx-writes'
  [ "$MRC" = 0 ] && ok "mutation 'no tree comparison': a harness that edited the tree is reported GREEN" \
    || bad "the mutant still exited $MRC"
  want 'verdict: all green' "$MOUT" "and the verdict says all green on a run that damaged the fixture repo"
  want 'the repository is unchanged' "$MOUT" "and the summary claims the tree is unchanged"
fi

# "Treat a missing count as 0" -- which is exactly the defect, so it is the mutation: default both
# numbers and disable the branch that exists to catch the absence.
if mutate assummary 's#^  if \[ -z "\$p" \] || \[ -z "\$q" \]; then$#  p=${p:-0}; q=${q:-0}; if false; then #'; then
  mutrun assummary --only 'fx-silent'
  [ "$MRC" = 0 ] && ok "mutation 'a missing summary read as 0': the whole run is GREEN" \
    || bad "the mutant still exited $MRC"
  want 'verdict: all green' "$MOUT" "and a harness that said nothing is filed as a pass"
  want '^PASS  zl1-fx-silent-selftest\.sh +0 checks' "$MOUT" \
    "with 0 checks next to it -- the count that appeared because nothing was there to count"
fi

# The refusal is deleted as a BLOCK, not as one of its echo lines (the first version replaced the first
# `echo` and left the `exit 2` behind, so the mutant refused for a reason that had nothing to do with the
# mutation and the scenario proved nothing).
if mutate nogitr '/^  if ! ( cd "\$ROOT" && git rev-parse --git-dir/,/^  fi$/d'; then
  mutrun nogitr --only 'fx-writes' --root "$W/notgit"
  # AND IT STILL REFUSES -- from the 0-tracked-files guard. That is the point of having two: the protection
  # is not one sentence, and removing one of them lands on the other rather than on silence.
  [ "$MRC" = 2 ] && ok "mutation 'the not-a-git-repo refusal removed': the run STILL exits 2" \
    || bad "the mutant exited $MRC -- the second guard did not catch it"
  want 'the tree check found 0 tracked files' "$MOUT" "because the 0-files guard refuses instead"
  notwant 'verdict: all green' "$MOUT" "and nothing in the output claims the run was clean"
fi

if mutate notracked 's#^    TREE_CHANGED=1$#    : #'; then
  mutrun notracked --only 'fx-creates'
  [ "$MRC" = 0 ] && ok "mutation 'untracked-file detection removed': a NEW file in the tree is not noticed" \
    || bad "the mutant still exited $MRC"
  want 'the repository is unchanged' "$MOUT" "and the summary claims the tree is unchanged"
fi

# ==================================================================================================
echo
echo "== 7b. no pipeline in a pipefail harness may end in a reader that exits early =="
# ==================================================================================================
# The family's harnesses ARE the tree's green/red signal, and thirteen of them share one verdict helper
# (`want`/`notwant`: `printf '%s\n' "$2" | grep -Eq ...`). Under `set -o pipefail`, which SEVEN of them
# set, that helper can report a FALSE FAIL: the reader exits at the first match, the writer is killed by
# SIGPIPE, and pipefail reports the writer's death as the check's answer. Measured while verifying docs
# 133 in zl1-lpm-ladder-trial-selftest.sh -- `PIPESTATUS` was `printf=141 grep=0` at the failure, 4 red
# runs in 100, with the pattern present in the haystack that was read back at that moment.
#
# This is the invariant that keeps it fixed. Two things about its shape are deliberate:
#
#   * It scans the harnesses that SET pipefail, found by a `set` at the start of a line, which is how
#     every harness in this tree writes it. Without pipefail the writer's death is not the pipeline's
#     status and the shape is inert -- twelve harnesses carry it today and cannot misbehave. The day one
#     of them gains `set -o pipefail`, this check reds and lists the sites to change, which is the whole
#     point: the shape is a trap that springs on an edit nobody would think of as related.
#   * It bans the SHAPE (`grep -q` / `grep -m` / `head` on the right of a pipe) rather than a use, and
#     skips comment lines -- the use is not visible in the text (it depends on both callers and options),
#     and a reader that stops early can only ever save work, never change an answer, so nothing is given
#     up by not having one. The truncating call sites use `sed -n '1,5p'`, which reads to EOF and prints
#     the same five lines.
scan_risky() { # file -> the matching lines, with the file's own line numbers and comments dropped
  grep -nE '\|[[:space:]]*(grep[[:space:]]+-[A-Za-z]*q|grep[[:space:]]+-[A-Za-z]*-m|head([[:space:]]|$))' "$1" 2>/dev/null \
    | grep -vE '^[0-9]+:[[:space:]]*#'
}
RISKY=""; PF=0; NAMES=""
for f in "$HERE"/zl1-*selftest.sh; do
  grep -qE '^set -[a-zA-Z]* *pipefail' "$f" || continue
  PF=$((PF + 1)); NAMES="$NAMES $(basename "$f")"
  hit=$(scan_risky "$f")
  [ -n "$hit" ] && RISKY="$RISKY
$(basename "$f"):
$hit"
done
[ "$PF" -ge 1 ] \
  && ok "$PF harness(es) set pipefail and were scanned:$NAMES" \
  || bad "no harness was found to set pipefail -- the invariant would be vacuous, so it is reported, not assumed"
[ -z "$RISKY" ] \
  && ok "and not one of them puts an early-exiting reader on the right of a pipe (the shape that reports the writer's death)" \
  || { bad "a pipefail harness still has the shape that reports the WRITER's death as a check's answer:"
       printf '%s\n' "$RISKY" | sed 's/^/        | /'; }
# Two fixtures, in this order: the scan must CATCH what it forbids (or the check above is vacuous) and
# must not catch the shape the harnesses now use -- a scan that flags everything would pass the first
# assertion and fail the second. The risky one is written with `@` in place of the pipe and passed
# through `tr`: this file sets pipefail too, so its own test data would otherwise trip the guard, and a
# guard that has to carry an exemption for itself is the shape every check in this tree tries not to be.
mkdir -p "$W/scan"
cat > "$W/scan/risky.raw" <<'FIX'
#!/usr/bin/env bash
set -uo pipefail
want() { if printf '%s\n' "$2" @ grep -Eq -- "$1"; then :; fi; }
FIX
tr '@' '|' < "$W/scan/risky.raw" > "$W/scan/risky.sh"
cat > "$W/scan/fixed.sh" <<'FIX'
#!/usr/bin/env bash
set -uo pipefail
want() { if grep -Eq -- "$1" <<< "$2"; then :; fi; }
FIX
[ -n "$(scan_risky "$W/scan/risky.sh")" ] \
  && ok "the scan CATCHES the shape it forbids, on a fixture (so it is a check, not a statement)" \
  || bad "the scan did not flag a fixture that HAS the shape -- it cannot be what fails the check above"
[ -z "$(scan_risky "$W/scan/fixed.sh")" ] \
  && ok "and it does not flag the shape the harnesses now use, so the fix is not punished by the guard" \
  || bad "the scan flags the fixed shape too -- then it is not measuring the defect"
# A comment is prose about the shape, not the shape: the harnesses that document this defect quote it in
# a comment, and a guard that reds on its own explanation is a guard somebody deletes.
cat > "$W/scan/commented.raw" <<'FIX'
#!/usr/bin/env bash
set -uo pipefail
# the old helper was: printf '%s\n' "$2" @ grep -Eq -- "$1"
FIX
tr '@' '|' < "$W/scan/commented.raw" > "$W/scan/commented.sh"
[ -z "$(scan_risky "$W/scan/commented.sh")" ] \
  && ok "and a comment that quotes the shape is not the shape" \
  || bad "the scan flags a comment -- then every harness that explains this defect would fail this check"

# --- 7c. the same shape OUTSIDE the harnesses: a CENSUS, not a verdict -----------------------------
#
# docs 134 section 7 named this as its boundary -- "the invariant only covers harnesses" -- and left a
# paragraph saying so. This closes it with a number. It is deliberately a CENSUS and not a demand, and
# the reason is a measurement (docs 136):
#
#   * the two early-exiting readers are NOT equally dangerous. `cmd | head` kills its writer at ANY input
#     size above one pipe (measured: 19/20, 20/20, 50/50, 30/30 -- head leaves after ONE line, while the
#     writer is still going). `cmd | grep -q PAT` does not: with a bash-`printf` writer the writer
#     survives 30/30 runs at 318899 bytes and dies 30/30 at 348899 -- a threshold of about five pipe
#     capacities, not one.
#   * and a site only matters where the status is USED. `p=$(cmd | head -1)` is not a verdict: the
#     substitution's value is what the caller reads, and an unused non-zero status is nothing. What can
#     be corrupted is the CONDITION form -- `if cmd | grep -q P`, `cmd | grep -q P && ...`, `... || ...`.
#
# So this scans for exactly that form, in every non-harness script in the tree that sets pipefail, and
# requires the per-file counts to be the ones recorded below. It cannot say "this one is dangerous" (the
# pattern's presence is a property of the DATA, not of the text -- a gate that checks DT_NEEDED is EMPTY
# is safe by construction, because a reader that finds nothing must read to the end), so it does not
# pretend to: it says "no site here changed without somebody looking". A number that nothing can see is
# the defect docs 129 records; a number that is read back and compared is the fix for that.
VERDICT_RE='(\|[[:space:]]*(grep[[:space:]]+-[A-Za-z]*q|grep[[:space:]]+-[A-Za-z]*-[A-Za-z]*m|head([[:space:]]|$)))[^|]*(&&|\|\|)|(^|[^A-Za-z])(if|while|elif|!)[[:space:]].*\|[[:space:]]*(grep[[:space:]]+-[A-Za-z]*q|head([[:space:]]|$))'
verdict_sites() { # file -> its matching lines, with prose and comments dropped
  grep -nE "$VERDICT_RE" "$1" 2>/dev/null \
    | grep -vE '^[0-9]+:[[:space:]]*#' \
    | grep -vE '^[0-9]+:[[:space:]]*(always|say|echo|printf)[[:space:]]+["'\'']'
}
# The second filter is the same rule as section 7b's comment filter, one step over: a line that PRINTS
# text is prose, and a manual that explains this defect has to quote the shape it forbids. It fired on
# this change itself -- the paragraph above, added to the health check, was reported as two new sites.
# Narrow on purpose: a real pipeline inside an \`echo "$(cmd | grep -q P)"\` is not verdict-bearing anyway
# (the substitution's status is unused), which is the same reason the census only counts the
# status-carrying form.
# The census, per file, as measured on 2026-09-24 (docs 136). Every one of them is left alone on purpose
# and the reason is one of three: the line is inside a string that is SENT TO THE DEVICE (where the
# device's own sh does not set pipefail, so the shape is inert -- and it is not inert to EDIT them: the
# first attempt to do that here put three comment lines inside `REMOTE_STATUS='...'`, and the apostrophe
# in one of them CLOSED the device string and broke the file, which `bash -n` caught); the reader is
# `head -1` whose writer is a few-hundred-byte listing; or the file is historical stage machinery that
# no runbook drives any more. The lines this round DID fix are gone from this list, and section 7b
# forbids them coming back in a harness.
CENSUS=$(cat <<'CENSUS'
android-fw-stubs/camera-stack-reset.sh 1
android-fw-stubs/run-on-device.sh 1
boot-experiments/retest-v64.sh 1
boot-experiments/v65-watch-and-boot-production-keeper.sh 4
boot-experiments/v66-watch-and-boot-guardian.sh 4
fix-ssh-authorized-keys.sh 1
flash-boot-image.sh 1
host-watch-usb0.sh 2
host/zl1-one-boot-runbook.sh 1
hybris-shims/build-compat-layer.sh 2
hybris-shims/build-platform-api-libs.sh 1
install-netwatch-service.sh 1
install-repowerd-ordering.sh 1
make-halium-nonblocking-usb-debug-boot.sh 1
make-halium-postswitch-debug-boot.sh 4
measure-link-stability.sh 1
stage2-rollback-drill.sh 2
CENSUS
)
CENSUS_TOTAL=0
CENSUS_N=0
CENSUS_BAD=""
CENSUS_SEEN=""
# $HERE is scripts/host, so the tree root is its parent's parent's parent is wrong: go up two levels.
SCAN_ROOT=$(cd "$HERE/../.." && pwd)
for f in "$SCAN_ROOT"/scripts/*.sh "$SCAN_ROOT"/scripts/*/*.sh; do
  [ -f "$f" ] || continue
  case "$(basename "$f")" in *-selftest.sh) continue ;; esac
  grep -qE '^set -[a-zA-Z]* *pipefail' "$f" || continue
  rel="${f#"$SCAN_ROOT"/scripts/}"
  n=$(verdict_sites "$f" | grep -c . )
  CENSUS_SEEN="$CENSUS_SEEN$rel
"
  [ "${n:-0}" = 0 ] && continue
  want_n=$(printf '%s\n' "$CENSUS" | awk -v k="$rel" '$1==k{print $2}')
  CENSUS_TOTAL=$((CENSUS_TOTAL + n))
  CENSUS_N=$((CENSUS_N + 1))
  if [ -z "$want_n" ]; then
    CENSUS_BAD="$CENSUS_BAD
$rel: $n site(s), NOT in the census -- look at them (a site whose status decides something)"
  elif [ "$want_n" != "$n" ]; then
    CENSUS_BAD="$CENSUS_BAD
$rel: $n site(s) now, $want_n in the census"
  fi
done
# The other direction, and it is the one that rots: a file in the census that no longer has that many
# sites (fixed, or renamed) is a line in this table that is now a lie.
while read -r rel want_n; do
  [ -n "${rel:-}" ] || continue
  grep -qxF "$rel" <<< "$CENSUS_SEEN" || CENSUS_BAD="$CENSUS_BAD
$rel: in the census but no longer a pipefail script"
done <<EOF
$CENSUS
EOF
NPF=$(printf '%s' "$CENSUS_SEEN" | grep -c . )
[ "$NPF" -ge 20 ] \
  && ok "the census was taken over $NPF non-harness scripts that set pipefail (a floor of 20, so an empty scan cannot pass)" \
  || bad "only $NPF non-harness scripts were found to set pipefail -- the scan did not run"
[ "$CENSUS_N" -ge 8 ] \
  && ok "of those, $CENSUS_N files carry $CENSUS_TOTAL pipeline(s) whose STATUS decides something (the form that can be corrupted)" \
  || bad "only $CENSUS_N files carry such a pipeline -- the census extractor matched almost nothing, so it is reporting agreement it cannot have"
if [ -z "$CENSUS_BAD" ]; then
  ok "and every one of them is the number the census records -- no site changed without a look"
else
  bad "the census and the tree disagree, which is what it exists to notice:"
  printf '%s\n' "$CENSUS_BAD" | sed 's/^/        | /'
fi
# Fixtures. A census that cannot fail is the thing docs 129 is about, so: a file with a NEW site must be
# reported, and a file with the fixed shape must not be.
mkdir -p "$W/census"
cat > "$W/census/new.raw" <<'FIX'
#!/usr/bin/env bash
set -uo pipefail
if lsmod @ grep -q '^rndis_host'; then :; fi
FIX
tr '@' '|' < "$W/census/new.raw" > "$W/census/new.sh"
cat > "$W/census/fixed.sh" <<'FIX'
#!/usr/bin/env bash
set -uo pipefail
if grep -q '^rndis_host' <<< "$(lsmod)"; then :; fi
FIX
[ -n "$(verdict_sites "$W/census/new.sh")" ] \
  && ok "the census's extractor CATCHES a condition that asks its question through a pipe" \
  || bad "it did not flag a fixture that has one -- then its 'no site changed' reading means nothing"
[ -z "$(verdict_sites "$W/census/fixed.sh")" ] \
  && ok "and it does not flag the here-string form, so the fix is not punished" \
  || bad "it flags the fixed shape too -- then it is not measuring the defect"
# And it does not flag the shape where it appears in PROSE. This is not hypothetical: the paragraph this
# round added to zl1-health-check.sh was reported as two new sites before this filter existed, and a
# guard that reds on the page that explains it is a guard somebody deletes (section 7b's rule, one step
# over). The fixture is assembled with `@` for the same reason as the others.
cat > "$W/census/prose.raw" <<'FIX'
#!/usr/bin/env bash
set -uo pipefail
always "the form is: if cmd @ grep -q P then, or cmd @ grep -q P && fail"
say "and the pipe is the whole defect"
FIX
tr '@' '|' < "$W/census/prose.raw" > "$W/census/prose.sh"
[ -z "$(verdict_sites "$W/census/prose.sh")" ] \
  && ok "nor does it flag the shape quoted in a PRINTED string (prose about the defect is not the defect)" \
  || bad "it flagged prose -- then every page that explains this defect would fail the census"

# ==================================================================================================
echo
echo "== 8. the citation in the health check is checked by the thing it cites =="
# ==================================================================================================
# The family's rule, applied to this file: the health check names this harness WITH a check count, and a
# hand-typed count with nothing to notice when it drifts is the defect docs 110 records. The count in the
# page is read back out of the page and compared with what this run actually did -- so the number and the
# run cannot separate.
HEALTH="$HERE/zl1-health-check.sh"
if [ -r "$HEALTH" ]; then
  cited=$(sed -e 's/always "/ /g' -e 's/"$//' "$HEALTH" | tr '\n' ' ' |
            sed -n 's/.*zl1-selftest-family-selftest\.sh[ ,(]*\([0-9][0-9]*\) checks.*/\1/p')
  total=$((PASS + FAIL + 1))
  if [ -z "$cited" ]; then
    bad "the health check does not cite this harness's count -- either the citation is gone or its wording changed"
  elif [ "$cited" = "$total" ]; then
    ok "the health check cites $cited checks, and this run has exactly that many"
  else
    bad "the health check cites $cited checks, but this harness has $total -- fix host/zl1-health-check.sh"
  fi
else
  bad "cannot read $HEALTH -- its citation is unchecked"
fi

echo
if [ "$KEEP" = 1 ]; then
  echo "kept: $W (the fixture repository, the fixture harnesses, the mutants)"
else
  rm -rf "$W"
fi
printf 'pass=%s fail=%s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
exit 0
