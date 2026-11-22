#!/bin/bash
# Final mechanical steps of the pandora port, after merge-file + resolve_conflicts + dp_be_tx merge.
set -euo pipefail
B=/data/build
W=$B/work/wlan
cd $W

python3 $B/port/fix_kbuild.py $W

# fw-api: houji's only passthru-specific firmware interface addition (rest is kiwi-only C3 profile).
python3 - <<'EOF'
p = "fw-api/fw/wmi_unified.h"
s = open(p).read()
old = "#define WMI_VDEV_TYPE_MESH_POINT 0x8\n"
if "WMI_VDEV_TYPE_WIFI_PASSTHRU" not in s:
    assert s.count(old) == 1
    s = s.replace(old, old + "#ifdef DRIVER_PASSTHRU_SESSION\n#define WMI_VDEV_TYPE_WIFI_PASSTHRU 0x9\n#endif\n")
    open(p, "w").write(s)
EOF

# policy-manager PCL tables: every row gets a PM_PASSTHRU_MODE entry (houji value or neutral default).
for f in $(grep -oE 'qcacld-3.0/components/cmn_services/policy_mgr/src/wlan_policy_mgr_tables_[^ ]+' $B/houji-patch.list); do
  echo "table: $f"
  python3 $B/port/fill_pm_tables.py $B/houji-overlay/wlan/$f $f
done

# houji's new files, except Xiaomi P2PHC sources (pandora ships its own, newer copies).
for f in $(awk '$1=="A"{print $2}' $B/houji-patch.list | sed 's#^\./##'); do
  case "$f" in */p2phc/*) continue ;; esac
  mkdir -p "$(dirname "$f")"
  cp "$B/houji-overlay/wlan/$f" "$f"
done
git status --short | wc -l
