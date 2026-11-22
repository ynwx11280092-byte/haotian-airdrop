#!/system/bin/sh
# ============================================================================
# haotian-airdrop KernelSU 安装器
# 目标：小米 15 Pro（haotian）HyperOS OS4.0.4.0.XOBCNXM（Android 17 / SDK 37）
#
# 原则：先做完全部校验，再动任何东西；不写任何分区；校验失败直接 abort。
# 相对上游 pandora-airdrop 的变化：
#   * 设备/内核/驱动/固件全部走 device/<profile>.env；
#   * 原厂驱动名、固件路径、PCI 节点在安装时实机探测并记录校准哈希；
#   * 内核模块必须带 EXPECTED_KERNEL 的 vermagic，否则拒绝安装；
#   * 安装前检查 /data 剩余空间、输入固件哈希、LSPosed 状态。
# ============================================================================
SKIPUNZIP=0
MODDIR=${MODPATH:-${0%/*}}
. "$MODDIR/common.sh"

touch "$MODDIR/skip_mount" 2>/dev/null

ui_print "=========================================="
ui_print "  ${DEVICE_NAME} 原生 AirDrop (${DEVICE_CODENAME})"
ui_print "  $(grep '^version=' "$MODDIR/module.prop" | cut -d= -f2)  不修改任何系统分区"
ui_print "=========================================="

[ -n "$BB" ] || abort "! 未找到 KernelSU 自带的 busybox，无法安装"
[ -n "$PROFILE_ID" ] || abort "! 未找到设备配置 device/${PROFILE}.env，安装包不完整"

device=$(getprop ro.product.device)
sdk=$(getprop ro.build.version.sdk)
os=$(getprop ro.mi.os.version.incremental)
kernel=$(uname -r)
ui_print "- 设备: $(getprop ro.product.marketname) ($device)"
ui_print "- 系统: HyperOS $os (SDK $sdk)"
ui_print "- 内核: $kernel"
ui_print "- 配置: $PROFILE_ID ($DEVICE_SOC / $DEVICE_WLAN)"

# ---------- 1. 机型 / 系统 / 内核 ------------------------------------------
device_is_expected || abort "! 仅支持 ${DEVICE_NAME} (${DEVICE_CODENAME})，当前为 $device"
[ "$sdk" = "$EXPECTED_SDK" ] || abort "! 需要 Android 17 (SDK $EXPECTED_SDK)，当前为 SDK $sdk"
kernel_is_allowed || { ui_print "! 内核不匹配，本项目只支持以下内核："; ui_print "  $EXPECTED_KERNEL"; ui_print "  当前: $kernel"; abort "! 已中止，手机未做任何改动"; }
case "$os" in
  "$EXPECTED_BUILD_PREFIX"*) : ;;
  *) ui_print "! 当前系统 $os 与目标 $EXPECTED_BUILD_PREFIX 不完全一致。"; ui_print "  同内核的其它小版本通常可用，但请留意后续 OTA。";;
esac

# ---------- 2. 安装包完整性 / 内核模块材质 ---------------------------------
ui_print "- 校验安装包..."
for f in "$MODDIR/payload/installation.sha256" "$MODDIR/apks/APKS.sha256"; do
  [ -f "$f" ] || abort "! 安装包缺少 $f，请重新下载"
done
(cd "$MODDIR/apks" && sha256sum -c APKS.sha256 >/dev/null) || abort "! APK 校验失败，安装包可能已损坏"
# payload 里除固件外的其它文件的完整性在固件就位后统一校验（见 §7），
# 这里先检查 4 个内核模块是否存在、vermagic 配置后缀与内核主系列是否匹配。
for ko in $KERNEL_MODULES; do
  [ -s "$MODDIR/payload/$ko" ] || abort "! 缺少内核模块 $ko。本机没有可用的编译产物，请先按 BUILD-MODULES.md 在 Linux 上编译"
  vm=$("$BB" strings "$MODDIR/payload/$ko" 2>/dev/null | sed -n 's/^vermagic=//p' | head -n 1)
  # busybox 未编入 strings applet 时用 tr 兜底（vermagic 在 .modinfo 里是 null 结尾字符串）
  [ -n "$vm" ] || vm=$(tr '\0' '\n' < "$MODDIR/payload/$ko" 2>/dev/null | sed -n 's/^vermagic=//p' | head -n 1)
  [ -n "$vm" ] || abort "! 模块 $ko 缺少 vermagic，文件可能损坏"
  suffix=${vm#* }
  if [ "$suffix" != "$EXPECTED_VERMAGIC_SUFFIX" ]; then
    ui_print "! 模块 $ko 的 vermagic 配置后缀不匹配"
    ui_print "  模块: ${suffix:-无}"
    ui_print "  内核: $EXPECTED_VERMAGIC_SUFFIX"
    abort "! 驱动模块不是针对本机内核配置编译的，安装会失败。已中止，手机未做任何改动"
  fi
  uts=${vm%% *}
  # 内核主系列号必须一致（挡住误用 pandora 6.12 模块的情况）
  [ "${uts%%.*}.$(echo "${uts#*.}" | cut -d. -f1)" = "${EXPECTED_KERNEL%%.*}.$(echo "${EXPECTED_KERNEL#*.}" | cut -d. -f1)" ] \
    || abort "! 模块 $ko 是内核 ${uts} 的产物，与手机内核 $EXPECTED_KERNEL 主系列不一致。已中止，手机未做任何改动"
  [ "$uts" = "$EXPECTED_KERNEL" ] || ui_print "  提示: $ko 的 UTS_RELEASE=$uts（与手机 $EXPECTED_KERNEL 不同，CONFIG_MODVERSIONS 下允许，需 CRC 校验通过）"
done
ui_print "  内核模块 vermagic 检查通过"

# ---------- 3. 当前系统必须处于健康的原厂状态 ------------------------------
if [ -f "$NATIVE_DIR/saved.env" ] || [ -e /sys/class/net/xos0 ]; then
  abort "! AirDrop 会话正在进行，请先关闭「与Apple设备互传」再安装"
fi
# 等待原厂驱动加载（安装器运行较早时可能还没加载）
i=0
while [ "$i" -lt 30 ] && ! detect_all; do i=$((i + 1)); sleep 1; done
detect_all || abort "! 未找到原厂 WLAN 驱动/固件/PCI 设备。请先打开一次 Wi-Fi 再安装（驱动名/路径需实机确认）"
[ "$DRIVER_LOADED" = 1 ] || abort "! 原厂 Wi-Fi 驱动尚未加载。请先打开一次 Wi-Fi，等 Wi-Fi 正常连接后重试"
ui_print "- 原厂驱动: $DRIVER ($DRIVER_KO)"
ui_print "- 原厂固件: $AMSS"
ui_print "- WLAN PCI: $PCI_CTL"
[ -r "$(note_path)" ] || abort "! 原厂驱动缺少 build-id note，无法做一致性校验"
if grep -q " $AMSS " /proc/1/mountinfo; then
  abort "! 原厂 Wi-Fi 固件正被替换中（上次会话未恢复），请先重启手机再安装"
fi

# 与实机采集的已知适配指纹比对（STRICT_STOCK_CHECK=1 时不一致直接中止）。
# 这些值来自 2026-11-22 的 haotian OS4.0.4.0.XOBCNXM 实机采集；系统 OTA 改变
# 驱动/固件后旧模块的 CRC 不再匹配，必须等适配，不能硬装。
if [ "${STRICT_STOCK_CHECK:-0}" = 1 ] && [ -n "${KNOWN_STOCK_DRIVER_SHA:-}" ]; then
  cur_driver_sha=$(sha_of "$DRIVER_KO")
  cur_note_sha=$(sha_of "$(note_path)")
  cur_amss_sha=$(sha_of "$AMSS")
  if [ "$DRIVER" != "${KNOWN_STOCK_DRIVER:-$DRIVER}" ] || \
     [ "$cur_driver_sha" != "$KNOWN_STOCK_DRIVER_SHA" ] || \
     [ "$cur_note_sha" != "$KNOWN_STOCK_NOTE_SHA" ] || \
     [ "$cur_amss_sha" != "$KNOWN_STOCK_AMSS_SHA" ]; then
    ui_print "! 原厂 WLAN 驱动/固件与已知适配指纹不一致："
    ui_print "  驱动: $DRIVER sha=$cur_driver_sha (已知 ${KNOWN_STOCK_DRIVER} ${KNOWN_STOCK_DRIVER_SHA})"
    ui_print "  固件: $AMSS sha=$cur_amss_sha (已知 ${KNOWN_STOCK_AMSS} ${KNOWN_STOCK_AMSS_SHA})"
    abort "! 系统可能已 OTA 或不是同一 ROM。本模块只适配上述指纹；请等待适配或修改 device/haotian.env。已中止，手机未做任何改动"
  fi
  ui_print "- 原厂驱动/固件与已知适配指纹一致"
fi

# 已有校准：升级安装时保留；但若当前状态与旧校准不一致（OTA），拒绝覆盖校准
if [ -f "$CALIBRATION" ]; then
  if verify_calibration; then
    ui_print "- 已存在设备校准，原厂驱动/固件未变化"
  else
    ui_print "! 当前原厂状态与上次安装的校准不一致：$CAL_ERR"
    ui_print "  若刚做过系统 OTA，本模块需要新内核模块并重新安装；"
    ui_print "  若只是升级本模块，请重启手机后再安装。"
    abort "! 已中止，未覆盖原有校准"
  fi
fi

# ---------- 4. LSPosed / 小米互传 ------------------------------------------
if [ ! -d /data/adb/modules/zygisk_lsposed ] && [ ! -d /data/adb/lspd ]; then
  ui_print "! 未检测到 LSPosed。没有兼容模块时，打开互传后会话会被中断。"
fi
vc=$(mishare_version_code)
[ -n "$vc" ] || abort "! 未找到小米互传 ($MISHARE_PKG)，无法安装"
if mishare_version_supported "$vc"; then
  ui_print "- 小米互传 versionCode: $vc"
else
  ui_print "! 小米互传版本为 $vc，已知兼容版本：$MISHARE_VC_SUPPORTED"
  ui_print "  AirDrop 接收仍可能可用；Live Photo 合成会自动跳过。"
fi

# ---------- 5. 三星 S26 Ultra 固件 ----------------------------------------
if [ ! -f "$MODDIR/payload/$S26U_FW_REL" ]; then
  ui_print "- 安装包不含三星 S26U 固件，正在手机上查找 amss20.bin ..."
  fw=
  for f in $S26U_FW_SEARCH; do
    if [ -f "$f" ] && [ "$(sha_of "$f")" = "$S26U_FW_SHA" ]; then fw=$f; break; fi
  done
  if [ -z "$fw" ]; then
    ui_print "! 没找到三星 S26 Ultra 的 WLAN 固件。请把 amss20.bin"
    ui_print "  （SM-S948B S948BXXS6BZK1，SHA-256 以 71fc5c2e 开头）"
    ui_print "  放到 /sdcard/Download/s26u-amss20.bin 后重新安装。"
    ui_print "  获取方法见项目 firmware/README.md（python firmware/get_amss20.py）。"
    abort "! 已中止，手机未做任何改动"
  fi
  ui_print "  使用 $fw"
  mkdir -p "$MODDIR/payload/firmware" || abort "! 创建 firmware 目录失败"
  cp "$fw" "$MODDIR/payload/$S26U_FW_REL" || abort "! 复制固件失败"
fi
[ "$(sha_of "$MODDIR/payload/$S26U_FW_REL")" = "$S26U_FW_SHA" ] || abort "! 三星固件 SHA-256 不匹配，拒绝安装"

# ---------- 6. 空间 / 旧守护 ----------------------------------------------
avail=$(df -k /data 2>/dev/null | awk 'NR>1 {print $4; exit}')
case "$avail" in ''|*[!0-9]*) : ;; *) [ "$avail" -lt 65536 ] && abort "! /data 剩余空间不足 64 MB，无法部署运行文件" ;; esac

ui_print "- 停止正在运行的旧版守护..."
stop_bridge || abort "! 旧版守护未能停止，请重启手机后再安装"
[ "$(radio_state)" = RESTORE_FAILED ] && abort "! 上次 Wi-Fi 恢复失败，请先重启手机再安装"

# ---------- 7. 部署 ---------------------------------------------------------
ui_print "- 部署运行文件到 $RUNTIME_DIR ..."
# 固件已就位（payload 内置或从手机复制），现在做 payload 全量校验
(cd "$MODDIR/payload" && sha256sum -c installation.sha256 >/dev/null) || abort "! payload 校验失败，安装包可能已损坏"
sync_runtime "$MODDIR/payload" || abort "! 运行文件部署失败"
rm -f "$STATE_DIR/sepolicy.boot_id"

if [ ! -f "$CALIBRATION" ]; then
  write_calibration || abort "! 设备校准写入失败"
  ui_print "- 已记录本机原厂驱动/固件指纹（OTA 后自动停用保护）"
fi
write_device_conf || abort "! 生成运行时配置失败"

# ---------- 8. LSPosed 兼容模块 -------------------------------------------
ui_print "- 安装 LSPosed 兼容模块 ($COMPAT_PKG)..."
apk="$MODDIR/apks/$COMPAT_APK_NAME"
[ -f "$apk" ] || abort "! 安装包缺少 $COMPAT_APK_NAME"
cur=$(pm path "$COMPAT_PKG" 2>/dev/null | sed -n 's/^package://p' | head -n 1)
if [ -n "$cur" ] && [ "$(sha_of "$cur")" = "$(sha_of "$apk")" ]; then
  ui_print "  已是最新版，保留现有的 LSPosed 启用状态"
  first=0
else
  [ -n "$cur" ] && first=0 || first=1
  # system_server 在 SELinux Enforcing 下只能从 /data/local/tmp 之类的位置读取 APK
  stage=/data/local/tmp/haotian-airdrop-compat.apk
  cp "$apk" "$stage" && chmod 644 "$stage" || abort "! 兼容模块暂存失败"
  out=$(pm install -r "$stage" 2>&1)
  rm -f "$stage"
  case "$out" in
    *Success*) ui_print "  安装成功" ;;
    *INSTALL_FAILED_UPDATE_INCOMPATIBLE*)
      abort "! 已装有不同签名的 $COMPAT_PKG，请先卸载它再安装本模块" ;;
    *) ui_print "  $out"; abort "! 兼容模块安装失败" ;;
  esac
  am force-stop "$MISHARE_PKG" >/dev/null 2>&1 || true
fi

set_perm "$MODDIR/service.sh" 0 0 0755
set_perm "$MODDIR/action.sh" 0 0 0755
set_perm "$MODDIR/uninstall.sh" 0 0 0755
mlog "installed $(grep '^version=' "$MODDIR/module.prop")"
ui_print " "
while IFS= read -r line; do ui_print "$line"; done < "$MODDIR/README.txt"
ui_print " "
ui_print "=========================================="
if [ "$first" = 1 ]; then
  ui_print "✅ 安装完成。请先在 LSPosed 里启用兼容模块，然后重启手机。"
else
  ui_print "✅ 安装完成，重启手机后生效。"
fi
ui_print "=========================================="
