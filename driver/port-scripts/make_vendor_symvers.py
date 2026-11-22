"""Build a Module.symvers fragment for vendor (non-GKI) symbols the peach driver imports.

CRCs come from the phone itself: cnss2.ko's exports and the stock qca_cld3_peach_v2.ko's
import table. Symbols already provided by our kernel build (out/Module.symvers) are skipped.
usage: make_vendor_symvers.py <out/Module.symvers> <phone-crcs.txt> > vendor.symvers
"""
import sys

have = set()
for l in open(sys.argv[1]):
    parts = l.rstrip('\n').split('\t')
    if len(parts) >= 2:
        have.add(parts[1])

rows = {}
for l in open(sys.argv[2]):
    crc, name, kind, f = l.split()
    if name in have:
        continue
    if kind == 'export' and f == 'cnss2.ko':
        rows[name] = (crc, 'cnss2')
    elif kind == 'import' and f == 'qca_cld3_peach_v2.ko':
        rows.setdefault(name, (crc, 'vendor'))

for name, (crc, mod) in sorted(rows.items()):
    print(f'0x{crc}\t{name}\t{mod}\tEXPORT_SYMBOL\t')
sys.stderr.write(f'{len(rows)} vendor symbols\n')
