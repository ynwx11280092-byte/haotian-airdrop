#!/system/bin/sh
# ============================================================================
# XosBridge supervisor（适配自 pandora-airdrop / houji-airdrop）
#
# 职责：在系统 mount namespace 里以 root 身份运行 XosBridge（小米互传通过
# binder 调用它申请/释放 xos0 无线电），并在退出时调用 radio.sh restore，
# 保证任何异常路径都不会把 Wi-Fi 留在独占模式。
#
# 相对上游的改动：
#   * 包名/状态目录来自 $OWLY_XOS/device.conf（安装时生成）；
#   * SELinux 规则覆盖 Android 17 的多个 app 域（platform_app_36 等）；
#   * 退出时先尝试正常 restore，失败再交给 service.sh 开机恢复；
#   * 缺少 ksud/magiskpolicy 时明确退出并记录，不静默失败。
# ============================================================================
set -eu
D=/data/local/tmp/xos/native
OWLY_XOS=/data/local/tmp/xos/owly
BB=""
for cand in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /data/adb/magisk/busybox; do
  if test -x "$cand"; then BB=$cand; break; fi
done
test -n "$BB"

test "$(id -u)" = 0
if test "$(readlink /proc/self/ns/mnt)" != "$(readlink /proc/1/ns/mnt)"; then
  exec "$BB" nsenter -t 1 -m /system/bin/sh "$OWLY_XOS/bridge-supervisor.sh" "$@"
fi
mkdir -p "$D" "$OWLY_XOS/state"
if test "${1:-}" != locked; then
  exec "$BB" flock -n "$D/supervisor.lock" /system/bin/sh "$OWLY_XOS/bridge-supervisor.sh" locked
fi

MISHARE_PKG=com.miui.mishare.connectivity
if test -f "$OWLY_XOS/device.conf"; then
  . "$OWLY_XOS/device.conf"
fi

uid=$(cmd package list packages -U "$MISHARE_PKG" | sed -n "s/^package:$MISHARE_PKG uid:\([0-9]*\)$/\1/p")
test -n "$uid" || { echo "MIShare package not found"; exit 1; }
pm grant "$MISHARE_PKG" android.permission.NETWORK_FACTORY >/dev/null 2>&1 || true
case "$(getprop sys.xos.exclusive)" in
  ''|0) setprop sys.xos.exclusive 0 ;;
esac

apply_sepolicy() {
  rule=$1
  if test -x /data/adb/ksu/bin/ksud; then
    /data/adb/ksu/bin/ksud sepolicy patch "$rule" 2>/dev/null && return 0
  elif test -x /data/adb/ap/bin/magiskpolicy; then
    /data/adb/ap/bin/magiskpolicy --live "$rule" 2>/dev/null && return 0
  elif test -x /data/adb/magisk/magiskpolicy; then
    /data/adb/magisk/magiskpolicy --live "$rule" 2>/dev/null && return 0
  elif command -v magiskpolicy >/dev/null 2>&1; then
    magiskpolicy --live "$rule" 2>/dev/null && return 0
  fi
  return 1
}

ok=0
for dom in platform_app platform_app_36 platform_app_37; do
  if apply_sepolicy "allow $dom default_android_service service_manager { find }"; then ok=1; fi
done
if test "$ok" = 0; then
  echo "Missing ksud or magiskpolicy for live SELinux rule" >&2
  exit 1
fi

boot_id=$(cat /proc/sys/kernel/random/boot_id)
if test "$(cat "$OWLY_XOS/state/sepolicy.boot_id" 2>/dev/null || true)" != "$boot_id"; then
  for dom in ksu magisk su; do
    for k in 0 1 2 3 4 5 6 7; do
      runcon "u:r:$dom:s0:c$k" /system/bin/service list >/dev/null 2>&1 || true
    done
  done
  printf '%s\n' "$boot_id" > "$OWLY_XOS/state/sepolicy.boot_id"
fi

echo $$ > "$D/supervisor.pid"
export CLASSPATH="$OWLY_XOS/xos-bridge.zip"
export XOS_RADIO_SCRIPT="$OWLY_XOS/radio.sh"
/system/bin/app_process /system/bin XosBridge "$uid" 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- &
child=$!
echo "$child" > "$D/bridge.pid"
trap 'kill "$child" 2>/dev/null || true' TERM INT
set +e
wait "$child"
rc=$?
echo "BRIDGE_EXIT=$rc"
/system/bin/sh "$OWLY_XOS/radio.sh" restore
