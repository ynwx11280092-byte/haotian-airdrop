"""Qualcomm signed ELF (MBN) integrity check + basic info.
Finds the hash-table segment (p_flags OS-segment type 2 = HASH) and verifies each segment's digest.
Prints version strings (QC_IMAGE_VERSION / WLAN.*) for comparison.
usage: mbn_check.py file..."""
import hashlib, re, struct, sys


def check(path):
    d = open(path, 'rb').read()
    assert d[:4] == b'\x7fELF', 'not ELF'
    cls = d[4]
    if cls == 2:
        phoff, = struct.unpack_from('<Q', d, 0x20); phentsize, phnum = struct.unpack_from('<HH', d, 0x36)
        fmt, fields = '<IIQQQQQQ', ('type', 'flags', 'off', 'vaddr', 'paddr', 'filesz', 'memsz', 'align')
    else:
        phoff, = struct.unpack_from('<I', d, 0x1c); phentsize, phnum = struct.unpack_from('<HH', d, 0x2a)
        fmt, fields = '<IIIIIIII', ('type', 'off', 'vaddr', 'paddr', 'filesz', 'memsz', 'flags', 'align')
    ph = [dict(zip(fields, struct.unpack_from(fmt, d, phoff + i * phentsize))) for i in range(phnum)]
    hseg = [p for p in ph if (p['flags'] >> 24) & 7 == 2]
    print(f'{path}: size={len(d)} sha256={hashlib.sha256(d).hexdigest()} ELF{32 * cls} segments={phnum}')
    if hseg:
        h = d[hseg[0]['off']:hseg[0]['off'] + hseg[0]['filesz']]
        ok = None
        for name, n in (('sha384', 48), ('sha256', 32)):
            # header size varies by MBN version: find the offset where segment 0 (ELF+PH) digest appears
            elfph = d[:phoff + phnum * phentsize]
            dg = hashlib.new(name, elfph).digest()
            pos = h.find(dg)
            if pos < 0:
                continue
            bad = 0; good = 0
            for i, p in enumerate(ph):
                exp = h[pos + i * n:pos + (i + 1) * n]
                if i == 0 or p is hseg[0] or p['filesz'] == 0:
                    continue
                got = hashlib.new(name, d[p['off']:p['off'] + p['filesz']]).digest()
                if got == exp:
                    good += 1
                elif exp != bytes(n):
                    bad += 1
            ok = (name, good, bad)
            break
        print('  hash table:', ok if ok else 'segment-0 digest not found (cannot verify)')
    vers = sorted(set(m.decode() for m in re.findall(rb'(?:QC_IMAGE_VERSION_STRING=|OEM_IMAGE_VERSION_STRING=|WLAN\.[A-Z]{2,4}\.)[\x21-\x7e]{3,80}', d)))
    for v in vers[:8]:
        print('  ', v)


for p in sys.argv[1:]:
    check(p)
