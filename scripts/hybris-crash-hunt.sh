#!/usr/bin/env bash
# Find exactly where a libhybris test dies on the device, without a compiler on either side.
#
# Why this exists: on 2026-09-21 the whole Ubuntu Touch display stack turned out to die
# inside libhybris' Android runtime, and the answer only came out of a core dump plus
# gdb-multiarch. Three earlier guesses (property area, linker variant, tls padding) were
# all wrong. Getting a core is cheap; guessing is not. See docs/ubuntu-touch/40-*.
#
# The device has no gdb and its rootfs is a read-only image, so:
#   * the core is produced by the kernel (core_pattern -> a writable path on /userdata)
#   * the binaries come to us (a sysroot built from the core's own NT_FILE list)
#   * gdb-multiarch on the host does the symbolising
#
# Usage: hybris-crash-hunt.sh [TEST] [OUTDIR]
#        hybris-crash-hunt.sh --from-pid PID [OUTDIR]
#   TEST    name of a /usr/bin/test_* helper (default test_hwcomposer), or any
#           command — a name containing a "/" is used verbatim, which is how the
#           real compositor gets analysed (`/usr/share/ubuntu-touch-session/lsc-wrapper`).
#   OUTDIR  where to keep core + sysroot (default /mnt/data/zl1-bb10/tmp-hybris-<TEST>)
#
# --from-pid is for the other failure mode: a process that *hangs* rather than crashes
# leaves no core, and "it is sitting in futex_wait" is not an answer. SIGABRT turns the
# running process into a core, and then the identical analysis applies. Use it on a
# process something else restarts (lightdm restarts the compositor every 60 s anyway).
#
# Env: HYBRIS_TEST_PRELOAD  LD_PRELOAD for the run (e.g. the TLS-slot shim)
#      HYBRIS_TEST_ARGS     extra arguments appended to the command

set -uo pipefail
FROM_PID=""
if [[ "${1:-}" == "--from-pid" ]]; then
  FROM_PID="${2:?--from-pid needs a pid}"
  shift 2
  TAG="hang"
  CMD="(pid $FROM_PID)"
  OUT="${1:-/mnt/data/zl1-bb10/tmp-hybris-hang}"
