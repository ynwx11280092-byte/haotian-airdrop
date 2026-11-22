#!/system/bin/sh
# ============================================================================
# haotian-airdrop device preflight (v2) - READ ONLY
#
# Usage:
#   adb push tools/preflight.sh /data/local/tmp/
#   adb shell su -c 'sh /data/local/tmp/preflight.sh'
#   # report:   /sdcard/Download/haotian-airdrop-preflight.txt
#   # dump dir: /sdcard/Download/haotian-dump/  (stock .ko files for CRC/offset work)
#
# v2 adds (vs v1):
#   * full vermagic of the stock WLAN driver (v1 cut it at the first space)
#   * /proc/kallsyms checks for cnss/mhi symbols needed by the port
#   * copies the stock qca_cld3_peach_v2.ko / cnss2.ko / mhi.ko to
#     /sdcard/Download/haotian-dump so they can be sent to the PC (CRC extraction)
#   * ASCII-only output so it survives IM/WeChat transcoding
# ============================================================================
OUT=/sdcard/Download/haotian-airdrop-preflight.txt
DUMP=/sdcard/Download/haotian-dump
BB=""
for cand in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /data/adb/magisk/busybox; do
  if [ -x "$cand" ]; then BB=$cand; break; fi
done
sha_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
pt() { printf '%-26s %s\n' "$1" "$2"; }
vm_of() {
  v=$("$BB" strings "$1" 2>/dev/null | sed -n 's/^vermagic=//p' | head -n 1)
  [ -n "$v" ] || v=$(tr '\0' '\n' < "$1" 2>/dev/null | sed -n 's/^vermagic=//p' | head -n 1)
  echo "$v"
}

