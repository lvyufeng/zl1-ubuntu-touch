#!/bin/sh
# zl1 lpm sleep semantics, offline -- self-test.
#
# Host-side, touches no device, and it cannot: the subject reads a kernel SOURCE TREE, a built .config
# and a BOOT IMAGE. So the fixtures are shaped like those three things and not like text files:
#
#   * a kernel source directory whose lpm-levels.c is emitted line by line by a generator that PRINTS the
#     line numbers it wrote, so "the gate is at line N" is asserted against the generator's number and not
#     against the subject's own grep;
#   * a `.config` the preprocessor-arm reading consumes;
#   * a boot image with a real FDT blob appended at a NON-4-ALIGNED offset, because offsets inside an FDT
#     are relative to the blob and mixing them with file offsets is how a walk silently returns one node.
#
# What is under test, and each of these was a defect in this instrument or a way it could be empty:
#
#   1. THE GATE IS COUNTED, NOT NAMED. `gate sites: 1` for the fixture; 0 must take the verdict down and
#      2 must be reported as 2 rather than silently reading the first.
#   2. THE ENCLOSING FUNCTION AND THE GATE'S LINE NUMBER. The first version reported the gate 124 lines
#      past where it is (renumbering with an offset) and quoted the `module_param_named` statement as the
#      enclosing "function". Both are asserted against the generator's own numbers.
#   3. THE CHAIN, FOUR LINKS, EACH ABLE TO FAIL: the select callback, the enter callback, the definition
#      of psci_enter_sleep (present in BOTH shapes -- `static bool f(` and bare `bool f(`), and the call
#      that carries the index into it. Each has a fixture where that one link is broken.
#   4. WHICH DEFINITION COMPILES. The fixture has three preprocessor arms with hostile names; the built
#      config must select the first, and a config with CONFIG_CPU_V7=y must take the verdict down instead
#      of quoting an arm that is dead text.
#   5. THE LADDER IS GROUPED PER CLUSTER. Two `pm-cpu` clusters in one tree must print TWO `LEVELS` lines
#      of three modes each. A flattened six-entry list -- the first version -- fails this, and it is the
#      assertion that catches a reading which is true here by accident.
#   6. `qcom,use-psci` IS A VERDICT-BEARING READING, and it is looked for on the right node: the fixture
#      node is nested at /soc/qcom,lpm-levels, so a comparison against the bare name reports 0 of 1 and
#      that is mutation (c).
#   7. min-child-idx IS COMPUTED, NOT REMEMBERED. "parsed and never consumed" was a sentence this
#      instrument used to print as prose, and the source contradicts it (it is read six times). Three
#      fixtures: read only outside the gate's function, read inside it, and not read at all.
#   8. NOTHING IS CLAIMED WHEN THE INPUT IS UNUSABLE: no FDT in the image, and a source with no gate.
#   9. `--quiet` keeps the VERDICT and drops the READINGS (both halves of that are asserted), `--help`
#      answers, and the subject is READ-ONLY by static check.
#
# Usage: zl1-lpm-sleep-semantics-selftest.sh [--keep]
#
# Exit codes: 0 every scenario behaved; 1 something did not; 2 the harness could not set up.

set -u

KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
  --keep) KEEP=1; shift ;;
  --help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0" ; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

HERE=$(dirname "$0")
SRC="$HERE/zl1-lpm-sleep-semantics.sh"
[ -r "$SRC" ] || { echo "cannot read $SRC" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "this harness needs python3 to build its fixtures" >&2; exit 2; }
BASH_BIN=$(command -v bash) || exit 2

W=${TMPDIR:-/tmp}/zl1-lpm-sleep-semantics-selftest
rm -rf "$W"
mkdir -p "$W/fx" || exit 2
export LC_ALL=C

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$(( PASS + 1 )); printf 'PASS  %s\n' "$1"; }
bad()  { FAIL=$(( FAIL + 1 )); printf 'FAIL  %s\n' "$1"; }
skip() { SKIP=$(( SKIP + 1 )); printf 'SKIP  %s\n' "$1"; }
want()   { if printf '%s' "$2" | grep -qF -- "$1"; then ok "$3"; else bad "$3"; printf '        | wanted: %s\n' "$1"; fi; }
notwant(){ if printf '%s' "$2" | grep -qF -- "$1"; then bad "$3"; printf '        | did NOT want: %s\n' "$1"; else ok "$3"; fi; }
count_is(){ n=$(printf '%s\n' "$2" | grep -cF -- "$1" || true); if [ "$n" = "$3" ]; then ok "$4"; else bad "$4 (found $n, wanted $3)"; fi; }
rc_is()  { if [ "$RC" = "$1" ]; then ok "$2"; else bad "$2 (rc=$RC, wanted $1)"; printf '%s\n' "$OUT" | sed 's/^/        | /'; fi; }

# --- the fixture generators -----------------------------------------------------------------------
# ONE python program writes all four inputs and PRINTS the line numbers it wrote. The harness asserts the
# subject's reported numbers against these, so the two are not the same computation: the generator knows
# because it emitted the lines; the subject has to find them in the file.
cat > "$W/mkfx.py" <<'PY'
import sys, os, struct

MODE  = sys.argv[1]   # source variant
FMODE = sys.argv[2]   # fdt variant
FX    = sys.argv[3]   # output directory

