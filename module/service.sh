#!/system/bin/sh
# ============================================================================
# haotian-airdrop 开机服务
#
# 职责：安全校验（内核/驱动/固件/校准）→ 部署运行时 → 恢复被重启打断的会话
#       → 维护 XosBridge supervisor；模块被停用时卸载 idle 三件套。
#
# 后台/功耗设计（相对上游的优化）：
#   * 全程事件驱动：阻塞在 busybox inotifyd 上等待 KernelSU 的 disable/remove；
#     inotifyd 不可用时退化为 30 秒轮询（仅比较标志位，无高频唤醒）。
#   * supervisor 崩溃重启采用 5→10→20→40→60 秒指数退避：崩溃循环不再每 5 秒拉起
#     app_process/nsenter，显著降低异常时的 CPU 唤醒。
#   * 启动等待有上限（180+60 秒），OTA 后内核不匹配立即退出，不进入任何循环。
# ============================================================================
MODDIR=${0%/*}
. "$MODDIR/common.sh"
[ -n "$BB" ] || exit 1

BASE_DESC="${DEVICE_NAME} 原生 AirDrop：iPhone 隔空投送到小米互传，Live Photo 合成动态照片。不修改系统分区。"
set_desc() {
  awk -v d="$1 $BASE_DESC" '/^description=/ { print "description=" d; next } { print }' \
    "$MODDIR/module.prop" > "$MODDIR/module.prop.tmp" 2>/dev/null && \
    mv "$MODDIR/module.prop.tmp" "$MODDIR/module.prop"
}

wait_boot() {
  i=0
  while [ "$i" -lt 180 ]; do
    if [ "$(getprop sys.boot_completed)" = 1 ]; then
      # pm 调用会拉起 app_process，只在 boot_completed 之后每 3 秒探一次
      if [ $((i % 3)) -eq 0 ] && pm path "$MISHARE_PKG" >/dev/null 2>&1; then
        return 0
      fi
    fi
    i=$((i + 1)); sleep 1
  done
  return 1
}

mkdir -p "$NATIVE_DIR" "$STATE_DIR"
chmod 700 "$NATIVE_DIR" 2>/dev/null
trim_log "$MODULE_LOG"
trim_log "$STATE_DIR/radio.log"
trim_log "$STATE_DIR/supervisor.log"
trim_log "$NATIVE_DIR/owly-bridge.log"
mlog "boot: service start (kernel $(uname -r), profile $PROFILE_ID)"
wait_boot || mlog "warning: boot_completed/MIShare not ready after 180s, continuing"
mlog "boot: running checks"

# ---- 1. 内核 / 驱动 / 固件 / 校准 校验 ------------------------------------
if ! kernel_is_allowed; then
  restore_settings_only
  mlog "kernel $(uname -r) not in support list; module disabled"
  set_desc "[⚠ 已自动停用：内核 $(uname -r) 不在支持列表，请等待适配]"
  exit 0
fi

i=0
while [ "$i" -lt 60 ]; do
  detect_all && [ "$DRIVER_LOADED" = 1 ] && break
  i=$((i + 1)); sleep 1
done
if [ -z "$DRIVER" ] || [ -z "$AMSS" ] || [ -z "$PCI_CTL" ] || [ "$DRIVER_LOADED" != 1 ]; then
  restore_settings_only
  mlog "stock WLAN driver/firmware not detected; module disabled (driver=$DRIVER loaded=$DRIVER_LOADED amss=$AMSS pci=$PCI_CTL)"
  set_desc "[⚠ 已自动停用：未找到原厂 WLAN 驱动/固件，请打开一次 Wi-Fi 或重启]"
  exit 0
fi

if [ ! -f "$CALIBRATION" ]; then
  restore_settings_only
  mlog "calibration missing; module disabled"
  set_desc "[⚠ 请重新安装模块：缺少设备校准数据]"
  exit 0
fi
if ! verify_calibration; then
  restore_settings_only
  mlog "calibration failed: $CAL_ERR"
  set_desc "[⚠ 已自动停用：$CAL_ERR]"
  exit 0
fi
mlog "verified: driver=$DRIVER fw=$AMSS pci=$PCI_CTL"

# ---- 2. 运行时部署（失败重试一次） ---------------------------------------
if ! sync_runtime "$MODDIR/payload"; then
  mlog "runtime sync failed, retrying once"
  sleep 10
  if ! sync_runtime "$MODDIR/payload"; then
    mlog "runtime sync failed twice; module disabled"
    set_desc "[⚠ 运行文件损坏，请重新安装模块]"
    exit 0
  fi
fi
write_device_conf || mlog "warning: device.conf write failed"

# ---- 3. 恢复被重启打断的会话 ----------------------------------------------
[ -e "$NATIVE_DIR/saved.env" ] && radio_restore

# ---- 4. supervisor 管理 ----------------------------------------------------
RUNNER=
start_runner() {
  [ -n "$RUNNER" ] && kill -0 "$RUNNER" 2>/dev/null && return 0
  (
    delay=5
    while :; do
      start=$(date +%s)
      "$BB" nsenter -t 1 -m /system/bin/sh "$RUNTIME_DIR/bridge-supervisor.sh" \
        </dev/null >>"$NATIVE_DIR/owly-bridge.log" 2>&1
      rc=$?
      echo "$(date '+%m-%d %H:%M:%S') supervisor exited rc=$rc (backoff ${delay}s)" >> "$MODULE_LOG"
      trim_log "$NATIVE_DIR/owly-bridge.log"
      if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]; then exit 0; fi
      sleep "$delay"
      # 运行超过 2 分钟才退出的，视为偶发错误，重置退避
      if [ $(( $(date +%s) - start )) -ge 120 ]; then delay=5
      else delay=$((delay * 2)); [ "$delay" -gt 60 ] && delay=60; fi
    done
  ) &
  RUNNER=$!
  mlog "runner started ($RUNNER)"
}

stop_runner() {
  if [ -n "$RUNNER" ]; then kill -TERM "$RUNNER" 2>/dev/null; RUNNER=; fi
  stop_bridge || mlog "bridge did not stop in time"
  radio_restore
}

idle_with_retry() {
  i=1
  while [ "$i" -le 3 ]; do
    if radio_idle; then return 0; fi
    mlog "idle modules failed to load (try $i)"
    i=$((i + 1)); sleep 10
  done
  return 1
}

apply_state() {
  if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]; then
    stop_runner
    unload_idle || mlog "idle modules busy"
    if [ -f "$MODDIR/remove" ]; then set_desc "[🗑 将在重启后卸载]"; else set_desc "[⏸ 已停用]"; fi
    mlog "paused"
    return 0
  fi
  if ! idle_with_retry; then
    mlog "idle modules failed to load after retries"
    set_desc "[⚠ 空闲模块加载失败，请重启手机]"
    return 0
  fi
  start_runner
  set_desc "[✅ 运行中]"
}

apply_state

# ---- 5. 事件循环（disable/remove 变化时重新应用） -------------------------
if "$BB" inotifyd 2>&1 | grep -qi 'usage'; then
  "$BB" inotifyd - "$MODDIR:nd" 2>/dev/null | while IFS="$(printf '\t')" read -r ev dir name; do
    case "$name" in disable|remove) apply_state ;; esac
  done
else
  # 没有 inotifyd 的 busybox：30 秒轮询标志位（状态不变时不做任何事，几乎无唤醒开销）
  prev=""
  while :; do
    cur=idle
    if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]; then cur=paused; fi
    if [ "$cur" != "$prev" ]; then prev=$cur; apply_state; fi
    sleep 30
  done
fi
