#!/usr/bin/env bash
# zl1 offline self-test family -- every harness in one command, and one check that no harness can make
# about itself: that the family did not modify the repository it tests.
#
# Why this exists:
#
#   * **The family total was hand-typed, every time.** Docs 118/121/124/126/127/128 each carry a line
#     like "18 harnesses / N checks / green", and N was recomputed by the author in a shell loop and
#     copied into the page -- which is the same defect the whole tree keeps finding in *scripts*
#     (docs 110: a hand-typed count with nothing to notice when it goes stale). The counts in those
#     pages are still human prose; this makes the number itself a command that can be re-run.
#
#   * **A harness can only fail for a reason it was written to notice.** On 2026-09-24
#     `scripts/host/zl1-heat-fix-chain-selftest.sh` was found to have replaced
#     `scripts/device/zl1-thermal.sh` -- 409 lines, this project's only heat instrument -- with a
#     one-line comment, because its fixtures were written through a directory symlink into the
#     repository. Every assertion in that file stayed green; the damage was a fact about the REPOSITORY,
#     and there is no assertion *inside* a harness that can see it (docs 128 section 9c). That harness
#     now hashes the one file it was hurting. This script generalises it from one file to all 400
#     tracked ones, from one harness to all of them, and it is a mechanism rather than a rule to
#     remember: it runs on every invocation.
#
#   * **A harness that prints nothing is not a green harness.** An empty run, a crash before the
#     summary, a `timeout` kill -- none of those may be reported as a pass. Each is a distinct state
#     here (`no-summary`, `timeout`, `rc!=0`), because "the count did not appear" and "the count was
#     zero" are two different facts (the family's own rule, docs 96/99/108).
#
# What it does NOT do: it does not decide whether a harness is any good. It reports what each one said
# and whether the tree survived. The judgement about coverage lives in the harnesses themselves.
#
# Usage: zl1-selftest-family.sh [--list] [--only REGEX] [--timeout SECS] [--quiet]
#                               [--root DIR] [--harness-dir DIR] [--no-fingerprint]
#   --list             print the harnesses that would run, and exit 0 (no run, no fingerprint)
#   --only REGEX       run only the harnesses whose basename matches (ERE, unanchored)
#   --timeout SECS     per-harness wall-clock bound (default 900). 124/137 from timeout(1) is reported
#                      as `timeout`, never as a failure of the thing under test.
#   --quiet            print the verdict lines only (one per harness, plus the totals)
#   --root DIR         the repository to fingerprint (default: the one this script lives in)
#   --harness-dir DIR  where the harnesses are (default $ROOT/scripts/host)
#   --no-fingerprint   skip the tree check. It is PRINTED as skipped, because "not checked" and
#                      "checked and clean" are the two facts this script exists to keep apart.
#
# Exit codes: 0 every harness green and the tree unchanged; 1 at least one harness failed, timed out or
#             said nothing; 2 refused -- no harness found, not a git repository (the tree check cannot
#             be made), or no sha256sum(1); 3 THE REPOSITORY CHANGED while the family ran (this
#             outranks 1 in the code, because it means a fixture is landing in the tree, and every
#             later reading in this repository is suspect until it is understood).

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
HARNESS_DIR="$ROOT/scripts/host"
TIMEOUT=900
QUIET=0
FINGERPRINT=1
ONLY=""
LIST=0

while [ $# -gt 0 ]; do
  case "$1" in
  --list) LIST=1; shift ;;
  --only) ONLY="${2?--only needs a pattern}"; shift 2 ;;
  --timeout) TIMEOUT="${2?--timeout needs SECONDS}"; shift 2 ;;
  --quiet) QUIET=1; shift ;;
  --root) ROOT=$(cd "${2?--root needs a DIRECTORY}" && pwd) || exit 2; shift 2 ;;
  --harness-dir) HARNESS_DIR="${2?--harness-dir needs a DIRECTORY}"; shift 2 ;;
  --no-fingerprint) FINGERPRINT=0; shift ;;
  --help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0" ; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

# `say` prints the NOTES (the header block, the explanations). The per-harness lines and the totals are
# verdict lines and are printed directly, because `--quiet` means "one line per harness plus the totals"
# and a quiet run that printed neither would be a run with nothing to read. (The first version reused the
# heat chain's helper verbatim, where an empty argument took the opposite branch: under --quiet it printed
# blank lines AND swallowed the PASS lines.)
say() { [ "$QUIET" = 1 ] && return 0; printf '%s\n' "${*:-}"; }