os.makedirs(os.path.join(FX, 'src', 'drivers', 'cpuidle'), exist_ok=True)
os.makedirs(os.path.join(FX, 'dtbs'), exist_ok=True)

# ---------------------------------------------------------------- the kernel source (a fixture) ----
L = []
def add(x):
    L.append(x)
def emit():
    add('/* fixture: shaped like drivers/cpuidle/lpm-levels.c and nothing else */')
    add('#include <linux/module.h>')
    add('')
    add('static bool sleep_disabled;')
    add('module_param_named(sleep_disabled,')
    add('\tsleep_disabled, bool, S_IRUGO | S_IWUSR | S_IWGRP);')
    add('')
    add('static int cpu_power_select(struct cpuidle_device *dev,')
    add('\t\tstruct lpm_cpu *cpu)')
    add('{')
    add('\tint best_level = -1;')
    add('\tint i;')
    add('')
    add('\tif (!cpu)')
    add('\t\treturn -EINVAL;')
    add('')
    if MODE != 'no-gate':
        add('\tif (sleep_disabled || sleep_us  < 0)')
        add('\t\treturn 0;')
    if MODE == 'gate-two':
        add('')
        add('\tif (sleep_disabled || sleep_us  < 0)')
        add('\t\treturn -1;')
    if MODE == 'minchild-inside':
        add('')
        add('\tif (cluster->min_child_level > child_idx)')
        add('\t\treturn 0;')
    add('')
    add('\tfor (i = 0; i < cpu->nlevels; i++)')
    add('\t\tbest_level = i;')
    add('')
    add('\treturn best_level;')
    add('}')
    add('')
    # the select callback's definition spans two lines on purpose: a finder that only matches `name(` at
    # column 0 finds lpm_cpuidle_enter and misses this one.
    add('static int lpm_cpuidle_select(struct cpuidle_driver *drv,')
    add('\t\tstruct cpuidle_device *dev)')
    add('{')
    add('\tstruct lpm_cluster *cluster = per_cpu(cpu_cluster, dev->cpu);')
    add('\tint idx;')
    add('')
    add('\tif (!cluster)')
    add('\t\treturn 0;')
    add('')
    add('\tidx = cpu_power_select(dev, cluster->cpu);')
    add('')
    add('\tif (idx < 0)')
    add('\t\treturn -EPERM;')
    add('')
    add('\treturn idx;')
    add('}')
    add('')
    add('static int lpm_cpuidle_enter(struct cpuidle_device *dev,')
    add('\t\tstruct cpuidle_driver *drv, int idx)')
    add('{')
    add('\tstruct lpm_cluster *cluster = per_cpu(cpu_cluster, dev->cpu);')
    add('\tbool success = true;')
    add('')
    add('\tif (idx < 0)')
    add('\t\treturn -EINVAL;')
    add('')
    add('\tif (!use_psci) {')
    add('\t\tsuccess = msm_cpu_pm_enter_sleep(cluster->cpu->levels[idx].mode,')
    add('\t\t\t\ttrue);')
    add('\t} else {')
    if MODE != 'no-call':
        call_line = len(L) + 1
        add('\t\tsuccess = psci_enter_sleep(cluster, idx, true);')
    add('\t}')
    add('')
    add('\treturn success;')
    add('}')
    add('')
    # THREE definitions behind three preprocessor arms, and only the FIRST is `bool f(` with no return
    # type -- the shape a `static`-only finder refuses.
    add('#if !defined(CONFIG_CPU_V7)')
    def1 = len(L) + 1
    add('bool psci_enter_sleep(struct lpm_cluster *cluster, int idx, bool from_idle)')
    add('{')
    add('\t/* idx = 0 is the default LPM state */')
    add('\tif (!idx) {')
    add('\t\tstop_critical_timings();')
    add('\t\twfi();')
    add('\t\tstart_critical_timings();')
    add('\t\treturn 1;')
    add('\t} else {')
    add('\t\tint state_id = get_cluster_id(cluster, &affinity_level);')
    add('\t\treturn !cpu_suspend(state_id);')
    add('\t}')
    add('}')
    add('#elif defined(CONFIG_ARM_PSCI)')
    def2 = len(L) + 1
    add('static bool psci_enter_sleep(struct lpm_cluster *cluster, int idx,')
    add('\t\tbool from_idle)')
    add('{')
    add('\tif (!idx) {')
    add('\t\twfi();')
    add('\t\treturn 1;')
    add('\t}')
    add('\treturn !cpu_suspend(0);')
    add('}')
    add('#else')
    def3 = len(L) + 1
    add('bool psci_enter_sleep(struct lpm_cluster *cluster, int idx, bool from_idle)')
    add('{')
    add('\tWARN_ONCE(true, "PSCI cpu_suspend ops not supported\\n");')
    add('\treturn false;')
    add('}')
    add('#endif')
    add('')
    if MODE == 'no-psci-fn':
        # ALL THREE arms are renamed, and the CALL is not: that isolates the definition link. Renaming only
        # the first arm left the other two holding the shape, so the subject found definition #2 and the
        # mutation tested nothing -- a mutation has to break the link it is about, not one of three copies.
        for n in (def1, def2, def3):
            L[n - 1] = L[n - 1].replace('psci_enter_sleep(', 'psci_enter_sleep_renamed(')
    if MODE != 'minchild-none':
        add('static void cluster_prepare(struct lpm_cluster *cluster, int child_idx)')
        add('{')
        add('\tif (cluster->min_child_level > child_idx)')
        add('\t\treturn;')
        add('}')
    return L, def1, def2, def3, (call_line if MODE != 'no-call' else 0)

