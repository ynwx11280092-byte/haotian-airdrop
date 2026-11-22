"""Generate a force-include header with the canoe vendor config fragment (soc-repo configs/canoe_perf.bzl).

Vendor modules are built against GKI .config + this fragment; ACK's Kconfig does not know the vendor
symbols, so instead of olddefconfig we define them the way include/generated/autoconf.h would.
Options already decided by the GKI .config are left alone (vmlinux ABI stays as verified).
usage: make_vendor_defines.py canoe_perf.bzl out/.config > vendor_defines.h
"""
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


# Vendor 'y' over GKI 'not set' that only affect vendor-module-built code (cfg80211/mac80211 are
# vendor modules on canoe). NL80211_TESTMODE adds testmode_cmd/testmode_dump to cfg80211_ops and
# ieee80211_ops; verified: with it, wiphy_new_nm/ieee80211_alloc_hw_nm CRCs equal the phone's.
MODULE_ONLY_Y = {'CONFIG_NL80211_TESTMODE'}


def skip(name, val):
    """GKI decides built-in/ABI-relevant options; '=m' vendor drivers are module-only and
    invisible to vmlinux, so they apply even where the GKI .config says 'not set'."""
    if name not in gki:
        return False
    if val == 'y' and gki[name] == 'n' and name in MODULE_ONLY_Y:
        return False
    return not (val == 'm' and gki[name] == 'n')

print('/* generated from canoe_perf.bzl: vendor-only config options (mixed build emulation) */')
n = 0
for name, val in frag:
    if skip(name, val):
        continue
    if val == 'y':
        print(f'#ifndef {name}\n#define {name} 1\n#endif')
    elif val == 'm':
        print(f'#ifndef {name}_MODULE\n#define {name}_MODULE 1\n#endif')
    elif val == 'n':
        continue
    else:
        v = val.encode().decode('unicode_escape')
        print(f'#ifndef {name}\n#define {name} {v}\n#endif')
    n += 1
sys.stderr.write(f'{n} vendor-only options defined\n')
