"""Adapt houji's qcacld-3.0/Kbuild additions to pandora (canoe / peach_v2).

- remove the duplicated p2phc objects houji's hunk inserted mid-list (pandora already builds them)
- drop houji's kiwi_v2 "DDK selection" overrides: pandora builds with
  WLAN_PROFILE=canoe_gki_peach-v2, Qualcomm's own defconfig for this target
- drop the kiwi ROM object/macro closure: pandora's Kbuild wires those objects from its config
- PASSTHRU_RUNTIME no longer requires HOUJI_WMI_C3_PROFILE (C3 = Samsung kiwi firmware WMI layout,
  not applicable to peach); the C3 profile itself stays kiwi_v2-only
"""
import re, sys

p = f'{sys.argv[1]}/qcacld-3.0/Kbuild'
s = open(p).read()


def sub1(old, new):
    global s
    n = s.count(old)
    if n != 1:
        raise SystemExit(f'expected 1 match, got {n}:\n{old}')
    s = s.replace(old, new)


_dup = '''		$(HDD_SRC_DIR)/wlan_hdd_wmm.o \\
		$(HDD_SRC_DIR)/p2phc/p2phc.o \\
		$(HDD_SRC_DIR)/p2phc/dlhc.o \\
		$(HDD_SRC_DIR)/p2phc/p2phc_switch.o
		$(HDD_SRC_DIR)/wlan_hdd_wowl.o\\
'''
if _dup in s:  # only present after a plain `patch` run; a 3-way merge does not duplicate them
    sub1(_dup, '''		$(HDD_SRC_DIR)/wlan_hdd_wmm.o \\
		$(HDD_SRC_DIR)/wlan_hdd_wowl.o\\
''')
assert s.count('$(HDD_SRC_DIR)/p2phc/p2phc.o') == 1

s, n = re.subn(r'# BEGIN OFFLINE BUILD-ONLY DDK SELECTION ADAPTATION\n.*?# END OFFLINE BUILD-ONLY DDK SELECTION ADAPTATION\n\n?',
               '', s, flags=re.S)
assert n == 1, n
s, n = re.subn(r'# BEGIN OFFLINE BUILD-ONLY DDK OBJECT/MACRO CLOSURE\n.*?# END OFFLINE BUILD-ONLY DDK OBJECT/MACRO CLOSURE\n\n?',
               '', s, flags=re.S)
assert n == 1, n

sub1('''ifneq ($(HOUJI_WMI_C3_PROFILE),1)
$(error CONFIG_DRIVER_PASSTHRU_RUNTIME requires HOUJI_WMI_C3_PROFILE=1)
endif
''', '')

open(p, 'w').write(s)
print('Kbuild adapted')
