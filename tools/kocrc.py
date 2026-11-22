"""Extract symbol CRCs from Linux .ko files (arm64, ELF64 LE).

imports: __versions (64-byte entries) and __version_ext_crcs/__version_ext_names
exports: __crc_<sym> symbols pointing into __kcrctab*
usage: python -I kocrc.py a.ko [b.ko ...]   -> prints "<crc> <sym> <kind> <file>"
"""
import os, struct, sys


def sections(d):
    shoff, = struct.unpack_from('<Q', d, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', d, 0x3A)
    secs = [struct.unpack_from('<IIQQQQIIQQ', d, shoff + i * shentsize) for i in range(shnum)]
    so = secs[shstrndx][4]
    names = [d[so + s[0]:d.index(b'\0', so + s[0])].decode() for s in secs]
    return secs, names


def run(path):
    d = open(path, 'rb').read()
    secs, names = sections(d)
    base = os.path.basename(path)
    by = {n: s for n, s in zip(names, secs)}
    if '__versions' in by:
        s = by['__versions']
        for i in range(0, s[5], 64):
            crc, = struct.unpack_from('<Q', d, s[4] + i)
            n = d[s[4] + i + 8:s[4] + i + 64].split(b'\0')[0].decode()
            print(f'{crc & 0xffffffff:08x} {n} import {base}')
    if '__version_ext_crcs' in by and '__version_ext_names' in by:
        c, n = by['__version_ext_crcs'], by['__version_ext_names']
        nm = d[n[4]:n[4] + n[5]].split(b'\0')
        for i in range(c[5] // 4):
            crc, = struct.unpack_from('<I', d, c[4] + i * 4)
            print(f'{crc:08x} {nm[i].decode()} import {base}')
    # exports via __crc_ symbols
    for s in secs:
        if s[1] != 2:
            continue
        stro = secs[s[6]][4]
        for i in range(s[5] // s[9]):
            nm_off, info, other, shndx, val, size = struct.unpack_from('<IBBHQQ', d, s[4] + i * s[9])
            if not nm_off or shndx == 0 or shndx >= len(secs):
                continue
            nm = d[stro + nm_off:d.index(b'\0', stro + nm_off)]
            if not nm.startswith(b'__crc_'):
                continue
            tgt = secs[shndx]
            if tgt[1] == 8:  # NOBITS
                continue
            crc, = struct.unpack_from('<I', d, tgt[4] + val)
            print(f'{crc:08x} {nm[6:].decode()} export {base}')


for p in sys.argv[1:]:
    run(p)