lines, DEF1, DEF2, DEF3, CALL = emit()
src = os.path.join(FX, 'src', 'drivers', 'cpuidle', 'lpm-levels.c')
with open(src, 'w') as fh:
    fh.write('\n'.join(lines) + '\n')
GATE = [i + 1 for i, l in enumerate(lines) if 'sleep_disabled ||' in l]
GATES = [i + 1 for i, l in enumerate(lines) if 'sleep_disabled' in l and i + 1 not in (4, 5, 6)]
FSTART = max(i + 1 for i, l in enumerate(lines) if i + 1 < (GATE[0] if GATE else 10 ** 9)
             and (l.startswith('static ') and '(' in l or (l[:1].isalpha() and '(' in l))
             and not l.startswith('module_param'))
SEL_END = next(i + 1 for i, l in enumerate(lines) if i + 1 > FSTART and l == '}')
MCREAD = [i + 1 for i, l in enumerate(lines) if 'min_child_level' in l]

print("GATE %s" % (GATE[0] if GATE else 0))
print("GATES %d" % len(GATES))
print("FSTART %d" % FSTART)
print("SEL_END %d" % SEL_END)
print("CDEF1 %d" % DEF1)
print("CDEF2 %d" % DEF2)
print("CDEF3 %d" % DEF3)
print("CALL %d" % CALL)
print("MCREAD %d" % len(MCREAD))
print("MCINSIDE %d" % len([n for n in MCREAD if FSTART <= n <= SEL_END]))

# ---------------------------------------------------------------- the other driver file ------------
of = '''/* fixture: the OF parser, and only the lines the subject reads out of it */
static int parse_level(struct lpm_cluster_level *level)
{
	ret = of_property_read_u32(node, "qcom,min-child-idx",
			&level->min_child_level);
	if (cluster->min_child_level > level->min_child_level)
		cluster->min_child_level = level->min_child_level;
	return 0;
}
'''
with open(os.path.join(FX, 'src', 'drivers', 'cpuidle', 'lpm-levels-of.c'), 'w') as fh:
    fh.write(of)

# ---------------------------------------------------------------- the built config ------------------
cfg = 'CONFIG_ARM64=y\n'
if FMODE == 'cfg-v7':
    cfg += 'CONFIG_CPU_V7=y\n'
cfg += '# CONFIG_SOMETHING_ELSE is not set\n'
with open(os.path.join(FX, '.config'), 'w') as fh:
    fh.write(cfg)

# ---------------------------------------------------------------- the FDT ---------------------------
# A real blob, written from the spec: header, reserve map, struct block, strings block. Node names mirror
# the shipped tree (/soc/qcom,lpm-levels/qcom,pm-cluster@0/...) so the subject's shortening is exercised
# and so a bare-name comparison against the lpm-levels node is what mutation (c) breaks.
FDT_BEGIN_NODE, FDT_END_NODE, FDT_PROP, FDT_END = 1, 2, 3, 9

class Fdt:
    def __init__(self):
        self.st = b''
        self.strtab = {}
        self.strs = b''
    def s(self, name):
        if name not in self.strtab:
            self.strtab[name] = len(self.strs)
            self.strs += name.encode() + b'\x00'
        return self.strtab[name]
    def pad(self):
        self.st += b'\x00' * ((4 - (len(self.st) % 4)) % 4)
    def begin(self, name):
        self.st += struct.pack('>I', FDT_BEGIN_NODE)
        self.st += name.encode() + b'\x00'
        self.pad()
    def endn(self):
        self.st += struct.pack('>I', FDT_END_NODE)
    def prop(self, name, data):
        if isinstance(data, str):
            data = data.encode() + b'\x00'
        self.st += struct.pack('>III', FDT_PROP, len(data), self.s(name))
        self.st += data
        self.pad()
    def prop_cells(self, name, *cells):
        self.prop(name, b''.join(struct.pack('>I', c) for c in cells))
    def blob(self):
        self.endn()                      # close the root
        self.st += struct.pack('>I', FDT_END)
        hdr_len, rsv_len = 40, 16
        off_struct = hdr_len + rsv_len
        off_strings = off_struct + len(self.st)
        total = off_strings + len(self.strs)
        hdr = struct.pack('>10I', 0xd00dfeed, total, off_struct, off_strings, hdr_len,
                          17, 16, 0, len(self.strs), len(self.st))
        assert len(hdr) == hdr_len
        return hdr + b'\x00' * rsv_len + self.st + self.strs

def level(f, idx, mode, lat, ss, psci, mcidx=None):
    f.begin('qcom,pm-cpu-level@%d' % idx)
    f.prop('qcom,spm-cpu-mode', mode)
    f.prop_cells('qcom,latency-us', lat)
    f.prop_cells('qcom,ss-power', ss)
    f.prop_cells('qcom,psci-cpu-mode', psci)
    if mcidx is not None:
        f.prop_cells('qcom,min-child-idx', mcidx)
    f.prop('label', mode)
    f.endn()

