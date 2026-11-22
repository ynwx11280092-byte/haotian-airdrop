#!/system/bin/sh
# ============================================================================
# KernelSU 卸载钩子。
# KernelSU 在下次开机早期执行本脚本（system_server 尚未就绪），所以需要 Android
# 服务（Wi-Fi 开关、PackageManager）的清理放到一个 detach 的后台任务里，
# 等 boot_completed 之后执行。任务只使用运行时目录和系统工具，不依赖模块目录。
# ============================================================================
MODDIR=${0%/*}
. "$MODDIR/common.sh"

job='NATIVE=$1; RUNTIME=$2; STATE=$3; PKG=$4; BB=$5; BRIDGE=$6; MHI=$7; WONDER=$8
i=0
while [ "$i" -lt 300 ]; do
  [ "$(getprop sys.boot_completed)" = 1 ] && pm path android >/dev/null 2>&1 && break
  i=$((i + 1)); sleep 2
done
# 先停 supervisor：它退出时会自己 restore 原厂驱动/固件/Wi-Fi
for f in supervisor bridge; do
  p=$(cat "$NATIVE/$f.pid" 2>/dev/null)
  case "$p" in ""|*[!0-9]*) ;; *)
    tr "\0" " " < "/proc/$p/cmdline" 2>/dev/null | grep -qE "bridge-supervisor|XosBridge" && kill -TERM "$p" ;;
  esac
done
sleep 3
if [ -f "$RUNTIME/radio.sh" ] && [ -n "$BB" ]; then
  "$BB" nsenter -t 1 -m /system/bin/sh "$RUNTIME/radio.sh" restore >/dev/null 2>&1
fi
if [ ! -e "$NATIVE/saved.env" ]; then
  for m in "$WONDER" "$BRIDGE" "$MHI"; do
    [ -e "/sys/module/$m" ] && rmmod "$m" 2>/dev/null
  done
fi
rm -rf "$RUNTIME" "$NATIVE"
rmdir /data/local/tmp/xos 2>/dev/null
pm uninstall "$PKG" >/dev/null 2>&1'

if [ -n "$BB" ]; then
  "$BB" setsid /system/bin/sh -c "$job" sh \
    "$NATIVE_DIR" "$RUNTIME_DIR" "$STATE_DIR" "$COMPAT_PKG" "$BB" \
    "$BRIDGE_MOD" "$MHI_MOD" "$WONDER_MOD" </dev/null >/dev/null 2>&1 &
else
  /system/bin/sh -c "$job" sh \
    "$NATIVE_DIR" "$RUNTIME_DIR" "$STATE_DIR" "$COMPAT_PKG" "" \
    "$BRIDGE_MOD" "$MHI_MOD" "$WONDER_MOD" </dev/null >/dev/null 2>&1 &
fi
