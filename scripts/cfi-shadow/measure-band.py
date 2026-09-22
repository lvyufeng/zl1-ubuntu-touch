#!/usr/bin/env python3
# Where do the Android libraries live inside a live hybris process, and how big is the CFI shadow
# window that covers them?  The answer sizes the shadow mapping that cfi-shadow-init.c has to fill:
# the shadow is 2 bytes per 2**18 bytes of address space, so a 64 GiB band of libraries costs 1 MiB
# of shadow and a 512 GiB band costs 8 MiB -- the point of measuring is to pick the band.
import re, sys

pid = sys.argv[1]
lo, hi = 1 << 64, 0
n = 0
for line in open(f"/proc/{pid}/maps"):
    m = re.match(r"([0-9a-f]+)-([0-9a-f]+) .* (/android/\S+)", line)
    if not m:
        continue
    a, b = int(m.group(1), 16), int(m.group(2), 16)
    lo, hi = min(lo, a), max(hi, b)
    n += 1

if n == 0:
    raise SystemExit(f"pid {pid} has no /android/ mappings")

print(f"{n} android mappings")
print(f"lo  = 0x{lo:012x}")
print(f"hi  = 0x{hi:012x}")
print(f"span= {(hi - lo) / 2**30:.2f} GiB")
print()
print(f"shadow offset(lo) = 0x{(lo >> 18) << 1:010x}  ({(lo >> 18 << 1) / 2**20:.1f} MiB)")
print(f"shadow offset(hi) = 0x{(hi >> 18) << 1:010x}  ({(hi >> 18 << 1) / 2**20:.1f} MiB)")
print(f"shadow bytes for exactly these libs = {((hi - lo) >> 18) * 2 / 1024:.1f} KiB")
print()
print("what a band would cost (shadow bytes = band size / 2**17):")
for shift in (36, 37, 38, 39, 40):
    band = 1 << shift
    # a band centred on the observed [lo, hi), rounded up to the band size
    centre = (lo + hi) // 2
    b_lo = (centre - band // 2) & ~(band - 1)
    print(f"  band 2**{shift} = {band / 2**30:8.0f} GiB "
          f"-> [0x{b_lo:012x}, 0x{b_lo + band:012x}) costs {band / 2**17 / 2**20:8.2f} MiB of shadow"
          f"  {'covers' if b_lo <= lo and b_lo + band >= hi else 'TOO SMALL'}")
