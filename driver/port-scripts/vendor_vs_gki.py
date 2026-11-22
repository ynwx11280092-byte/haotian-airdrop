"""List canoe vendor-fragment options whose value differs from the GKI .config (other than GKI-off -> vendor-m).
usage: vendor_vs_gki.py canoe_perf.bzl out/.config"""
import re, sys

frag = re.findall(r'"(CONFIG_\w+)":\s*"((?:[^"\\]|\\.)*)"', open(sys.argv[1]).read())
gki = {}
for l in open(sys.argv[2]):
    m = re.match(r'(CONFIG_\w+)=(.*)', l)
    if m:
        gki[m.group(1)] = m.group(2)
        continue
    m = re.match(r'# (CONFIG_\w+) is not set', l)
    if m:
        gki[m.group(1)] = 'n'
for n, v in frag:
    if n in gki and gki[n] != v and not (v == 'm' and gki[n] == 'n'):
        print(n, 'vendor=' + v, 'gki=' + gki[n])