def cpu_cluster(f, cname, second_mode):
    f.begin('qcom,pm-cluster@%s' % cname)
    f.prop('label', 'pwr' if cname == '0' else 'perf')
    f.begin('qcom,pm-cpu')
    level(f, 0, second_mode if cname == '1' else 'wfi', 20 if cname == '0' else 25, 200, 1)
    level(f, 1, 'fpc-def', 40, 198, 4)
    level(f, 2, 'fpc', 80, 196, 4)
    f.endn()
    f.endn()

def tree(model, psci, second_mode, with_levels):
    f = Fdt()
    f.begin('')
    f.prop('model', model)
    f.begin('soc')
    f.begin('qcom,lpm-levels')
    f.prop('compatible', 'qcom,lpm-levels')
    f.prop_cells('qcom,psci-mode-shift', 4)
    if psci:
        f.prop('qcom,use-psci', b'')
    f.begin('qcom,pm-cluster@0')
    f.prop('label', 'system')
    if with_levels:
        cpu_cluster(f, '0', second_mode)
        cpu_cluster(f, '1', second_mode)
    f.endn()
    f.endn()
    f.endn()
    f.endn()
    return f.blob()

blobs = []
if FMODE != 'garbage':
    if FMODE in ('second-not-wfi', 'no-psci', 'no-levels', 'normal'):
        blobs.append(tree('Letv Technologies, Inc. MSM 8996pro + PMI8996 FIXTURE', FMODE != 'no-psci',
                          'retention' if FMODE == 'second-not-wfi' else 'wfi', FMODE != 'no-levels'))
    elif FMODE == 'two-trees':
        blobs.append(tree('FIXTURE DVT1', True, 'wfi', True))
        blobs.append(tree('FIXTURE PVT', False, 'wfi', True))
    elif FMODE == 'cfg-v7':
        blobs.append(tree('FIXTURE DVT1', True, 'wfi', True))
    else:
        blobs.append(tree('FIXTURE DVT1', True, 'wfi', True))

# The image: 1235 bytes of something else, then the blob(s). The offset is NOT a multiple of four, which is
# the whole point: an FDT's internal offsets are relative to the blob and a walk that aligns them to the
# FILE offset returns one node instead of the tree.
img = b'\x00' * 1235
for i, b in enumerate(blobs):
    img += b
    if i + 1 < len(blobs):
        img += b'\x00' * 77
with open(os.path.join(FX, 'boot.img'), 'wb') as fh:
    fh.write(img)
if blobs:
    with open(os.path.join(FX, 'dtbs', 'fixture-dvt1.dtb'), 'wb') as fh:
        fh.write(blobs[0])
PY

build() { # build SRC_MODE FDT_MODE
  python3 "$W/mkfx.py" "$1" "$2" "$W/fx" > "$W/nums"
  [ -s "$W/nums" ] || { echo "fixture generator produced nothing for $1/$2" >&2; exit 2; }
  num() { sed -n "s/^$1 //p" "$W/nums" | sed -n 1p; }
}

run() { # run [extra args...]
  OUT=$("$BASH_BIN" "$SRC" --src "$W/fx/src" --boot "$W/fx/boot.img" --dtb-dir "$W/fx/dtbs" \
        --config "$W/fx/.config" "$@" 2>&1)
  RC=$?
}

printf 'subject: %s\n\n' "$SRC"

# ==================================================================================================
printf -- '--- 1. the fixture source: the gate is COUNTED, and its line number is the generator'"'"'s ---\n'
# ==================================================================================================
build normal normal
GATE=$(num GATE); GATES=$(num GATES); FSTART=$(num FSTART); SEL_END=$(num SEL_END)
run
rc_is 0 "the fixture reads as a BARE WFI run"
want "== verdict: THE GATE IS A BARE WFI" "$OUT" "the verdict is BARE WFI on a fixture that is one"
want "gate sites: $GATES" "$OUT" "gate sites counted from the fixture's own text ($GATES)"
want "declaration:      line 4" "$OUT" "the declaration line is the fixture's line 4"
want "the enclosing function begins at line $FSTART; the gate is at line $GATE:" "$OUT" \
     "the enclosing function ($FSTART) and the gate ($GATE) are the fixture's own line numbers"
want "module_param_named(sleep_disabled," "$OUT" "the module_param statement is quoted verbatim"
# the statement's CONTINUATION line is not a second gate: 4/5/6 are excluded and 17 is the only one left
notwant "tab" "$(printf '%s' "$OUT" | grep -F 'sleep_disabled, bool' || true)" \
     "(sanity) the continuation line is quoted only where it belongs"
want "type, the default VALUE and the sysfs BEHAVIOUR" "$OUT" "the parameter's three parts are named"
# docs 163: the statement is quoted BECAUSE it carries the type, so the type is then DERIVED from it and
# turned into what a reader actually sees. Three scripts in this tree read this same parameter and
# compared the read-back against the string they wrote; the declaration that says not to is right here.
want "what that TYPE does to a READER: it is \`bool\`, so sysfs renders" "$OUT" \
     "and the TYPE is derived from that statement and turned into what a READER sees"
want "the file holds 0 and a reader SEES N" "$OUT" "which is the rendering a bool parameter applies"
want "OFF is 0/N/n/off, ON is 1/Y/y/on" "$OUT" \
     "with both STATES named, because comparing a string is the defect docs 163 records"
want "__setup arm:      none in this driver" "$OUT" "the absence of a __setup arm is reported"
want "cpu_power_select(struct cpuidle_device *dev," "$OUT" "the enclosing function is quoted, not described"

