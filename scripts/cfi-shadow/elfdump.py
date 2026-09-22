#!/usr/bin/env python3
# Minimal ELF dynsym/DT_NEEDED dumper -- the device has python3 but no binutils.
#
#   elfdump.py info <file>            -> class/machine, SONAME, NEEDED
#   elfdump.py syms <file> [regex]    -> defined/undefined dynamic symbols
#   elfdump.py find <file> sym...     -> just report which of these names are exported
import re, struct, sys


def load(path):
    with open(path, "rb") as f:
        return f.read()


def elf_header(b):
    if b[:4] != b"\x7fELF":
        raise SystemExit("not an ELF file")
    is64 = b[4] == 2
    little = b[5] == 1
    e = "<" if little else ">"
    machine = struct.unpack_from(e + "H", b, 18)[0]
    if is64:
        shoff, = struct.unpack_from(e + "Q", b, 0x28)
        shentsize, shnum, shstrndx = struct.unpack_from(e + "HHH", b, 0x3A)
    else:
        shoff, = struct.unpack_from(e + "I", b, 0x20)
        shentsize, shnum, shstrndx = struct.unpack_from(e + "HHH", b, 0x2E)
    return is64, e, machine, shoff, shentsize, shnum, shstrndx


def sections(b):
    is64, e, machine, shoff, shentsize, shnum, shstrndx = elf_header(b)
    out = []
    for i in range(shnum):
        off = shoff + i * shentsize
        if is64:
            name, typ, flags, addr, offset, size, link, info, align, entsize = \
                struct.unpack_from(e + "IIQQQQIIQQ", b, off)
        else:
            name, typ, flags, addr, offset, size, link, info, align, entsize = \
                struct.unpack_from(e + "IIIIIIIIII", b, off)
        out.append(dict(name=name, type=typ, addr=addr, offset=offset, size=size,
                        link=link, entsize=entsize, idx=i))
    strtab_hdr = out[shstrndx]
    def sname(n):
        s = b[strtab_hdr["offset"] + n:]
        return s[:s.index(b"\0")].decode("utf-8", "replace")
    for s in out:
        s["sname"] = sname(s["name"])
    return is64, e, machine, out


def dynsyms(b):
    is64, e, machine, secs = sections(b)
    dyn = next((s for s in secs if s["type"] == 11), None)       # SHT_DYNSYM
    if dyn is None:
        return is64, e, machine, secs, []
    strsec = secs[dyn["link"]]
    strtab = b[strsec["offset"]:strsec["offset"] + strsec["size"]]
    syms = []
    step = 24 if is64 else 16
    for off in range(dyn["offset"], dyn["offset"] + dyn["size"], step):
        if is64:
            name, info, other, shndx, value, size = struct.unpack_from(e + "IBBHQQ", b, off)
        else:
            name, value, size, info, other, shndx = struct.unpack_from(e + "IIIBBH", b, off)
        if name >= len(strtab):
            continue
        end = strtab.find(b"\0", name)
        nm = strtab[name:end].decode("utf-8", "replace")
        syms.append(dict(name=nm, info=info, shndx=shndx, value=value, size=size))
    return is64, e, machine, secs, syms


def dynamic(b):
    is64, e, machine, secs = sections(b)
    dyn = next((s for s in secs if s["type"] == 6), None)        # SHT_DYNAMIC
    if dyn is None:
        return []
    strsec = secs[dyn["link"]]
    strtab = b[strsec["offset"]:strsec["offset"] + strsec["size"]]
    ents = []
    step = 16 if is64 else 8
    for off in range(dyn["offset"], dyn["offset"] + dyn["size"], step):
        if is64:
            tag, val = struct.unpack_from(e + "qQ", b, off)
        else:
            tag, val = struct.unpack_from(e + "iI", b, off)
        ents.append((tag, val))
    out = []
    for tag, val in ents:
        if tag in (1, 14):                                        # NEEDED, SONAME
            end = strtab.find(b"\0", val)
            out.append(({1: "NEEDED", 14: "SONAME"}[tag],
                        strtab[val:end].decode("utf-8", "replace")))
    return out


def main():
    cmd, path = sys.argv[1], sys.argv[2]
    b = load(path)
    is64, e, machine, secs, syms = dynsyms(b)
    if cmd == "info":
        print(f"{path}: {'ELF64' if is64 else 'ELF32'} machine={machine} "
              f"({'aarch64' if machine == 183 else 'arm' if machine == 40 else machine})")
        for k, v in dynamic(b):
            print(f"  {k}: {v}")
        for s in secs:
            if s["type"] in (1, 2, 3):                            # PROGBITS/SYMTAB/STRTAB
                print(f"  section {s['sname']:<22} addr=0x{s['addr']:x} "
                      f"file=0x{s['offset']:x} size=0x{s['size']:x}")
        return
    pat = re.compile(sys.argv[3]) if len(sys.argv) > 3 else None
    if cmd == "syms":
        for s in syms:
            if pat and not pat.search(s["name"]):
                continue
            kind = "DEF" if s["shndx"] != 0 else "UND"
            print(f"  {kind} 0x{s['value']:016x} size={s['size']:<6} {s['name']}")
    elif cmd == "find":
        want = set(sys.argv[3:])
        have = {s["name"]: s for s in syms if s["shndx"] != 0}
        for w in sorted(want):
            s = have.get(w)
            print(f"  {w:<28} {'EXPORTED 0x%x size=%d' % (s['value'], s['size']) if s else 'not exported'}")
    else:
        raise SystemExit(__doc__)


main()
