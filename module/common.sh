#!/system/bin/sh
# ============================================================================
# haotian-airdrop 公共库（由 customize/service/action/uninstall source）
#
# 设计要点（相对上游 pandora-airdrop 的改动）：
#   1) 设备相关值全部来自 device/<profile>.env，脚本不再硬编码 pandora；
#   2) 原厂驱动名/驱动路径/固件路径/PCI 电源节点在安装时**实机探测**并写入
#      $NATIVE_DIR/calibration.env，之后每次开机校验；OTA 改变任一值就自动停用；
#   3) 所有"找不到/不匹配"都走安全路径：绝不 insmod 未知模块、绝不修改分区；
#   4) 探测/校验函数可被 tools/preflight.sh 复用。
# ============================================================================

NATIVE_DIR=/data/local/tmp/xos/native
RUNTIME_DIR=/data/local/tmp/xos/owly
STATE_DIR=$RUNTIME_DIR/state
MODULE_LOG=$NATIVE_DIR/module.log
CALIBRATION=$NATIVE_DIR/calibration.env
DEVICE_CONF=$RUNTIME_DIR/device.conf

if [ -z "${MODDIR:-}" ]; then
  if [ -n "${MODPATH:-}" ]; then MODDIR=$MODPATH; else MODDIR=${0%/*}; fi
fi
DRIVER_LOADED=0
MINSTREL_MOD=${MINSTREL_MOD:-rc80211_minstrel_ht}

# ---- busybox ---------------------------------------------------------------
BB=""
for cand in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /data/adb/magisk/busybox; do
  if [ -x "$cand" ]; then BB=$cand; break; fi
done

# ---- 安装器兼容函数 --------------------------------------------------------
if ! command -v ui_print >/dev/null 2>&1; then
  ui_print() { echo "$*"; }
fi
if ! command -v abort >/dev/null 2>&1; then
  abort() { echo "$*"; exit 1; }
fi

# ---- 配置 profile ----------------------------------------------------------
PROFILE=${XOS_PROFILE:-}
if [ -z "$PROFILE" ] && [ -f "$MODDIR/device/profile" ]; then
  PROFILE=$(cat "$MODDIR/device/profile" 2>/dev/null)
fi
[ -n "$PROFILE" ] || PROFILE=haotian
# 打包后 device/ 与 module/ 同级放在模块根目录；源码树里 device/ 在项目根目录。
PROFILE_DIR=$MODDIR/device
[ -f "$PROFILE_DIR/$PROFILE.env" ] || PROFILE_DIR=$MODDIR/../device
if [ -f "$PROFILE_DIR/$PROFILE.env" ]; then
  . "$PROFILE_DIR/$PROFILE.env"
else
  # 允许从已部署的运行时配置兜底（installer 之外的场景）
  [ -f "$NATIVE_DIR/device.profile.env" ] && . "$NATIVE_DIR/device.profile.env"
fi

# ---- 基础工具 --------------------------------------------------------------
mlog() {
  mkdir -p "$NATIVE_DIR" 2>/dev/null
  echo "$(date '+%m-%d %H:%M:%S') $*" >> "$MODULE_LOG"
}

sha_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

file_size() { wc -c < "$1" 2>/dev/null | tr -d ' '; }

# pid_from <pidfile> <cmdline substring>: 只有进程真的存活且命令行匹配才输出 pid
pid_from() {
  p=$(cat "$1" 2>/dev/null || true)
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  { tr '\0' ' ' < "/proc/$p/cmdline"; } 2>/dev/null | grep -q -- "$2" || return 1
  echo "$p"
}

trim_log() {
  [ -f "$1" ] || return 0
  sz=$(wc -c < "$1" 2>/dev/null || echo 0)
  if [ "${sz:-0}" -gt 524288 ]; then
    tail -n 2000 "$1" > "$1.tmp" 2>/dev/null && mv "$1.tmp" "$1"
  fi
}

# ---- 设备/内核判断 ---------------------------------------------------------
kernel_is_allowed() {
  cur=$(uname -r)
  for k in $KERNEL_ACCEPT $EXPECTED_KERNEL; do
    [ "$cur" = "$k" ] && return 0
  done
  return 1
}

kernel_mismatch_text() {
  echo "当前内核 $(uname -r)，需要 $EXPECTED_KERNEL"
}

sdk_is_expected() { [ "$(getprop ro.build.version.sdk)" = "$EXPECTED_SDK" ]; }

device_is_expected() {
  d=$(getprop ro.product.device)
  case "$d" in
    "$DEVICE_CODENAME"|"${DEVICE_CODENAME}_global"|"${DEVICE_CODENAME}_in") return 0 ;;
    *) return 1 ;;
  esac
}

mishare_version_code() {
  dumpsys package "$MISHARE_PKG" 2>/dev/null \
    | sed -n 's/.*versionCode=\([0-9]*\).*/\1/p' | head -n 1
}