# mutation: no gate at all -> nothing may be claimed, and the run must say why
build no-gate normal
GATES0=$(num GATES)
run
rc_is 3 "a source with NO gate exits 3 (not a pass)"
want "gate sites: $GATES0" "$OUT" "gate sites: $GATES0 on that fixture (the count is real, not a constant)"
want "== verdict: THE GATE IS SOMETHING ELSE" "$OUT" "no gate -> THE GATE IS SOMETHING ELSE"
want "NOTHING is claimed about the ladder" "$OUT" "and it says NOTHING is claimed"

# mutation: two gate sites -> reported as two, and the FIRST is the one quoted
build gate-two normal
GATES2=$(num GATES); GATE2=$(num GATE)
run
want "gate sites: $GATES2" "$OUT" "two gate sites are reported as $GATES2, not read as one"
want "the gate is at line $GATE2:" "$OUT" "the first of them is quoted, at the fixture's line $GATE2"

# ==================================================================================================
printf -- '\n--- 2. the chain: four links, and each one can fail ---\n'
# ==================================================================================================
build normal normal
CDEF1=$(num CDEF1); CDEF2=$(num CDEF2); CDEF3=$(num CDEF3); CALL=$(num CALL)
run
want "the call(s) that carry that index into it:" "$OUT" "the index is followed to the call that carries it"
want "$CALL:		success = psci_enter_sleep(cluster, idx, true);" "$OUT" \
     "and that call is the fixture's line $CALL"
want "defined 3 time(s), at line(s): $CDEF1 $CDEF2 $CDEF3" "$OUT" \
     "all three definitions are found: $CDEF1 $CDEF2 $CDEF3"
want "lpm_cpuidle_select()  lpm-levels.c:" "$OUT" "the select callback is quoted"
want "lpm_cpuidle_enter()  lpm-levels.c:" "$OUT" "the enter callback is quoted"
# definition #1 has no `static`: a finder that requires one reports the link that holds the ANSWER missing
want "psci_enter_sleep()  lpm-levels.c:$CDEF1-" "$OUT" \
     "the bare-'bool f(' definition (no 'static') IS found, at line $CDEF1"
notwant "psci_enter_sleep(): NOT FOUND" "$OUT" "no link of the chain is reported missing on a good fixture"
want "guarded by: #if !defined(CONFIG_CPU_V7)" "$OUT" "the preprocessor guard of the quoted arm is read"
want "that branch is a literal wfi()" "$OUT" "the wfi() in the index-0 branch is read from the text"

# mutation: the index is not passed to the function at all
build no-call normal
run
want "NO call passes the index to psci_enter_sleep" "$OUT" "a broken call link is reported"
want "== verdict: THE GATE IS SOMETHING ELSE" "$OUT" "and it takes the verdict down"

# mutation: the definition the reading needs is not there under that name
build no-psci-fn normal
run
want "psci_enter_sleep(): NOT FOUND" "$OUT" "a missing definition is reported as missing"
want "== verdict: THE GATE IS SOMETHING ELSE" "$OUT" "and it takes the verdict down"

# ==================================================================================================
printf -- '\n--- 3. which of the three definitions COMPILES ---\n'
# ==================================================================================================
build normal normal
run
want "CONFIG_ARM64=1  CONFIG_CPU_V7=0  CONFIG_ARM_PSCI=0" "$OUT" "the two symbols are read from the config"
want "IS the arm that compiles" "$OUT" "arm 1 compiles for this config, and it says so"
want "== verdict: THE GATE IS A BARE WFI" "$OUT" "so the three facts stand"

# mutation: a config where the first arm is dead text. The verdict MUST go down: the facts would be about
# text the compiler never sees.
build normal cfg-v7
run
want "CONFIG_ARM64=1  CONFIG_CPU_V7=1" "$OUT" "the mutated config is read"
want "IS *NOT* THE ARM THAT COMPILES" "$OUT" "a config that picks another arm is called out"
want "== verdict: THE GATE IS SOMETHING ELSE" "$OUT" "and the verdict goes down with it"

# no config at all: that is UNKNOWN, not a failure -- the facts are labelled as about definition #1
OUT=$("$BASH_BIN" "$SRC" --src "$W/fx/src" --boot "$W/fx/boot.img" --dtb-dir "$W/fx/dtbs" \
      --config "$W/fx/nope.config" 2>&1); RC=$?
want "not readable" "$OUT" "an unreadable config is reported, not assumed"
want "== verdict: THE GATE IS A BARE WFI" "$OUT" "...and the reading goes on, labelled"

# ==================================================================================================
printf -- '\n--- 4. the ladder, grouped per cluster, read from a real FDT ---\n'
# ==================================================================================================
build normal normal
run
want "device trees appended to the image that parsed: 1" "$OUT" "the blob appended at an ODD offset is walked"
want "IDENTICAL to the built fixture-dvt1.dtb" "$OUT" "the blob's own sha256 matches the standalone .dtb"
count_is "LEVELS " "$OUT" 2 "TWO clusters produce TWO LEVELS lines (a flattened six-entry list fails this)"
count_is "| wfi,fpc-def,fpc" "$OUT" 2 "and each cluster's ladder is three modes, index 0 first"
want "LEVELS /soc/c0/c0/cpu | wfi,fpc-def,fpc" "$OUT" "the pwr cluster's path is the shipped tree's shape"
want "LEVELS /soc/c0/c1/cpu | wfi,fpc-def,fpc" "$OUT" "the perf cluster is a SEPARATE row, not a third entry"
want "(tree, cluster) pairs carrying CPU levels: 2" "$OUT" "the count is pairs, not trees"
want "index 0 is 'wfi': 2" "$OUT" "both clusters' index 0 is wfi on this fixture"
want "USE_PSCI_PATH /soc/qcom,lpm-levels" "$OUT" \
     "qcom,use-psci is found on the NESTED node (a bare-name comparison reports 0 here)"
