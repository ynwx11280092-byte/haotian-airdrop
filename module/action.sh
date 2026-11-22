#!/system/bin/sh
# ============================================================================
# KernelSU 「操作」按钮：结束 AirDrop 会话并恢复原厂 Wi-Fi；
# 同时输出设备/校准诊断，便于移植调试。
# ============================================================================
MODDIR=${0%/*}
. "$MODDIR/common.sh"

echo "===== haotian-airdrop $(grep '^version=' "$MODDIR/module.prop" | cut -d= -f2) ====="
echo "设备: $(getprop ro.product.marketname) ($(getprop ro.product.device))"
echo "系统: HyperOS $(getprop ro.mi.os.version.incremental) / SDK $(getprop ro.build.version.sdk)"
echo "内核: $(uname -r)"
echo "配置: $PROFILE_ID / 目标内核 $EXPECTED_KERNEL"
echo ""

# 探测（不修改任何状态）
detect_all || true
echo "原厂驱动: ${DRIVER:-未找到}"
echo "原厂固件: ${AMSS:-未找到}"
echo "WLAN PCI : ${PCI_CTL:-未找到}"
echo "当前状态: $(radio_state)"
[ -f "$MODDIR/disable" ] && echo "模块状态: 已停用（KernelSU）"
if [ -f "$CALIBRATION" ]; then
  if verify_calibration; then
    echo "设备校准: 正常"
  else
    echo "设备校准: 异常 - $CAL_ERR"
  fi
else
  echo "设备校准: 缺失（请重新安装模块）"
fi
echo ""

if [ -f "$NATIVE_DIR/saved.env" ] || [ -e /sys/class/net/xos0 ] || \
   { [ -n "$DRIVER" ] && [ -e "/sys/module/$DRIVER/parameters/pt_activate" ]; }; then
  echo "检测到 AirDrop 会话，正在结束并恢复 Wi-Fi（最多约 1 分钟）..."
  mlog "action: reset requested (state $(radio_state))"
  stop_bridge || echo "守护进程没有按时退出"
  radio_restore
else
  echo "当前没有进行中的 AirDrop 会话。"
  echo "正在做一次幂等的原厂状态恢复..."
  stop_bridge || true
  radio_restore
fi

state=$(radio_state)
pt=0
[ -n "$DRIVER" ] && [ -e "/sys/module/$DRIVER/parameters/pt_activate" ] && pt=1
echo "恢复后状态: $state"
if [ "$state" = STOCK_RESTORED ] && [ "$pt" = 0 ]; then
  if [ "$(settings get global wifi_on)" = 1 ]; then
    if cmd wifi status 2>/dev/null | grep -q 'Wifi is connected to'; then
      echo "✅ Wi-Fi 已恢复并已连接。"
    else
      echo "✅ 已回到原厂 Wi-Fi，正在重新连接网络。"
    fi
  else
    echo "✅ 已回到原厂 Wi-Fi（会话前 Wi-Fi 是关着的，保持关闭）。"
  fi
  mlog "action: restored"
else
  echo "❌ 自动恢复未完成。"
  echo "请直接重启手机：本模块不修改任何分区，重启后 Wi-Fi 会自动恢复正常。"
  tail -n 5 "$STATE_DIR/radio.log" 2>/dev/null
  mlog "action: restore incomplete (state $state, pt=$pt)"
fi