# --- the harnesses ---------------------------------------------------------------------------------
# The glob is `zl1-*selftest.sh`, and it deliberately does NOT match this script: this file is named
# `zl1-selftest-family.sh`, whose basename does not end in `selftest.sh`. A runner that matched its own
# glob would run itself. The `-s` test drops a zero-length file, whose "pass=..." line can never appear.
shopt -s nullglob
HARNESSES=()
for f in "$HARNESS_DIR"/zl1-*selftest.sh; do
  [ -s "$f" ] || continue
  b=$(basename "$f")
  if [ -n "$ONLY" ]; then
    # grep, not [[ =~ ]]: the pattern is the operator's, and an ERE the shell cannot parse must be a
    # refusal, not a silent no-match (a filter that quietly selects nothing looks exactly like a suite
    # where everything is fine).
    printf '%s\n' "$b" | grep -Eq "$ONLY" || continue
  fi
  HARNESSES+=("$f")
done
shopt -u nullglob

if [ "$LIST" = 1 ]; then
  for f in "${HARNESSES[@]}"; do printf '%s\n' "${f#"$ROOT"/}"; done
  printf '%s harness(es)\n' "${#HARNESSES[@]}"
  exit 0
fi

if [ "${#HARNESSES[@]}" = 0 ]; then
  echo "REFUSING: no harness matched under $HARNESS_DIR (pattern '${ONLY:-zl1-*selftest.sh}')." >&2
  echo "A run over nothing reports zero failures, which is the check that cannot fail." >&2
  exit 2
fi

if ! command -v sha256sum >/dev/null 2>&1; then
  echo "REFUSING: no sha256sum(1), so the tree check cannot be made." >&2
  exit 2
fi

# --- the fingerprint -------------------------------------------------------------------------------
# Two lists, because they answer different questions: the HASHES catch a tracked file whose contents
# changed, and the untracked list catches a file that did not exist before (the `file` that a stray
# backtick created in the repository root, docs 96, was exactly that). Both are relative to $ROOT and
# both are taken with the working tree as the baseline -- this script runs in a tree that is often
# already dirty, and what it must catch is what the FAMILY changes, not what the author has not
# committed yet.
#
# A missing tracked file is reported as MISSING rather than skipped: `sha256sum` on a path that is not
# there prints to stderr and moves on, so a deleted file would otherwise look like an unchanged one.
fingerprint() { # hashes of tracked files
  ( cd "$ROOT" || exit 1
    git ls-files -z 2>/dev/null | tr '\0' '\n' | LC_ALL=C sort | while IFS= read -r p; do
      [ -n "$p" ] || continue
      if [ -f "$p" ] || [ -L "$p" ]; then
        printf '%s  %s\n' "$(sha256sum -- "$p" 2>/dev/null | cut -d' ' -f1)" "$p"
      else
        printf '%s  %s\n' MISSING "$p"
      fi
    done )
}
untracked() {
  ( cd "$ROOT" && git ls-files --others --exclude-standard -z 2>/dev/null | tr '\0' '\n' | LC_ALL=C sort )
}

FP_BEFORE=""; UT_BEFORE=""
if [ "$FINGERPRINT" = 1 ]; then
  if ! ( cd "$ROOT" && git rev-parse --git-dir >/dev/null 2>&1 ); then
    echo "REFUSING: $ROOT is not a git repository, so 'did the family modify the tree?' cannot be" >&2
    echo "answered here. A tree check that cannot be taken must not be reported as a clean tree." >&2
    echo "(--no-fingerprint runs anyway, and says so.)" >&2
    exit 2
  fi
  FP_BEFORE=$(fingerprint)
  UT_BEFORE=$(untracked)
  # A fingerprint over NOTHING is not a clean tree. `git ls-files` returning no rows (an index with
  # nothing in it, or a tree whose paths could not be read) leaves both sides empty, and an empty pair
  # compares equal -- the check-that-cannot-fail shape, one level up from the harnesses it guards.
  if [ "$(printf '%s\n' "$FP_BEFORE" | grep -c .)" = 0 ]; then
    echo "REFUSING: the tree check found 0 tracked files under $ROOT, so 'did the family modify the" >&2
    echo "tree?' has no evidence behind it. An empty fingerprint compares equal to an empty fingerprint" >&2
    echo "and would report every run as clean. (--no-fingerprint runs anyway, and says so.)" >&2
    exit 2
  fi
fi

say "zl1 offline self-test family"
say "  repo:      $ROOT"
say "  harnesses: ${#HARNESSES[@]} under ${HARNESS_DIR#"$ROOT"/}/"
say "  tree check: $([ "$FINGERPRINT" = 1 ] && echo "on -- $(printf '%s\n' "$FP_BEFORE" | wc -l) tracked files hashed before and after" || echo 'OFF (--no-fingerprint): this run does NOT check whether the family modified the tree')"
say ""