report() {
  echo "==================== haotian-airdrop preflight v2 ===================="
  pt time "$(date '+%Y-%m-%d %H:%M:%S')"
  pt root_uid "$(id -u)"
  echo "--- props ---"
  pt device "$(getprop ro.product.device)"
  pt marketname "$(getprop ro.product.marketname)"
  pt hyperos "$(getprop ro.mi.os.version.incremental)"
  pt build "$(getprop ro.build.version.incremental)"
  pt sdk "$(getprop ro.build.version.sdk)"
  pt security_patch "$(getprop ro.build.version.security_patch)"
  pt kernel "$(uname -r)"
  pt kernel_full "$(cat /proc/version)"
  echo "--- WLAN driver ---"
  pt sys_module_qca "$([ -d /sys/module/qca_cld3_peach_v2 ] && echo loaded || echo missing)"
  pt sys_module_cnss2 "$([ -d /sys/module/cnss2 ] && echo loaded || echo missing)"
  pt sys_module_mhi "$([ -d /sys/module/mhi ] && echo loaded || echo builtin-or-missing)"
  echo "/sys/module/qca_cld3_peach_v2/parameters:"
  ls /sys/module/qca_cld3_peach_v2/parameters 2>/dev/null | sed 's/^/  /'
  echo "/proc/modules (wlan/cnss/mhi):"
  grep -E '^(qca_cld3|cnss2|mhi|wlan)' /proc/modules 2>/dev/null | sed 's/^/  /'
  ko=""
  for f in /vendor_dlkm/lib/modules/qca_cld3_peach_v2.ko /vendor_dlkm/lib/modules/qca_cld3_peach.ko /vendor_dlkm/lib/modules/qca_cld3_*.ko; do
    [ -f "$f" ] && { ko=$f; break; }
  done
  if [ -n "$ko" ]; then
    pt driver_ko "$ko"
    pt driver_size "$(wc -c < "$ko" | tr -d ' ')"
    pt driver_sha256 "$(sha_of "$ko")"
    pt driver_vermagic_full "$(vm_of "$ko")"
  else
    pt driver_ko "NOT FOUND (check /vendor_dlkm/lib/modules as root)"
  fi
  pt driver_note_sha256 "$(sha_of /sys/module/qca_cld3_peach_v2/notes/.note.gnu.build-id)"
  echo "--- WLAN firmware ---"
  for f in /vendor/firmware_mnt/image/peach/amss20.bin /vendor/firmware_mnt/image/peach/amss.bin; do
    [ -f "$f" ] && pt "$f" "size=$(wc -c < "$f" | tr -d ' ') sha256=$(sha_of "$f")"
  done
  echo "--- wonder / PASSTHRU support ---"
  pt wonder_enable "$(cat /proc/sys/net/wonder/wonder_enable 2>/dev/null || echo missing)"
  pt cnss_set_vendor_wonder_priv_data "$(grep -c 'cnss_set_vendor_wonder_priv_data' /proc/kallsyms 2>/dev/null)"
  pt cnss_wonder_any "$(grep -c 'cnss_wonder' /proc/kallsyms 2>/dev/null)"
  pt cnss_get_wlan_tsf_gpio "$(grep -c 'cnss_get_wlan_tsf_gpio' /proc/kallsyms 2>/dev/null)"
  pt mhi_bdf_to_controller "$(grep -c 'mhi_bdf_to_controller' /proc/kallsyms 2>/dev/null)"
  pt mhi_ctrl_symbols "$(grep -c 'mhi_controller' /proc/kallsyms 2>/dev/null)"
  echo "--- MIShare ---"
  pt mishare_path "$(pm path com.miui.mishare.connectivity 2>/dev/null)"
  pt mishare_vc "$(dumpsys package com.miui.mishare.connectivity 2>/dev/null | sed -n 's/.*versionCode=\([0-9]*\).*/\1/p' | head -n 1)"
  pt mishare_vn "$(dumpsys package com.miui.mishare.connectivity 2>/dev/null | sed -n 's/.*versionName=\([^ ]*\).*/\1/p' | head -n 1)"
  echo "--- root / LSPosed ---"
  pt ksu "$([ -d /data/adb/ksu ] && echo yes || echo no)"
  pt magisk "$([ -d /data/adb/magisk ] && echo yes || echo no)"
  pt lsposed "$([ -d /data/adb/modules/zygisk_lsposed ] || [ -d /data/adb/lspd ] && echo yes || echo no)"
  echo "--- existing module traces ---"
  pt xos_dir "$(ls -d /data/local/tmp/xos 2>/dev/null || echo none)"
  pt xos0 "$([ -e /sys/class/net/xos0 ] && echo present || echo none)"
  echo "--- WLAN PCI ---"
  for d in /sys/class/net/wlan0 /sys/class/net/wlan1; do
    [ -e "$d" ] || continue
    pt "$d" "$(readlink -f "$d/device" 2>/dev/null)"
  done
  for c in /sys/bus/pci/devices/*/power/control; do
    [ -e "$c" ] || continue
    dd=${c%/power/control}
    [ "$(cat "$dd/vendor" 2>/dev/null)" = 0x17cb ] && pt wlan_pci_ctl "$c"
  done
  echo "--- dmesg (wlan/cnss, last 25) ---"
  dmesg 2>/dev/null | grep -iE 'cnss|qca_cld3|wlan|peach|mhi' | tail -n 25 | sed 's/^/  /'
  echo "===================================================================="
}

collect_dump() {
  mkdir -p "$DUMP" 2>/dev/null || return 0
  echo "--- stock kernel modules copied to $DUMP ---"
  for f in /vendor_dlkm/lib/modules/qca_cld3_peach_v2.ko \
           /vendor_dlkm/lib/modules/cnss2.ko \
           /vendor_dlkm/lib/modules/mhi.ko \
           /vendor_dlkm/lib/modules/mhi_9300.ko; do
    [ -f "$f" ] || continue
    b=${f##*/}
    if cp -f "$f" "$DUMP/$b" 2>/dev/null; then
      chmod 644 "$DUMP/$b" 2>/dev/null
      echo "  copied $b  size=$(wc -c < "$DUMP/$b" | tr -d ' ')  sha256=$(sha_of "$DUMP/$b")"
    else
      echo "  COPY FAILED $f (SELinux/permission?)"
    fi
  done
  # mhi may be builtin or under a different name
  if [ ! -f "$DUMP/mhi.ko" ]; then
    for f in $(find /vendor_dlkm/lib/modules -maxdepth 1 -name 'mhi*.ko' 2>/dev/null); do
      b=${f##*/}
      cp -f "$f" "$DUMP/$b" 2>/dev/null && chmod 644 "$DUMP/$b" 2>/dev/null && \
        echo "  copied $b  size=$(wc -c < "$DUMP/$b" | tr -d ' ')  sha256=$(sha_of "$DUMP/$b")"
    done
  fi
}

mkdir -p /sdcard/Download 2>/dev/null
{
  report
  collect_dump
} 2>&1 | tee "$OUT"
echo ""
echo "report: $OUT"
echo "dump  : $DUMP (send qca_cld3_peach_v2.ko / cnss2.ko / mhi*.ko to the PC, they are needed for CRC + MHI offset work)"