want "trees whose lpm-levels node sets qcom,use-psci: 1 of 1" "$OUT" "so the psci branch is the one that runs"

# mutation (a): one cluster's index 0 is not wfi -> the trees disagree, and the count shows it
build normal second-not-wfi
run
want "index 0 is 'wfi': 1" "$OUT" "the count follows the mutated tree"
want "== verdict: THE TREES DISAGREE" "$OUT" "a cluster whose index 0 is not wfi is a finding"
notwant "== verdict: THE GATE IS A BARE WFI" "$OUT" "and it is NOT reported as a clean BARE WFI"

# mutation (b): the property is not in the tree at all -> the WFI claim is about a branch that never runs
build normal no-psci
run
want "trees whose lpm-levels node sets qcom,use-psci: 0 of 1" "$OUT" "an absent use-psci is counted as 0"
want "== verdict: THE GATE IS SOMETHING ELSE" "$OUT" "and it takes the verdict down"
want "does not run at all" "$OUT" "naming why: the psci branch is not the one taken"

# mutation (c): two trees that disagree about use-psci
build normal two-trees
run
want "trees whose lpm-levels node sets qcom,use-psci: 1 of 2" "$OUT" "one of two trees sets it"
want "== verdict: THE TREES DISAGREE" "$OUT" "a split across trees is a finding, not an average"

# mutation (d): a tree whose lpm-levels node has no pm-cpu-level children. THIS ONE FOUND A REAL DEFECT:
# the sentinel that marks "no ladder here" used to be printed as `LEVELS -`, and the count of ladders
# greps `^LEVELS ` -- so a tree with NO levels was counted as one cluster with a ladder, and the run
# reported "THE TREES DISAGREE" (1 pair, 0 of them wfi) instead of claiming nothing. A sentinel that
# shares a prefix with the data it marks the absence of is a sentinel the reader has to parse.
build normal no-levels
run
rc_is 3 "a tree with no CPU levels exits 3"
want "NO appended device tree describes CPU levels" "$OUT" "and it says which half is missing"
want "(tree, cluster) pairs carrying CPU levels: 0" "$OUT" \
     "and the pair count is 0, not 1 -- the 'LEVELS -' sentinel is not counted as a ladder"
want "NO qcom,pm-cpu-level children" "$OUT" "the per-tree reading says so too"

# mutation (e): an image with no FDT at all
build normal garbage
run
rc_is 3 "an image with no FDT exits 3"
want "UNREADABLE" "$OUT" "and it says UNREADABLE"

# ==================================================================================================
printf -- '\n--- 5. min-child-idx is COMPUTED, not remembered ---\n'
# ==================================================================================================
build normal normal
run
want "read sites in the driver: $(num MCREAD)   of those, INSIDE cpu_power_select: $(num MCINSIDE)" "$OUT" \
     "the subject's counts are the generator's ($(num MCREAD) site(s), $(num MCINSIDE) inside the gate's function)"
want "read sites in the driver: 1   of those, INSIDE cpu_power_select: 0" "$OUT" \
     "a read outside the gate's function is counted and located"
want "it IS consumed -- but not on the path the gate returns into" "$OUT" \
     "the sentence is the computed one, and it does NOT say 'never consumed'"
notwant "PARSED AND NEVER CONSUMED" "$OUT" "the false claim (it is read six times in the real source) is gone"

# mutation: a read INSIDE the function the gate returns from -> that WOULD put the property on this path
build minchild-inside normal
run
want "read sites in the driver: 2   of those, INSIDE cpu_power_select: 1" "$OUT" \
     "a read inside the gate's function is located there"
want "it IS read inside cpu_power_select itself" "$OUT" "and the sentence changes"
want "mechanism has to be re-read" "$OUT" "with what to do about it"

# mutation: no read anywhere -> the opposite sentence
build minchild-none normal
run
want "read sites in the driver: 0   of those, INSIDE cpu_power_select: 0" "$OUT" "zero reads is counted as zero"
want "it is parsed and never read anywhere in this driver" "$OUT" "only then is 'never read' the reading"

# ==================================================================================================
printf -- '\n--- 6. the option and the input contract ---\n'
# ==================================================================================================
build normal normal
run --quiet
rc_is 0 "--quiet exits 0 on a good fixture"
if printf '%s' "$OUT" | grep -qF '== verdict: THE GATE IS A BARE WFI'; then
  ok "--quiet keeps the VERDICT"
else
  bad "--quiet keeps the VERDICT"; printf '%s\n' "$OUT" | sed 's/^/        | /'
fi
notwant "gate sites:" "$OUT" "--quiet drops the section-1 reading"
notwant "the gate is at line" "$OUT" "--quiet drops the section-2 reading"
notwant "the call(s) that carry that index" "$OUT" "--quiet drops the section-3 reading"
notwant "LEVELS " "$OUT" "--quiet drops the section-4 reading"
NN=$(printf '%s\n' "$OUT" | grep -c . || true)
if [ "$NN" -ge 8 ]; then ok "--quiet still prints $NN non-blank lines (not a truncated tail)"; else bad "--quiet printed only $NN non-blank lines"; fi