else
  TEST="${1:-test_hwcomposer}"
  [[ "$TEST" == */* ]] && CMD="$TEST" || CMD="/usr/bin/$TEST"
  TAG="$(basename "$CMD")"
  OUT="${2:-/mnt/data/zl1-bb10/tmp-hybris-$TAG}"
fi
PRELOAD="${HYBRIS_TEST_PRELOAD:-}"
ARGS="${HYBRIS_TEST_ARGS:-}"
DEV="root@10.15.19.82"
COREDIR="/userdata/zl1-cores"          # on /userdata, rw — the rootfs image is read-only

SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$DEV")
SCP=(scp -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

command -v gdb-multiarch >/dev/null || { echo "need gdb-multiarch on the host: apt install gdb-multiarch" >&2; exit 1; }
mkdir -p "$OUT"

if [[ -n "$FROM_PID" ]]; then
  echo "== 1/5  force a core out of running pid $FROM_PID"
  FROM_COMM="$("${SSH[@]}" "cat /proc/$FROM_PID/comm 2>/dev/null" | tr -d '\r')"
  [[ -n "$FROM_COMM" ]] || { echo "pid $FROM_PID is not running" >&2; exit 1; }
  EXPECT="core.$FROM_COMM.$FROM_PID"
  "${SSH[@]}" "bash -s" <<REMOTE
set -u
mkdir -p $COREDIR
echo '$COREDIR/core.%e.%p' > /proc/sys/kernel/core_pattern || { echo "core_pattern not writable" >&2; exit 1; }
echo "   target: $FROM_COMM  uptime \$(cut -d. -f1 /proc/uptime)s  state \$(awk '{print \$3}' /proc/$FROM_PID/stat)"
readlink -f /proc/$FROM_PID/exe > /tmp/zl1-hunt-exe 2>/dev/null
# RLIMIT_CORE belongs to the *process*, not to this shell: a compositor started by
# systemd->lightdm almost certainly has it at 0, and killing it then leaves only the
# previous session's core behind — which analyses beautifully and means nothing.
echo "   core limit: \$(grep -i 'core file' /proc/$FROM_PID/limits | tr -s ' ')"
prlimit --pid $FROM_PID --core=unlimited || echo "   prlimit failed — no core will be written" >&2
rm -f $COREDIR/core.$FROM_COMM.*
kill -ABRT $FROM_PID
sleep 6
ls -t $COREDIR/core.* 2>/dev/null | head -1
REMOTE
else
  echo "== 1/5  run $CMD on the device, with cores enabled"
  "${SSH[@]}" "bash -s" <<REMOTE
set -u
ulimit -c unlimited
mkdir -p $COREDIR
# A plain file path (not a pipe) so the kernel writes the core where we can read it.
echo '$COREDIR/core.%e.%p' > /proc/sys/kernel/core_pattern || { echo "core_pattern not writable" >&2; exit 1; }
rm -f $COREDIR/core.$TAG.*
cd $COREDIR
LD_PRELOAD="$PRELOAD" timeout 60 $CMD $ARGS >/tmp/$TAG.out 2>&1
echo "exit=\$?   output=[\$(head -c 300 /tmp/$TAG.out)]"
# The core is named after the process that actually died, which for a wrapper script
# (lsc-wrapper) is not the wrapper but the binary it exec'd — so report the newest.
ls -t $COREDIR/core.* 2>/dev/null | head -1
REMOTE
fi

core="$("${SSH[@]}" "ls -t $COREDIR/core.* 2>/dev/null | head -1" | tr -d '\r')"
[[ -n "$core" ]] || { echo "no core was written — did the test actually crash?" >&2; exit 1; }
# comm is capped at 15 characters, so a core's name is not always a usable binary name;
# --from-pid records the real path before the process disappears.
EXE="$("${SSH[@]}" 'cat /tmp/zl1-hunt-exe 2>/dev/null' | tr -d '\r')"
if [[ -n "$FROM_PID" ]]; then
  [[ "$(basename "$core")" == "$EXPECT" ]] ||
    { echo "no new core: expected $EXPECT, newest is $(basename "$core")" >&2; exit 1; }
elif [[ "$(basename "$core")" != core.$TAG.* ]]; then
  echo "   note: the core is from $(basename "$core" | sed 's/^core\.//;s/\.[0-9]*$//'), not $TAG"
fi
echo "   core: $core"

echo "== 2/5  pull the core"
"${SCP[@]}" "$DEV:$core" "$OUT/core" || exit 1

echo "== 3/5  ask the core which files were mapped (NT_FILE note)"
# readelf on the host can read an aarch64 core: the note format is not arch-specific.
readelf -n "$OUT/core" 2>/dev/null | sed -n '/NT_FILE/,$p' > "$OUT/nt_file.txt"
python3 - "$OUT/nt_file.txt" > "$OUT/mapped.txt" <<'PY'
import re, sys
pending = None
for ln in open(sys.argv[1]):
    m = re.match(r'\s*(0x[0-9a-f]+)\s+(0x[0-9a-f]+)\s+(0x[0-9a-f]+)\s*$', ln)
    if m:
        pending = m.group(1); continue
    f = ln.strip()
    if f.startswith('/') and pending:
        print(f); pending = None
PY
sort -u "$OUT/mapped.txt" | grep -Ev '^/(dev|proc|sys)/' > "$OUT/libs.txt"
echo "   $(wc -l < "$OUT/libs.txt") files to fetch"

echo "== 4/5  build a sysroot from the device (dereferenced, original paths kept)"
# The file list goes over as a file rather than into the heredoc: paths in a property
# area look like "/dev/__properties__/u:object_r:default_prop:s0" and quoting them
# inside a remote heredoc is exactly the kind of thing that silently drops entries.
"${SCP[@]}" "$OUT/libs.txt" "$DEV:/tmp/zl1-libs.txt" >/dev/null 2>&1
"${SSH[@]}" "bash -s" <<'REMOTE'
set -u
S=/userdata/zl1-sysroot
rm -rf $S; mkdir -p $S
while IFS= read -r f; do
  [ -e "$f" ] || { echo "  missing on device: $f" >&2; continue; }
  mkdir -p "$S$(dirname "$f")"
  cp -L "$f" "$S$f"
done < /tmp/zl1-libs.txt
cd $S && tar czf /userdata/zl1-sysroot.tgz .
REMOTE
"${SCP[@]}" "$DEV:/userdata/zl1-sysroot.tgz" "$OUT/" || exit 1
mkdir -p "$OUT/sysroot" && tar xzf "$OUT/zl1-sysroot.tgz" -C "$OUT/sysroot"

echo "== 5/5  symbolise"
# The faulting address lives in the NT_SIGINFO note (0x53494749) rather than in gdb:
# gdb-multiarch does not expose $_siginfo for a bare core. It matters because the value
# is usually the immediate operand of the faulting instruction, which names the bug —
# si_addr=0xb00 next to `ldr x8, [x8, #2816]` says "x8 was NULL", not "x8 was garbage".
python3 - "$OUT/core" <<'PY'
import struct, sys
d = open(sys.argv[1], 'rb').read()
e_phoff, = struct.unpack_from('<Q', d, 0x20)
e_phentsize, e_phnum = struct.unpack_from('<HH', d, 0x36)
for i in range(e_phnum):
    o = e_phoff + i * e_phentsize
    if struct.unpack_from('<I', d, o)[0] != 4:
        continue
    p_offset, = struct.unpack_from('<Q', d, o + 8)
    p_filesz, = struct.unpack_from('<Q', d, o + 32)
    off, end = p_offset, p_offset + p_filesz
    while off + 12 <= end:
        namesz, descsz, ntype = struct.unpack_from('<III', d, off)
        name = d[off+12:off+12+namesz].rstrip(b'\0')
        doff = off + 12 + ((namesz + 3) & ~3)
        if name == b'CORE' and ntype == 0x53494749:
            signo, errno, code = struct.unpack_from('<iii', d, doff)
            addr, = struct.unpack_from('<Q', d, doff + 16)
            print(f"signal  : {signo}  si_code={code}  si_addr=0x{addr:x}  (= {addr})")
        off = doff + ((descsz + 3) & ~3)
PY

# Registers and the frame pointer chain come from gdb, which reads them out of
# NT_PRSTATUS. The code pages are *not* in the core (coredump_filter skips file-backed
# private mappings), so $pc resolves to nothing here — that is why the addresses are
# resolved against the module files below, not against the core.
cat > "$OUT/analyse.gdb" <<'EOF'
set sysroot ./sysroot
set print frame-arguments none
printf "ADDR pc 0x%lx\n", $pc
printf "ADDR lr 0x%lx\n", $x30
set $p = $x29
set $n = 0
while $n < 20
  printf "ADDR frame%d 0x%lx\n", $n, *(unsigned long*)($p + 8)
  set $nx = *(unsigned long*)($p)
  if $nx <= $p
    loop_break
  end
  set $p = $nx
  set $n = $n + 1
end
EOF
exe="$(basename "$core")"; exe="${exe#core.}"; exe="${exe%.*}"
if [[ -n "$FROM_PID" && -n "$EXE" && -x "$OUT/sysroot$EXE" ]]; then
  MAIN="$OUT/sysroot$EXE"
else
  [[ -x "$OUT/sysroot/usr/bin/$exe" ]] && MAIN="$OUT/sysroot/usr/bin/$exe" || MAIN="$OUT/sysroot/android/system/bin/$exe"
fi
gdb-multiarch -q -batch -x "$OUT/analyse.gdb" "$MAIN" "$OUT/core" 2>&1 | grep -E '^ADDR' | tee "$OUT/addrs.txt"

# module + offset for every address, from the core's own NT_FILE list.
#
# The offset is the ELF's link-time vaddr, because that is what `info symbol` and
# `disassemble` want. It is NOT simply "address minus the start of the mapping": that
# only holds when the mapping covering the start of the file has p_vaddr == 0, which is
# true for libc.so and false for libhidltransport.so (first LOAD: file 0, vaddr 0xa000).
# Getting it wrong is quiet — the module name is right and the offset is short by that
# vaddr, so it symbols to an unrelated function or to garbage. So: find the address's
# file offset from NT_FILE, then map it through the file's own program headers.
python3 - "$OUT/nt_file.txt" "$OUT/addrs.txt" "$OUT/sysroot" <<'PY' | tee "$OUT/resolved.txt"
import re, struct, sys

PAGE = 4096   # aarch64 with 4K pages; only ever used for non-first mappings

def load_segments(path):
    try:
        d = open(path, 'rb').read()
    except OSError:
        return []
    if d[:4] != b'\x7fELF':
        return []
    e_phoff, = struct.unpack_from('<Q', d, 0x20)
    e_phentsize, e_phnum = struct.unpack_from('<HH', d, 0x36)
    segs = []
    for i in range(e_phnum):
        o = e_phoff + i * e_phentsize
        if struct.unpack_from('<I', d, o)[0] != 1:      # PT_LOAD
            continue
        p_offset, = struct.unpack_from('<Q', d, o + 8)
        p_vaddr,  = struct.unpack_from('<Q', d, o + 16)
        p_filesz, = struct.unpack_from('<Q', d, o + 32)
        segs.append((p_offset, p_vaddr, p_filesz))
    return segs

maps, pending = [], None
for ln in open(sys.argv[1]):
    m = re.match(r'\s*(0x[0-9a-f]+)\s+(0x[0-9a-f]+)\s+(0x[0-9a-f]+)\s*$', ln)
    if m:
        pending = (int(m.group(1), 16), int(m.group(2), 16), int(m.group(3), 16)); continue
    f = ln.strip()
    if f.startswith('/') and pending:
        maps.append((pending[0], pending[1], pending[2] * PAGE, f)); pending = None

segcache = {}
root = sys.argv[3].rstrip('/')
for ln in open(sys.argv[2]):
    _, tag, a = ln.split()
    a = int(a, 16)
    hit = next(((s, e, fo, f) for s, e, fo, f in maps if s <= a < e), None)
    if not hit:
        print(f"{tag:8s} 0x{a:x}  (unmapped)"); continue
    s, e, fo, f = hit
    off = fo + (a - s)
    if f not in segcache:
        segcache[f] = load_segments(root + f)
    v = next((pv + (off - po) for po, pv, fs in segcache[f] if po <= off < po + fs), None)
    print(f"{tag:8s} 0x{a:x}  {f} +0x{v:x}" if v is not None else f"{tag:8s} 0x{a:x}  {f} (no segment)")
PY

# Nearest symbol + the instruction itself, read from the module on disk.
pcmod="$(awk '/^pc /{print $3; exit}' "$OUT/resolved.txt")"
pcoff="$(awk '/^pc /{print $4; exit}' "$OUT/resolved.txt")"
if [[ -n "${pcmod:-}" && -f "$OUT/sysroot$pcmod" ]]; then
  echo
  echo "== nearest symbol and faulting instruction in $pcmod"
  a=$((pcoff)); lo=$((a > 32 ? a - 32 : 0)); hi=$((a + 64))
  gdb-multiarch -q -batch \
    -ex "info symbol $pcoff" \
    -ex "disassemble 0x$(printf '%x' $lo),0x$(printf '%x' $hi)" \
    "$OUT/sysroot$pcmod" 2>&1 | grep -vE "^warning|^\[New|^End of assembler"
fi

echo
echo "core + sysroot kept in $OUT"