# --- the run ---------------------------------------------------------------------------------------
# One line per harness, and the four states are four different lines. The summary is parsed from the
# harness's OWN `pass=N fail=M`, which every harness in this directory prints; the count this script
# reports is pass+fail, i.e. the same arithmetic the citation checks inside the harnesses use, so the
# family total and the per-harness citations cannot drift apart by a different convention.
TOTAL_CHECKS=0
TOTAL_FAIL=0
N_OK=0; N_BAD=0
BAD_FILES=""
for f in "${HARNESSES[@]}"; do
  b=$(basename "$f")
  out=$(timeout -k 5 "$TIMEOUT" bash "$f" 2>&1); rc=$?
  p=$(printf '%s\n' "$out" | sed -n 's/^pass=\([0-9][0-9]*\) fail=.*/\1/p' | tail -1)
  q=$(printf '%s\n' "$out" | sed -n 's/^pass=[0-9][0-9]* fail=\([0-9][0-9]*\).*/\1/p' | tail -1)
  if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
    printf 'TIMEOUT %-42s rc=%s (timeout(1) -k 5 %s: the harness did not finish)\n' "$b" "$rc" "$TIMEOUT"
    N_BAD=$((N_BAD + 1)); BAD_FILES="$BAD_FILES $b"; continue
  fi
  if [ -z "$p" ] || [ -z "$q" ]; then
    printf 'NOSUMMARY %-39s rc=%s (it printed no pass=/fail= line, so it cannot be read as green)\n' "$b" "$rc"
    N_BAD=$((N_BAD + 1)); BAD_FILES="$BAD_FILES $b"
    [ "$QUIET" = 0 ] && printf '%s\n' "$out" | tail -5 | sed 's/^/        | /'
    continue
  fi
  TOTAL_CHECKS=$((TOTAL_CHECKS + p + q))
  TOTAL_FAIL=$((TOTAL_FAIL + q))
  if [ "$q" = 0 ] && [ "$rc" = 0 ]; then
    printf 'PASS  %-42s %5s checks  rc=0\n' "$b" "$((p + q))"
    N_OK=$((N_OK + 1))
  else
    printf 'FAIL  %-42s pass=%s fail=%s rc=%s\n' "$b" "$p" "$q" "$rc"
    printf '%s\n' "$out" | grep -E '^FAIL' | head -10 | sed 's/^/        | /'
    N_BAD=$((N_BAD + 1)); BAD_FILES="$BAD_FILES $b"
  fi
done

# --- the tree check --------------------------------------------------------------------------------
TREE_CHANGED=0
if [ "$FINGERPRINT" = 1 ]; then
  FP_AFTER=$(fingerprint)
  UT_AFTER=$(untracked)
  CH=$(diff <(printf '%s\n' "$FP_BEFORE") <(printf '%s\n' "$FP_AFTER") | grep -E '^[<>]' || true)
  NEW=$(comm -13 <(printf '%s\n' "$UT_BEFORE") <(printf '%s\n' "$UT_AFTER") | grep -v '^$' || true)
  if [ -n "$CH" ]; then
    TREE_CHANGED=1
    say ""
    say "!! THE REPOSITORY CHANGED WHILE THE FAMILY RAN -- a harness is writing into the tree it tests."
    say "   A fixture landing in the tree is the defect docs 128 section 9c records: it stays invisible"
    say "   to every assertion the harness makes, and it silently changes what the NEXT run measures."
    printf '%s\n' "$CH" | sed 's/^/   /'
  fi
  if [ -n "$NEW" ]; then
    TREE_CHANGED=1
    say ""
    say "!! THE FAMILY CREATED FILE(S) IN THE REPOSITORY ITSELF:"
    printf '%s\n' "$NEW" | sed 's/^/   + /'
  fi
fi

# --- totals ----------------------------------------------------------------------------------------
# Printed with printf, not say: these ARE the verdict lines, and --quiet must not be able to hide the
# one sentence that says whether the tree survived (the same reason the per-harness lines above are
# printed directly).
[ "$QUIET" = 0 ] && printf '\n'
if [ "$FINGERPRINT" = 1 ]; then
  if [ "$TREE_CHANGED" = 0 ]; then
    printf '== the repository is unchanged (%s tracked files hashed before and after, no new file)\n' "$(printf '%s\n' "$FP_BEFORE" | grep -c .)"
  else
    printf '== THE REPOSITORY IS NOT UNCHANGED -- see above; every reading above is suspect until that is understood\n'
  fi
else
  printf '== the tree check was SKIPPED (--no-fingerprint): this run says nothing about whether the family edited the repository\n'
fi
printf '== %s harnesses run, %s green, %s not green, %s checks, %s failing\n' \
  "${#HARNESSES[@]}" "$N_OK" "$N_BAD" "$TOTAL_CHECKS" "$TOTAL_FAIL"

if [ "$TREE_CHANGED" = 1 ]; then
  printf '== verdict: THE TREE CHANGED\n'
  exit 3
fi
if [ "$N_BAD" != 0 ]; then
  printf '== verdict: not green --%s\n' "$BAD_FILES"
  exit 1
fi
printf '== verdict: all green\n'
exit 0