OUT=$("$BASH_BIN" "$SRC" --help 2>&1); RC=$?
rc_is 0 "--help exits 0"
want "lpm_levels.sleep_disabled" "$OUT" "--help prints the script's own header"

OUT=$("$BASH_BIN" "$SRC" --src "$W/nope" 2>&1); RC=$?
rc_is 2 "a missing --src is exit 2"
want "a missing input is not a reading" "$OUT" "and it says a missing input is not a reading"

OUT=$("$BASH_BIN" "$SRC" --bogus 2>&1); RC=$?
rc_is 2 "an unknown argument is exit 2"

OUT=$("$BASH_BIN" "$SRC" --src "$W/fx/src" --boot "$W/fx/boot.img" --keep 2>&1); RC=$?
KEPT=$(printf '%s' "$OUT" | sed -n 's/^kept: //p' | sed -n 1p)
if [ -n "$KEPT" ] && [ -d "$KEPT" ]; then ok "--keep says WHERE it kept the intermediates ($KEPT)"; else bad "--keep did not report a directory"; fi
[ -n "$KEPT" ] && rm -rf "$KEPT"

# ==================================================================================================
printf -- '\n--- 7. it is read-only, and it has no device code path ---\n'
# ==================================================================================================
for pat in fastboot adb 'ssh ' 'dd of=' 'mount -' 'mkfs' 'debugfs -w' 'flash '; do
  if grep -qF -- "$pat" "$SRC"; then bad "the subject never names '$pat'"; else ok "the subject never names '$pat'"; fi
done
# WHERE IT WRITES. A pattern scan for `>` matches awk comparisons (`NR>s`), a `->` in a comment and
# `'>9I'` in the python -- so it reports a defect on almost every line and the check becomes one nobody
# reads (docs 149). The reading that matters is the TARGET: every redirect that names a variable must name
# one that is assigned a path under the work directory, and no redirect may name an absolute path outside
# it. That is exact, and it fails when someone writes `> /etc/whatever`.
TGT=$(grep -oE '>>? *"\$[A-Za-z_][A-Za-z_0-9]*"' "$SRC" | grep -oE '\$[A-Za-z_][A-Za-z_0-9]*' | sort -u)
if [ -z "$TGT" ]; then
  ok "the subject redirects into no variable-named file at all"
else
  # The assignment is matched as TEXT (grep -F): an ERE built from `$DTBL` puts a bare `$` -- the
  # end-of-line anchor -- into the pattern, so the check reads `^=.*$W` and reports every variable as
  # unassigned. A check that can only say "bad" is a check nobody keeps.
  for v in $TGT; do
    # the needle is the NAME, without the `$`: an assignment reads `DTBL="...`, not `$DTBL="...`
    assign=$(grep -F -- "${v#\$}=\"" "$SRC" | sed -n 1p)
    case "$assign" in
      *'$W/'*) ok "the subject writes into $v, assigned a path under \$W ($assign)" ;;
      *) bad "the subject redirects into $v, and its assignment is not a path under \$W (${assign:-no assignment found})" ;;
    esac
  done
fi
if grep -nE '(^|[^-=!0-9])>>? */[A-Za-z]' "$SRC" | grep -vE '/dev/null' | grep -qE '/[A-Za-z]'; then
  bad "the subject redirects into an absolute path"
  grep -nE '(^|[^-=!0-9])>>? */[A-Za-z]' "$SRC" | grep -vE '/dev/null' | sed 's/^/        | /'
else
  ok "the subject redirects into no absolute path (its writes are inside \$W)"
fi
# the fixtures themselves are the only files this harness writes, and they are under $W
want "THE KERNEL SOURCE IS ON THIS LAPTOP" "$("$BASH_BIN" "$SRC" --help 2>&1)" \
     "and the header states the premise this instrument exists to correct"
want "not on this device" "$("$BASH_BIN" "$SRC" --help 2>&1)" \
     "by quoting the false claim it replaces"
build normal normal
run
want "READ-ONLY, HOST-SIDE, NO DEVICE: every path below is a file on this laptop." "$OUT" \
     "and the run itself opens by saying it is host-side and read-only"

# ==================================================================================================
printf -- '\n--- 8. this harness is not vacuous: the defects it was written for ---\n'
# ==================================================================================================
# A harness is not a set of assertions about a script; it is a set of assertions that can FAIL. Each of the
# three below is a defect this instrument actually shipped, re-created on a copy by one substitution, and
# the reading that says so is the same one the section above asserts -- so if the subject ever regresses
# this way, the failures above reappear rather than a green run.
mut() { # mut NAME SEDSCRIPT... ; runs the mutated copy on the current fixture
  # ALL the remaining arguments are forwarded: passing only "$2" turned `-e A -e B` into a sed whose
  # script was the literal string `-e`, which fails to parse and reports "unterminated s command" -- a
  # mutation that never ran, asserted as a mutation that changed nothing.
  _n=$1; shift
  sed "$@" "$SRC" > "$W/mut-$_n.sh" || { bad "mutation $_n: sed failed"; return 1; }
  MOUT=$("$BASH_BIN" "$W/mut-$_n.sh" --src "$W/fx/src" --boot "$W/fx/boot.img" --dtb-dir "$W/fx/dtbs" \
         --config "$W/fx/.config" 2>&1); MRC=$?
}
build normal normal
# (a0) THE TYPE READING ITSELF (docs 163). A source it cannot extract a type from must SAY so rather than
# default to the alphabet that happens to be right today -- and the mutation empties PTYPE, which is
# exactly the state a later edit of that one line would leave behind.
mut ptype 's#^PTYPE=.*$#PTYPE=#'
if printf '%s' "$MOUT" | grep -qF 'NOT EXTRACTED'; then
  ok "emptying the type extraction makes it report that it could not read the type"