mishare_version_supported() {
  vc=$1
  for v in $MISHARE_VC_SUPPORTED; do [ "$vc" = "$v" ] && return 0; done
  return 1
}

# ---- 实机探测 --------------------------------------------------------------
# detect_driver: 设置 DRIVER(/sys/module 名)、DRIVER_KO(文件路径)、DRIVER_LOADED(1=已加载)
detect_driver() {
  DRIVER=""; DRIVER_KO=""; DRIVER_LOADED=0
  for c in $DRIVER_CANDIDATES; do
    if [ -d "/sys/module/$c" ]; then
      DRIVER=$c; DRIVER_LOADED=1
      for f in $DRIVER_KO_CANDIDATES; do
        [ -f "$VENDOR_DLKM_DIR/$f" ] && { DRIVER_KO=$VENDOR_DLKM_DIR/$f; break; }
      done
      [ -n "$DRIVER_KO" ] || DRIVER_KO=$VENDOR_DLKM_DIR/$c.ko
      return 0
    fi
  done
  # 回退 1：任何已加载的 qca_cld3_* 模块
  for m in /sys/module/qca_cld3_*; do
    [ -d "$m" ] || continue
    DRIVER=${m##*/}; DRIVER_LOADED=1
    for f in $DRIVER_KO_CANDIDATES; do
      [ -f "$VENDOR_DLKM_DIR/$f" ] && { DRIVER_KO=$VENDOR_DLKM_DIR/$f; break; }
    done
    [ -n "$DRIVER_KO" ] || DRIVER_KO=$VENDOR_DLKM_DIR/$DRIVER.ko
    return 0
  done
  # 回退 2：文件存在但未加载（如刚重启还没拉起 Wi-Fi）
  for f in $DRIVER_KO_CANDIDATES; do
    if [ -f "$VENDOR_DLKM_DIR/$f" ]; then
      DRIVER=${f%.ko}; DRIVER_KO=$VENDOR_DLKM_DIR/$f; DRIVER_LOADED=0; return 0
    fi
  done
  return 1
}

# detect_amss: 设置 AMSS（原厂 WLAN 固件路径）
detect_amss() {
  AMSS=""
  for f in $FW_CANDIDATES; do
    [ -f "$f" ] && { AMSS=$f; return 0; }
  done
  for d in /vendor/firmware_mnt/image /firmware/image /vendor/firmware; do
    [ -d "$d" ] || continue
    f=$(find "$d" -maxdepth 2 -name 'amss*.bin' -type f 2>/dev/null | head -n 1)
    [ -n "$f" ] && { AMSS=$f; return 0; }
  done
  return 1
}

# detect_pci: 设置 PCI_CTL（WLAN PCI 设备的 power/control 节点）
detect_pci() {
  PCI_CTL=""
  for nd in wlan0 wlan1; do
    [ -e "/sys/class/net/$nd" ] || continue
    dev=$(readlink -f "/sys/class/net/$nd/device" 2>/dev/null) || continue
    bdf=${dev##*/}
    case "$bdf" in
      [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F].[0-9a-fA-F])
        ctl="/sys/bus/pci/devices/$bdf/power/control"
        [ -e "$ctl" ] && { PCI_CTL=$ctl; return 0; } ;;
    esac
  done
  # 回退：Qualcomm PCI 设备 (vendor 0x17cb)
  for ctl in /sys/bus/pci/devices/*/power/control; do
    [ -e "$ctl" ] || continue
    d=${ctl%/power/control}
    [ "$(cat "$d/vendor" 2>/dev/null)" = 0x17cb ] || continue
    PCI_CTL=$ctl; return 0
  done
  return 1
}

# detect_all: 一次性探测全部设备节点，返回 0 表示驱动+固件+PCI 都找到
detect_all() {
  detect_driver || return 1
  detect_amss || return 1
  detect_pci || return 1
  return 0
}

note_path() { echo "/sys/module/$DRIVER/notes/.note.gnu.build-id"; }

# ---- 校准 / 一致性校验 -----------------------------------------------------
# 安装时把"当前健康原厂状态"的驱动/固件哈希记录到 calibration.env；
# 之后每次开机对比。OTA 改了驱动/固件/内核 → 自动停用，避免加载错配模块。
write_calibration() {
  mkdir -p "$NATIVE_DIR" || return 1
  boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
  umask 077
  {
    echo "cal_profile=$PROFILE_ID"
    echo "cal_device=$(getprop ro.product.device)"
    echo "cal_sdk=$(getprop ro.build.version.sdk)"
    echo "cal_kernel=$(uname -r)"
    echo "cal_build=$(getprop ro.build.version.incremental)"
    echo "cal_driver=$DRIVER"
    echo "cal_driver_ko=$DRIVER_KO"
    echo "cal_driver_sha=$(sha_of "$DRIVER_KO")"
    echo "cal_note_sha=$(sha_of "$(note_path)")"
    echo "cal_amss=$AMSS"
    echo "cal_amss_sha=$(sha_of "$AMSS")"
    echo "cal_install_boot=$boot"
    echo "cal_install_time=$(date '+%Y-%m-%d %H:%M:%S')"
  } > "$CALIBRATION.tmp" || return 1
  mv "$CALIBRATION.tmp" "$CALIBRATION" || return 1
  chmod 600 "$CALIBRATION"
}

# verify_calibration: 0 = 一切一致；1 = 不一致（原因见 CAL_ERR）
verify_calibration() {
  CAL_ERR=""
  [ -f "$CALIBRATION" ] || { CAL_ERR="未找到设备校准文件（请重新安装模块）"; return 1; }
  saved_driver=$DRIVER; saved_ko=$DRIVER_KO; saved_amss=$AMSS
  . "$CALIBRATION"
  [ -n "$saved_driver" ] && DRIVER=$saved_driver
  [ -n "$saved_ko" ] && DRIVER_KO=$saved_ko
  [ -n "$saved_amss" ] && AMSS=$saved_amss
  [ "$(uname -r)" = "${cal_kernel:-}" ] || { CAL_ERR="内核已变更：$(uname -r)（校准于 ${cal_kernel:-?}）"; return 1; }
  [ -n "$cal_driver" ] && [ -d "/sys/module/$cal_driver" ] || { CAL_ERR="原厂 WLAN 驱动未加载或已更名（校准为 ${cal_driver:-?}）"; return 1; }
  [ "$(sha_of "$cal_driver_ko")" = "$cal_driver_sha" ] || { CAL_ERR="原厂 WLAN 驱动文件已变更（系统可能已 OTA）"; return 1; }
  [ -n "$cal_note_sha" ] || { CAL_ERR="校准缺少驱动 build-id 记录"; return 1; }
  [ "$(sha_of "/sys/module/$cal_driver/notes/.note.gnu.build-id")" = "$cal_note_sha" ] \
    || { CAL_ERR="已加载的 WLAN 驱动与校准不一致"; return 1; }
  [ -n "$cal_amss" ] && [ -f "$cal_amss" ] || { CAL_ERR="原厂 WLAN 固件不存在（校准为 ${cal_amss:-?}）"; return 1; }
  [ "$(sha_of "$cal_amss")" = "$cal_amss_sha" ] || { CAL_ERR="原厂 WLAN 固件已变更（系统可能已 OTA）"; return 1; }
  DRIVER=$cal_driver; DRIVER_KO=$cal_driver_ko; AMSS=$cal_amss
  return 0
}

cal_get() { sed -n "s/^$1=//p" "$CALIBRATION" 2>/dev/null | head -n 1; }

# ---- 会话状态 --------------------------------------------------------------
session_active() {
  [ -e "$NATIVE_DIR/saved.env" ] && return 0
  [ -e /sys/class/net/xos0 ] && return 0
  [ -n "$DRIVER" ] && [ -e "/sys/module/$DRIVER/parameters/pt_activate" ] && return 0
  return 1
}

radio_state() { cat "$NATIVE_DIR/status" 2>/dev/null || echo UNKNOWN; }

# 停止 XosBridge supervisor（SIGTERM 时它自己会 restore 原厂驱动/固件/Wi-Fi）
stop_bridge() {
  # 全新安装时 native 目录还不存在，flock 无法创建锁文件会误判为“守护未停止”
  mkdir -p "$NATIVE_DIR" 2>/dev/null
  p=$(pid_from "$NATIVE_DIR/supervisor.pid" bridge-supervisor.sh) && kill -TERM "$p" 2>/dev/null
  p=$(pid_from "$NATIVE_DIR/bridge.pid" 'XosBridge') && kill -TERM "$p" 2>/dev/null
  i=0
  while [ "$i" -lt 200 ]; do
    if "$BB" flock -n "$NATIVE_DIR/supervisor.lock" true 2>/dev/null && \
       ! /system/bin/ps -A -o ARGS 2>/dev/null | grep -q '^[a]pp_process /system/bin XosBridge '; then
      return 0
    fi
    i=$((i + 1)); sleep 0.3
  done
  return 1
}

radio_restore() {
  [ -x "$RUNTIME_DIR/radio.sh" ] || [ -f "$RUNTIME_DIR/radio.sh" ] || return 0
  [ -n "$BB" ] || return 1
  "$BB" nsenter -t 1 -m /system/bin/sh "$RUNTIME_DIR/radio.sh" restore >>"$MODULE_LOG" 2>&1
}

# 加载 idle 三件套（bridge + synthetic wonder + mhi），让 wonder_enable=1
radio_idle() {
  j=0
  while [ "$j" -lt 30 ]; do
    detect_driver && [ "$DRIVER_LOADED" = 1 ] && break
    j=$((j + 1)); sleep 1
  done
  [ -n "$DRIVER" ] && [ "$DRIVER_LOADED" = 1 ] || return 1
  "$BB" nsenter -t 1 -m /system/bin/sh "$RUNTIME_DIR/radio.sh" idle >>"$MODULE_LOG" 2>&1
}

# 不带任何模块：把上次会话保存的 Wi-Fi 开关状态恢复（用于模块拒绝运行时）
restore_settings_only() {
  [ -f "$NATIVE_DIR/saved.env" ] || return 0
  saved_wifi=1; saved_scan=0
  . "$NATIVE_DIR/saved.env"
  setprop sys.xos.exclusive 0
  [ "${saved_scan:-0}" = 1 ] && cmd wifi set-scan-always-available enabled
  [ "${saved_wifi:-1}" = 1 ] && cmd wifi set-wifi-enabled enabled
  mv "$NATIVE_DIR/saved.env" "$STATE_DIR/previous-boot.env" 2>/dev/null || rm -f "$NATIVE_DIR/saved.env"
  mlog "restored saved Wi-Fi settings only"
}

unload_idle() {
  [ -e "$NATIVE_DIR/saved.env" ] && return 1
  [ -n "$DRIVER" ] && [ -e "/sys/module/$DRIVER/parameters/pt_activate" ] && return 1
  if [ -e "/sys/module/$WONDER_MOD" ]; then rmmod "$WONDER_MOD" 2>/dev/null || return 1; fi
  if [ -e "/sys/module/$MINSTREL_MOD" ]; then rmmod "$MINSTREL_MOD" 2>/dev/null || true; fi
  if [ -e "/sys/module/$BRIDGE_MOD" ]; then rmmod "$BRIDGE_MOD" 2>/dev/null || return 1; fi
  if [ -e "/sys/module/$MHI_MOD" ]; then rmmod "$MHI_MOD" 2>/dev/null || true; fi
  return 0
}

# ---- 运行时文件同步 --------------------------------------------------------
sync_runtime() {
  src=$1
  [ -f "$src/installation.sha256" ] || return 1
  if [ -f "$RUNTIME_DIR/installation.sha256" ] && cmp -s "$src/installation.sha256" "$RUNTIME_DIR/installation.sha256" && \
     (cd "$RUNTIME_DIR" && sha256sum -c installation.sha256 >/dev/null 2>&1); then
    return 0
  fi
  mkdir -p "$STATE_DIR" "$RUNTIME_DIR/radio" "$RUNTIME_DIR/firmware" "$NATIVE_DIR" || return 1
  chmod 700 "$RUNTIME_DIR" "$STATE_DIR" "$NATIVE_DIR"
  for f in $(awk '{print $2}' "$src/installation.sha256"); do
    mkdir -p "$RUNTIME_DIR/$(dirname "$f")" 2>/dev/null || true
    cp "$src/$f" "$RUNTIME_DIR/$f.new" && mv "$RUNTIME_DIR/$f.new" "$RUNTIME_DIR/$f" || return 1
  done
  cp "$src/installation.sha256" "$RUNTIME_DIR/installation.sha256" || return 1
  for x in radio.sh bridge-supervisor.sh owly-xosd wonder-init; do
    [ -f "$RUNTIME_DIR/$x" ] && chmod 700 "$RUNTIME_DIR/$x"
  done
  sync
  (cd "$RUNTIME_DIR" && sha256sum -c installation.sha256 >/dev/null)
}

# ---- 运行时配置生成 --------------------------------------------------------
conf_line() { printf "%s='%s'\n" "$1" "$2"; }

# 把探测结果/校准值写成 runtime/radio.sh 读取的 device.conf
write_device_conf() {
  mkdir -p "$RUNTIME_DIR" || return 1
  [ -f "$CALIBRATION" ] || return 1
  [ -n "${PCI_CTL:-}" ] && [ -e "$PCI_CTL" ] || return 1
  {
    conf_line PROFILE_ID "$PROFILE_ID"
    conf_line KERNEL "$(cal_get cal_kernel)"
    conf_line DRIVER "$(cal_get cal_driver)"
    conf_line DRIVER_KO "$(cal_get cal_driver_ko)"
    conf_line AMSS "$(cal_get cal_amss)"
    conf_line STOCK_NOTE_SHA "$(cal_get cal_note_sha)"
    conf_line STOCK_AMSS_SHA "$(cal_get cal_amss_sha)"
    conf_line CANDIDATE_SHA "$S26U_FW_SHA"
    conf_line CANDIDATE_REL "$S26U_FW_REL"
    conf_line PCI_CTL "$PCI_CTL"
    conf_line BRIDGE_MOD "$BRIDGE_MOD"
    conf_line MHI_MOD "$MHI_MOD"
    conf_line WONDER_MOD "$WONDER_MOD"
    conf_line MINSTREL_MOD "$MINSTREL_MOD"
    conf_line AWDL_CHANNEL "$AWDL_CHANNEL"
    conf_line ROUTE_TABLE "$ROUTE_TABLE"
    conf_line OWLY_MODE "$XOS_OWLY_MODE"
    conf_line PROFILE "$XOS_PROFILE"
    conf_line PT_PARAMS "$XOS_PT_PARAMS"
  } > "$DEVICE_CONF.tmp" || return 1
  mv "$DEVICE_CONF.tmp" "$DEVICE_CONF" || return 1
  chmod 600 "$DEVICE_CONF"
}

# 兼容旧调用：从 payload 直接部署（安装器用）
deploy_runtime() {
  sync_runtime "$1" || return 1
  return 0
}

# ---- 报告（action/preflight 复用） -----------------------------------------
device_report() {
  echo "# haotian-airdrop 设备报告"
  echo "time=$(date '+%Y-%m-%d %H:%M:%S')"
  echo "device=$(getprop ro.product.device)"
  echo "marketname=$(getprop ro.product.marketname)"
  echo "hyperos=$(getprop ro.mi.os.version.incremental)"
  echo "build=$(getprop ro.build.version.incremental)"
  echo "sdk=$(getprop ro.build.version.sdk)"
  echo "kernel=$(uname -r)"
  echo "profile=$PROFILE_ID"
  echo "expected_kernel=$EXPECTED_KERNEL"
  echo "detected_driver=$DRIVER"
  echo "driver_loaded=$DRIVER_LOADED"
  echo "detected_driver_ko=$DRIVER_KO"
  echo "detected_amss=$AMSS"
  echo "detected_pci=$PCI_CTL"
  echo "driver_sha=$(sha_of "$DRIVER_KO")"
  echo "amss_sha=$(sha_of "$AMSS")"
  echo "note_sha=$(sha_of "$(note_path)")"
  echo "wonder_enable=$(cat /proc/sys/net/wonder/wonder_enable 2>/dev/null || echo missing)"
  echo "cnss_wonder_symbols=$(grep -c cnss_set_vendor_wonder_priv_data /proc/kallsyms 2>/dev/null || echo 0)"
  echo "pt_params=$(ls "/sys/module/$DRIVER/parameters" 2>/dev/null | grep '^pt_' | tr '\n' ' ')"
  echo "mishare_vc=$(mishare_version_code)"
  echo "mishare_installed=$(pm path "$MISHARE_PKG" >/dev/null 2>&1 && echo yes || echo no)"
  echo "lsposed=$([ -d /data/adb/modules/zygisk_lsposed ] && echo yes || echo no)"
  echo "compat_installed=$(pm path "$COMPAT_PKG" >/dev/null 2>&1 && echo yes || echo no)"
  echo "radio_state=$(radio_state)"
  echo "calibration=$([ -f "$CALIBRATION" ] && echo present || echo missing)"
  echo "cal_err=$CAL_ERR"
}
