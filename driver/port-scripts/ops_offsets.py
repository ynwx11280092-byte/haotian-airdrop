"""Find the ieee80211_ops callback offset used by each drv_* function in a mac80211.ko.

Pattern in driver-ops: ldr xA, [xB, #local_ops]; ... ldr xC, [xA, #OP]; ... blr xC
We report, per drv_* function, the offsets of loads whose base register was itself just loaded
from the ieee80211_local->ops field offset (passed as argv[2], hex).
usage: ops_offsets.py <objdump -d output file> <local_ops_off_hex>
"""
import re, sys

ops_off = int(sys.argv[2], 16)
func = None
res = {}
opsregs = set()
for line in open(sys.argv[1]):
    m = re.match(r'^[0-9a-f]+ <([^>]+)>:', line)
    if m:
        func = m.group(1)
        opsregs = set()
        continue
    if not func or not func.startswith('drv_'):
        continue
    m = re.search(r'\bldr\s+(x\d+), \[(x\d+|sp)(?:, #(0x[0-9a-f]+|\d+))?\]', line)
    if not m:
        continue
    dst, base, off = m.group(1), m.group(2), int(m.group(3), 0) if m.group(3) else 0
    if off == ops_off:
        opsregs.add(dst)
        continue
    if base in opsregs:
        res.setdefault(func, [])
        if off not in res[func]:
            res[func].append(off)
    opsregs.discard(dst)

for f in sorted(res):
    print(f, ' '.join(hex(o) for o in res[f]))