else
  bad "the type reading silently defaulted -- a source it cannot read would be reported as a bool"
fi
if printf '%s' "$MOUT" | grep -qF 'so sysfs renders'; then
  bad "and it still claimed an alphabet it did not derive"
else
  ok "and it claims no alphabet at all in that state"
fi
# (a) the argument order of find_fn -- `awk -v fn="$2"` hands the awk its FILE as the function name
mut findfn 's/awk -v fn="\$1"/awk -v fn="$2"/'
if printf '%s' "$MOUT" | grep -qF 'NOT FOUND'; then
  ok "restoring the find_fn argument-order bug makes every link report NOT FOUND (section 2 catches it)"
else
  bad "the find_fn mutation did NOT break the chain -- section 2 is not measuring the finder"
fi
# (b) the use-psci lookup compared against a BARE node name instead of the last path component
# `[-1]` is a bracket expression in sed, not the four characters in the file: it has to be escaped, or
# the substitution matches nothing and the "mutation" is the shipped script.
mut usepsi "s/it\[1\]\.split('\/')\[-1\] ==/it[1] ==/"
if printf '%s' "$MOUT" | grep -qF "trees whose lpm-levels node sets qcom,use-psci: 0 of 1"; then
  ok "restoring the bare-name comparison reports 0 of 1 on a tree that sets it (section 4 catches it)"
else
  bad "the bare-name mutation did NOT change the use-psci count -- section 4 is not measuring the path"
fi
if printf '%s' "$MOUT" | grep -qF '== verdict: THE GATE IS SOMETHING ELSE'; then
  ok "...and it takes the verdict down, which is the whole point of counting that property"
else
  bad "the bare-name mutation left the verdict standing"
fi
# (c) the 'LEVELS -' sentinel, counted as a ladder by a `^LEVELS ` grep
build normal no-levels
mut sentinel -e 's/print("LEVELS_NONE")/print("LEVELS -")/' -e 's/\^LEVELS \[\^ \]/^LEVELS /g'
if printf '%s' "$MOUT" | grep -qF '== verdict: THE TREES DISAGREE'; then
  ok "restoring the 'LEVELS -' sentinel turns a tree with NO ladder into a 'trees disagree' finding"
else
  bad "the sentinel mutation did NOT reproduce the defect -- section 4 is not measuring that count"
fi
if [ "$MRC" = 0 ]; then
  ok "...with exit 0, so the defect is a WRONG ANSWER rather than a crash (the shape worth a harness)"
else
  bad "the sentinel defect changed the exit code instead of the answer (rc=$MRC)"
fi
build normal normal

# ==================================================================================================
printf -- '\n--- 9. this harness'"'"'s own citation ---\n'
# ==================================================================================================
# The health check names this harness WITH A CHECK COUNT, hand-typed. A count that is typed by hand and
# never compared is a number that drifts the first time a check is added, so the two are compared here --
# and this is the section that is "one check short" while it runs, which is why the total is +1.
HEALTH="$HERE/zl1-health-check.sh"
if [ -r "$HEALTH" ]; then
  match=$(tr '\n' ' ' < "$HEALTH" | grep -oE 'zl1-lpm-sleep-semantics-selftest\.sh[^0-9]*[0-9]+ checks' | sed -n 1p)
  cited=$(printf '%s\n' "$match" | sed -n 's/.*[^0-9]\([0-9][0-9]*\) checks$/\1/p')
  total=$(( PASS + FAIL + 1 ))
  if [ -z "$cited" ]; then
    bad "the health check no longer cites this harness's count -- either the citation is gone or its wording changed"
  elif [ "$cited" = "$total" ]; then
    ok "the health check cites $cited checks, and this run has exactly that many"
  else
    bad "the health check cites $cited checks, but this harness has $total -- fix host/zl1-health-check.sh"
  fi
else
  bad "cannot read $HEALTH -- its citations are unchecked"
fi

# ==================================================================================================
printf -- '\n%s\n' "=================================================================================="
# The `pass=`/`fail=` line is not decoration: the FAMILY runner reads exactly that line to decide whether
# a harness is green, and a harness that prints only a sentence is reported as NOSUMMARY -- "it printed no
# pass= line, so it cannot be read as green". The first version of this file printed the sentence alone.
printf 'pass=%s fail=%s skip=%s\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" = 0 ]; then
  printf 'ALL GREEN: %d checks, %d skipped\n' "$PASS" "$SKIP"
  printf 'fixtures: %s\n' "$W"
  [ "$KEEP" = 1 ] || rm -rf "$W"
  exit 0
else
  printf 'RED: %d failed, %d passed, %d skipped\n' "$FAIL" "$PASS" "$SKIP"
  printf 'fixtures kept: %s\n' "$W"
  exit 1
fi
