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
#   TEST    name of a /usr/bin/test_* helper (default test_hwcomposer)
#   OUTDIR  where to keep core + sysroot (default /mnt/data/zl1-bb10/tmp-hybris-<TEST>)

set -uo pipefail
TEST="${1:-test_hwcomposer}"
OUT="${2:-/mnt/data/zl1-bb10/tmp-hybris-$TEST}"
DEV="root@10.15.19.82"
COREDIR="/userdata/zl1-cores"          # on /userdata, rw — the rootfs image is read-only

SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$DEV")
SCP=(scp -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

command -v gdb-multiarch >/dev/null || { echo "need gdb-multiarch on the host: apt install gdb-multiarch" >&2; exit 1; }
mkdir -p "$OUT"

echo "== 1/5  run /usr/bin/$TEST on the device, with cores enabled"
"${SSH[@]}" "bash -s" <<REMOTE
set -u
ulimit -c unlimited
mkdir -p $COREDIR
# A plain file path (not a pipe) so the kernel writes the core where we can read it.
echo '$COREDIR/core.%e.%p' > /proc/sys/kernel/core_pattern || { echo "core_pattern not writable" >&2; exit 1; }
rm -f $COREDIR/core.$TEST.*
cd $COREDIR
timeout 60 /usr/bin/$TEST >/tmp/$TEST.out 2>&1
echo "exit=$?   output=[\$(head -c 200 /tmp/$TEST.out)]"
ls -t $COREDIR/core.$TEST.* 2>/dev/null | head -1
REMOTE

core="$("${SSH[@]}" "ls -t $COREDIR/core.$TEST.* 2>/dev/null | head -1" | tr -d '\r')"
[[ -n "$core" ]] || { echo "no core was written — did the test actually crash?" >&2; exit 1; }
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
exe="$(basename "$TEST")"
[[ -x "$OUT/sysroot/usr/bin/$exe" ]] && MAIN="$OUT/sysroot/usr/bin/$exe" || MAIN="$OUT/sysroot/android/system/bin/$exe"
gdb-multiarch -q -batch -x "$OUT/analyse.gdb" "$MAIN" "$OUT/core" 2>&1 | grep -E '^ADDR' | tee "$OUT/addrs.txt"

# module + offset for every address, from the core's own NT_FILE list.
# The offset is "address minus the start of the containing mapping", which is the ELF's
# link-time vaddr for the first load segment (page offset 0, p_vaddr 0) — the one that
# carries .text, i.e. the only one code addresses can be in.
python3 - "$OUT/nt_file.txt" "$OUT/addrs.txt" <<'PY' | tee "$OUT/resolved.txt"
import re, sys
maps, pending = [], None
for ln in open(sys.argv[1]):
    m = re.match(r'\s*(0x[0-9a-f]+)\s+(0x[0-9a-f]+)\s+(0x[0-9a-f]+)\s*$', ln)
    if m:
        pending = (int(m.group(1), 16), int(m.group(2), 16), int(m.group(3), 16)); continue
    f = ln.strip()
    if f.startswith('/') and pending:
        maps.append((pending[0], pending[1], f)); pending = None
for ln in open(sys.argv[2]):
    _, tag, a = ln.split()
    a = int(a, 16)
    hit = next(((f, a - s) for s, e, f in maps if s <= a < e), None)
    print(f"{tag:8s} 0x{a:x}  {hit[0]} +0x{hit[1]:x}" if hit else f"{tag:8s} 0x{a:x}  (unmapped)")
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
