#!/system/bin/sh
# ============================================================================
# haotian (Xiaomi 15 Pro) xos0 无线电后端 —— 适配自 pandora-airdrop 的
# runtime/owly-xos/radio.sh。
#
# 运行时只读 /data/local/tmp/xos/owly 下的部署文件；三星 amss20.bin 用 bind
# mount 临时替换，重启即消失；不写任何分区。
#
# 动作：idle | enter | restore | status | diag
#   idle   : 原厂 Wi-Fi + xos_wonder_bridge + wonder(synthetic)，让
#            /proc/sys/net/wonder/wonder_enable=1（小米互传据此显示入口）
#   enter  : 独占无线电：原厂驱动 -> PT 驱动 + S26U 固件 + wonder + owly-xosd(xos0)
#   restore: 恢复原厂驱动/固件/Wi-Fi 开关，再回到 idle
#
# 相对上游的健壮性改动：
#   * 设备节点（驱动名/固件路径/PCI 节点）来自 $R/device.conf（安装时实机探测），
#     不再硬编码 pandora；
#   * 所有可能无限循环/无界等待的地方都加了上限（umount、等待 refcnt、等待
#     pt_activate、等待 owly ready），失败时明确回滚而不是卡死；
#   * enter 失败一定走 restore；restore 失败记录 RESTORE_FAILED，开机由
#     service.sh 再次恢复；
#   * 每一步关键状态写 radio.log，便于模块「操作」按钮诊断。
# ============================================================================
set -eu

R=/data/local/tmp/xos/owly
STATE=$R/state
RADIO=$R/radio
NATIVE=/data/local/tmp/xos/native
BB=""
for cand in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /data/adb/magisk/busybox; do
  if test -x "$cand"; then BB=$cand; break; fi
done
test -n "$BB"
test -f "$R/device.conf" || { echo "missing $R/device.conf (reinstall module)"; exit 1; }
. "$R/device.conf"

W=/sys/module/$DRIVER
BRIDGE=$BRIDGE_MOD
REL=/sys/module/$BRIDGE/parameters/pt_release
MF=/sys/module/$MHI_MOD/parameters/realloc
STOCK=$DRIVER_KO
PCI=$PCI_CTL
IFACE=xos0
CANDIDATE=$CANDIDATE_SHA
CPATH=$R/$CANDIDATE_REL

test "$(id -u)" = 0
if test "$(readlink /proc/self/ns/mnt)" != "$(readlink /proc/1/ns/mnt)"; then
  exec "$BB" nsenter -t 1 -m /system/bin/sh "$R/radio.sh" "$@"
fi
mkdir -p "$STATE" "$NATIVE"

bounded() { "$BB" timeout -s TERM -k 2 25 "$@"; }
check() { echo "$1  $2" | sha256sum -c - >/dev/null; }
log() { echo "$*"; echo "$(date '+%m-%d %H:%M:%S') $*" >> "$STATE/radio.log"; }
file_size() { wc -c < "$1" 2>/dev/null | tr -d ' '; }

setstate() {
  echo "$1" > "$STATE/status"; echo "$1" > "$NATIVE/status"; log "RADIO_STATE=$1"
  case "$1" in
    ENTERING|XOS_READY) setprop sys.xos.exclusive 1 ;;
    STOCK_RESTORED) setprop sys.xos.exclusive 0 ;;
  esac
}

wifi_connected() { cmd wifi status 2>/dev/null | grep -q 'Wifi is connected to'; }

verify_files() {
  cd "$R"
  b=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo noboot)
  m=$(sha256sum installation.sha256 2>/dev/null | cut -d' ' -f1)
  # 同一 boot 内 manifest 未变时跳过 30~40MB 的全量哈希（节省 ~0.2-0.4s/次）
  if test -f "$STATE/verified.$b" && test "$(cat "$STATE/verified.$b" 2>/dev/null)" = "$m"; then
    test "$(uname -r)" = "$KERNEL"
    return
  fi
  sha256sum -c installation.sha256 >/dev/null
  grep -qx "$CANDIDATE  $CANDIDATE_REL" installation.sha256
  test -f "$CPATH"
  check "$CANDIDATE" "$CPATH"
  echo "$m" > "$STATE/verified.$b"
  test "$(uname -r)" = "$KERNEL"
}

stock_candidate_env() {
  test ! -e "$NATIVE/saved.env"
  test ! -e /sys/class/net/"$IFACE"
  test ! -e /sys/class/net/wondertap0
  ! grep -q " $AMSS " /proc/1/mountinfo
  # 原厂固件在一次开机内不会变；缓存校验结果，省掉每次 enter 的 7MB 哈希
  b=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo noboot)
  if test "$(cat "$STATE/stockamss.$b" 2>/dev/null)" = ok; then
    return 0
  fi
  check "$STOCK_AMSS_SHA" "$AMSS" || return 1
  echo ok > "$STATE/stockamss.$b"
}

load_idle_modules() {
  test -e "$W" || { log "stock driver not loaded"; return 1; }
  test -e "/sys/module/$BRIDGE" || { insmod "$R/$BRIDGE.ko" || { log "insmod bridge failed"; return 1; }; }
  test -e "/sys/module/$MINSTREL_MOD" || { insmod "$R/$MINSTREL_MOD.ko" || { log "insmod minstrel failed"; return 1; }; }
  test -e "/sys/module/$WONDER_MOD" || { insmod "$R/$WONDER_MOD.ko" synthetic_provider=1 || { log "insmod wonder failed"; return 1; }; }
  test -e "$MF" || { insmod "$R/$MHI_MOD.ko" || { log "insmod mhi_fw failed"; return 1; }; }
  test "$(cat /proc/sys/net/wonder/wonder_enable 2>/dev/null)" = 1
}

clean_routes() {
  for priority in 10980 10981 10982; do
    i=0
    while [ "$i" -lt 3 ] && ip -6 rule del priority "$priority" 2>/dev/null; do i=$((i + 1)); done
  done
  ip -6 route flush table "$ROUTE_TABLE" 2>/dev/null || true
}

routes() {
  clean_routes
  addr=$(ip -6 -o addr show dev "$IFACE" scope link 2>/dev/null | grep -vE 'tentative|dadfailed' | awk '$3=="inet6"{sub(/\/.*/, "", $4); print $4; exit}')
  case "$addr" in fe80:*) ;; *) return 1 ;; esac
  ip -6 route replace fe80::/64 dev "$IFACE" table "$ROUTE_TABLE"
  ip -6 route replace ff00::/8 dev "$IFACE" table "$ROUTE_TABLE"
  ip -6 rule add priority 10980 to fe80::/64 oif "$IFACE" uidrange 0-0 lookup "$ROUTE_TABLE"
  ip -6 rule add priority 10981 to ff00::/8 oif "$IFACE" uidrange 0-0 lookup "$ROUTE_TABLE"
  ip -6 rule add priority 10982 from "$addr/128" lookup "$ROUTE_TABLE"
}

runner_alive() {
  pid=$(cat "$STATE/runner.pid" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q "owly-xosd $IFACE "
}

clear_pt_peers() {
  ctl="$W/parameters/pt_remote_peer_ctl"
  test -e "$ctl" || return 0
  for i in 1 2 3 4 5; do
    # 每次最多 20 秒，总预算 110 秒，低于 bridge 的 120 秒命令超时
    "$BB" timeout -s TERM -k 2 20 sh -c 'echo clear > "$1"' sh "$ctl" 2>/dev/null || true
    summary=$(head -n 1 "$ctl" 2>/dev/null) || summary=unavailable
    case "$summary" in 'active=0 '*) log "pt peers cleared (try $i)"; return 0 ;; esac
    sleep 0.2
  done
  log "pt peer clear incomplete: $summary"
  return 1
}

stop_runner() {
  if runner_alive; then
    # 运行时开始关闭后会拒绝清空对端（ESHUTDOWN），所以先冻结再清
    if ! kill -STOP "$pid" 2>/dev/null; then
      log "could not pause owly runner $pid before clearing PT peers"
      return 1
    fi
  else
    pid=
  fi
  if ! clear_pt_peers; then
    if test -n "$pid"; then kill -CONT "$pid" 2>/dev/null || true; fi
    return 1
  fi
  if test -n "$pid"; then
    kill -TERM "$pid" 2>/dev/null || true
    kill -CONT "$pid" 2>/dev/null || true
    for i in $(seq 1 15); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
    kill -KILL "$pid" 2>/dev/null || true
    sleep 0.3
  fi
  rm -f "$STATE/runner.pid"
  for i in $(seq 1 15); do test -e "/sys/class/net/$IFACE" || break; sleep 0.2; done
  if test -e /sys/class/net/wonder0; then iw dev wonder0 del 2>/dev/null || true; fi
  clean_routes
}

restore_service() {
  if test "$(getprop "init.svc.$1")" != "$2"; then
    case "$2" in running) start "$1" ;; stopped) stop "$1" ;; *) return 1 ;; esac
  fi
  for i in $(seq 1 12); do test "$(getprop "init.svc.$1")" = "$2" && return 0; sleep 1; done
  return 1
}

restore_stock_settings() {
  echo "$saved_pci" > "$PCI" 2>/dev/null || true
  restore_service vendor.cnd "$saved_cnd" || true
  restore_service vendor.wifi_hal_legacy "$saved_hal" || true
  setprop sys.xos.exclusive 0
  if test "$saved_scan" = 1; then cmd wifi set-scan-always-available enabled; else cmd wifi set-scan-always-available disabled; fi
  # 不在这里等 Wi-Fi 关联完成：关联在后台进行，restore 立即返回，下一次 enter 更快
  if test "${saved_wifi:-1}" = 1; then cmd wifi set-wifi-enabled enabled; else cmd wifi set-wifi-enabled disabled; fi
}

snapshot() {
  test ! -e "$NATIVE/saved.env"
  case "$(getprop sys.xos.exclusive)" in ''|0) ;; *) return 1 ;; esac
  stock_candidate_env
  check "$STOCK_NOTE_SHA" "$W/notes/.note.gnu.build-id"
  wifi=$(settings get global wifi_on)
  scan=$(settings get global wifi_scan_always_enabled)
  cnd=$(getprop init.svc.vendor.cnd)
  hal=$(getprop init.svc.vendor.wifi_hal_legacy)
  pci=$(cat "$PCI")
  case "$wifi" in 0|1) ;; *) return 1 ;; esac
  case "$scan" in 0|1) ;; *) scan=0 ;; esac
  umask 077
  printf 'saved_wifi=%s\nsaved_scan=%s\nsaved_cnd=%s\nsaved_hal=%s\nsaved_pci=%s\nsaved_boot=%s\n' \
    "$wifi" "$scan" "$cnd" "$hal" "$pci" "$(cat /proc/sys/kernel/random/boot_id)" > "$STATE/snapshot.tmp"
  mv "$STATE/snapshot.tmp" "$NATIVE/saved.env"
}

# 原厂 cnss2/mhi 用首次开机时按原厂固件大小分配的 FBC 缓冲区；换更大的 S26U
# 固件会越界（内核 panic）。在芯片上电状态清 img_pre_alloc，下一次上电就会按
# 新固件重新分配（每次开机只需一次）。
mhi_prepare() {
  test -e "$MF" || insmod "$R/$MHI_MOD.ko" || { log "insmod mhi_fw failed"; return 1; }
  st=$(cat "$MF")
  case "$st" in pre_alloc=*) ;; *) log "mhi state unusable: $st"; return 1 ;; esac
  cap=$(echo "$st" | sed -n 's/.*fbc_capacity=\([0-9]*\).*/\1/p')
  sbl=$(echo "$st" | sed -n 's/.*sbl_size=\([0-9]*\).*/\1/p')
  need=$((CANDIDATE_SIZE - ${sbl:-0}))
  if test "${cap:-0}" -ge "$need"; then MHI_CLEARED=0; return 0; fi
  if ! ip link show wlan0 2>/dev/null | grep -q 'UP'; then
    log "FBC buffer too small and chip may be off: powering Wi-Fi up once to re-size it"
    cmd wifi set-wifi-enabled enabled
    for i in $(seq 1 30); do ip link show wlan0 2>/dev/null | grep -q 'UP' && break; sleep 0.5; done
    ip link show wlan0 2>/dev/null | grep -q 'UP' || return 1
    sleep 1
  fi
  echo 1 > "$MF"
  MHI_CLEARED=1
  log "mhi: img_pre_alloc cleared (capacity $cap < need $need)"
}

release_pt() {
  if test -e "$REL" && test -e "$W/parameters/pt_activate"; then
    for i in $(seq 1 15); do
      bounded sh -c "echo 1 > $REL" 2>/dev/null || true
      grep -qx 'armed=0 releasing=0 released=1 result=0' "$REL" && return 0
      sleep 0.2
    done
    log "pt_release failed: $(cat "$REL" 2>/dev/null || echo unreadable)"
    return 1
  fi
  return 0
}

unload_experimental() {
  if test -e "/sys/module/$WONDER_MOD"; then
    test -z "$(ls -A "/sys/module/$WONDER_MOD/holders" 2>/dev/null)" || return 1
    bounded rmmod "$WONDER_MOD" || return $?
  fi
  if test -e "$W/parameters/pt_activate"; then
    release_pt || return $?
    test "$(cat "$W/refcnt")" = 0 || return 1
    bounded rmmod "$DRIVER" || return $?
  fi
  if test -e "/sys/module/$BRIDGE"; then bounded rmmod "$BRIDGE" || return $?; fi
}

# 有限次重试的 umount，避免上游 while 死循环
unmount_candidate() {
  i=0
  while [ "$i" -lt 20 ] && grep -q " $AMSS " /proc/1/mountinfo 2>/dev/null; do
    umount "$AMSS" 2>/dev/null || break
    i=$((i + 1)); sleep 0.1
  done
  ! grep -q " $AMSS " /proc/1/mountinfo 2>/dev/null
}

restore() {
  if test ! -e "$NATIVE/saved.env"; then
    if test -e "$W/parameters/pt_activate"; then
      log "PT driver loaded without saved state; refusing to guess, reboot required"
      setstate RESTORE_FAILED
      return 1
    fi
    load_idle_modules || true
    setstate STOCK_RESTORED
    return 0
  fi
  . "$NATIVE/saved.env"
  setstate RESTORING
  if test "${saved_boot:-}" != "$(cat /proc/sys/kernel/random/boot_id)"; then
    # 会话期间重启过：运行时状态已随重启消失，只需要把 Wi-Fi 开关恢复
    clean_routes
    restore_stock_settings
    mv "$NATIVE/saved.env" "$STATE/previous-boot.env"
    load_idle_modules || true
    setstate STOCK_RESTORED
    return 0
  fi
  if ! stop_runner; then
    log "stop_runner failed, keeping session state for retry"
    setstate RESTORE_FAILED
    return 1
  fi
  if ! unload_experimental; then
    log "unload_experimental failed"
    setstate RESTORE_FAILED
    return 1
  fi
  if ! unmount_candidate; then
    log "could not unmount candidate firmware"
    setstate RESTORE_FAILED
    return 1
  fi
  if ! check "$STOCK_AMSS_SHA" "$AMSS"; then
    log "stock firmware hash mismatch after restore"
    setstate RESTORE_FAILED
    return 1
  fi
  if test ! -e "$W"; then
    bounded insmod "$STOCK" || { log "insmod stock driver failed"; setstate RESTORE_FAILED; return 1; }
  fi
  if ! check "$STOCK_NOTE_SHA" "$W/notes/.note.gnu.build-id"; then
    log "stock driver build-id mismatch after restore"
    setstate RESTORE_FAILED
    return 1
  fi
  restore_stock_settings
  mv "$NATIVE/saved.env" "$STATE/last-restored.env"
  setstate STOCK_RESTORED
  # 先把 STOCK_RESTORED 返回给调用方；Wi-Fi 关联由系统自动完成，idle 模块
  # 在后台加载（若用户马上重新打开 AirDrop，enter 会终止这次后台加载）。
  (
    i=0
    while test "$i" -lt 10; do
      test -e "$STATE/enter-active" && exit 0
      sleep 0.1
      i=$((i + 1))
    done
    test -e "$STATE/enter-active" && exit 0
    load_idle_modules || log "idle modules not reloaded"
  ) >>"$STATE/radio.log" 2>&1 &
  echo $! > "$STATE/idle-loading"
  return 0
}

start_xos() {
  rm -f "$STATE/runner.log"
  (
    for fd in 3 4 5 6 7 8 9; do eval "exec $fd>&-" 2>/dev/null || true; done
    # shellcheck disable=SC2086
    exec "$BB" setsid env \
      HOUJI_OWLY_OUTGOING_VHT="${PANDORA_OWLY_OUTGOING_VHT:-2}" \
      HOUJI_OWLY_ACCEPT_ADDBA="${PANDORA_OWLY_ACCEPT_ADDBA:-2}" \
      HOUJI_OWLY_TX_ADDBA="${PANDORA_OWLY_TX_ADDBA:-1}" \
      OWLY_COALESCE_US=1000 \
      "$R/owly-xosd" "$IFACE" $OWLY_MODE </dev/null >"$STATE/runner.log" 2>&1
  ) &
  echo $! > "$STATE/runner.pid"
  ready=0
  for i in $(seq 1 600); do
    if grep -q "^OWLY_READY iface=$IFACE " "$STATE/runner.log" 2>/dev/null && \
       ip -6 -o addr show dev "$IFACE" scope link 2>/dev/null | grep -vE 'tentative|dadfailed' | grep -q 'fe80:'; then
      ready=1; break
    fi
    runner_alive || break
    sleep 0.05
  done
  test "$ready" = 1 || { log "owly not ready"; return 1; }
  routes
  setstate XOS_READY
}

enter() {
  # 如果上一次 restore 的后台 idle 模块加载还没完成，直接终止它（不要等待），
  # 避免给「关掉页面立刻重开」额外增加 1~2 秒。
  if test -e "$STATE/idle-loading"; then
    ipid=$(cat "$STATE/idle-loading" 2>/dev/null || true)
    case "$ipid" in ''|*[!0-9]*) ;; *) kill -TERM "$ipid" 2>/dev/null || true ;; esac
    rm -f "$STATE/idle-loading"
    sleep 0.05
  fi
  if test -e "$NATIVE/saved.env"; then
    if ! grep -qx RESTORE_FAILED "$STATE/status" 2>/dev/null && \
       grep -q 'phase=3 error=0 closing=0' "$W/parameters/pt_activate" 2>/dev/null && runner_alive && \
       ip -6 -o addr show dev "$IFACE" scope link 2>/dev/null | grep -vE 'tentative|dadfailed' | grep -q 'fe80:'; then
      routes; setstate XOS_READY; return 0
    fi
    log "Unhealthy existing session; restoring first"
    restore || true
  fi
  echo $$ > "$STATE/enter-active"
  verify_files
  CANDIDATE_SIZE=$(file_size "$CPATH")
  test "${CANDIDATE_SIZE:-0}" -gt 1048576 || { log "candidate firmware too small"; return 1; }
  stock_candidate_env
  snapshot
  trap 'rc=$?; trap - EXIT; rm -f "$STATE/enter-active"; if test "$rc" != 0; then log "ENTER_FAILED=$rc"; restore || setstate RESTORE_FAILED; fi; exit "$rc"' EXIT
  setstate ENTERING
  MHI_CLEARED=0
  mhi_prepare
  copied=0
  if ! cmp -s "$CPATH" "$RADIO/amss20.bin" 2>/dev/null; then
    cp "$CPATH" "$RADIO/amss20.bin"
    copied=1
  fi
  chown system:system "$RADIO/amss20.bin"
  chmod 440 "$RADIO/amss20.bin"
  chcon u:object_r:firmware_file:s0 "$RADIO/amss20.bin"
  if test "$copied" = 1; then
    check "$CANDIDATE" "$RADIO/amss20.bin"
    sync
  else
    test -f "$RADIO/amss20.bin"
  fi

  # idle 的 synthetic wonder 必须先卸载，才能换 PT 驱动后重新绑定
  if test -e "/sys/module/$WONDER_MOD"; then bounded rmmod "$WONDER_MOD" || { log "rmmod wonder failed"; return 1; }; fi
  cmd wifi set-scan-always-available disabled >/dev/null 2>&1 || true
  cmd wifi set-wifi-enabled disabled >/dev/null 2>&1 || true
  for i in $(seq 1 80); do cmd wifi status 2>/dev/null | grep -q 'Wifi is disabled' && break; sleep 0.1; done
  stop vendor.cnd
  stop vendor.wifi_hal_legacy
  for i in $(seq 1 240); do
    test "$(getprop init.svc.vendor.cnd):$(getprop init.svc.vendor.wifi_hal_legacy)" = stopped:stopped && test "$(cat "$W/refcnt")" = 0 && break
    if test $((i % 20)) = 0; then stop vendor.wifi_hal_legacy; fi
    sleep 0.05
  done
  test "$(cat "$W/refcnt")" = 0 || { log "driver refcnt not zero"; return 1; }
  bounded rmmod "$DRIVER"
  if test "$MHI_CLEARED" = 1; then
    grep -q 'fbc_entries=0 ' "$MF" || { log "FBC buffer not freed: $(cat "$MF")"; return 1; }
  fi
  if test -e "/sys/module/$BRIDGE"; then bounded rmmod "$BRIDGE" || true; fi   # 每次会话用全新 broker

  mount --bind "$RADIO/amss20.bin" "$AMSS"
  check "$CANDIDATE" "$AMSS"
  insmod "$R/$BRIDGE.ko"
  echo on > "$PCI"
  # shellcheck disable=SC2086
  bounded insmod "$R/$DRIVER.ko" $PT_PARAMS
  # minstrel 与 PT 激活无关，提前加载，和固件 PT 启动时间重叠
  test -e "/sys/module/$MINSTREL_MOD" || insmod "$R/$MINSTREL_MOD.ko" || { log "insmod minstrel failed"; return 1; }
  activated=0
  for i in $(seq 1 200); do
    if sh -c "echo 1 > $W/parameters/pt_activate" 2>/dev/null && grep -q 'published=1' "$W/parameters/pt_activate"; then
      activated=1; break
    fi
    sleep 0.05
  done
  test "$activated" = 1 || { log "pt_activate not published"; return 1; }
  insmod "$R/$WONDER_MOD.ko" synthetic_provider=1
  phy=$(iw phy | awk '$0 == "Wiphy wonder" { found=1; next } found && $1 == "wiphy" && $2 == "index:" { print $3; exit }')
  case "$phy" in ''|*[!0-9]*) log "wonder phy not found"; return 1 ;; esac
  country=${XOS_COUNTRY:-CN}
  bounded "$R/wonder-init" create "$phy"
  bounded "$R/wonder-init" cache "$phy" "$(cat /sys/class/net/wonder0/ifindex)" "$PROFILE" "$country" "$AWDL_CHANNEL"
  ip link set dev wonder0 mtu 8192 2>/dev/null || true
  bounded ip link set dev wonder0 up
  iw dev wonder0 info | grep -q "channel $AWDL_CHANNEL " || bounded iw dev wonder0 set channel "$AWDL_CHANNEL" HT20
  iw dev wonder0 info | grep -q "channel $AWDL_CHANNEL " || { log "wonder0 channel set failed"; return 1; }
  freq=5745
  case "$AWDL_CHANNEL" in 149) freq=5745 ;; 44) freq=5220 ;; 6) freq=2437 ;; esac
  for i in $(seq 1 40); do grep -q "phase=3 error=0 closing=0 handle=1 freq=$freq " "$W/parameters/pt_activate" && break; sleep 0.05; done
  grep -q "phase=3 error=0 closing=0 handle=1 freq=$freq " "$W/parameters/pt_activate"
  start_xos
  rm -f "$STATE/enter-active"
  trap - EXIT
}

diag() {
  echo "profile=$PROFILE_ID kernel=$(uname -r) expected=$KERNEL"
  echo "driver=$DRIVER stock=$STOCK note_sha=$STOCK_NOTE_SHA"
  echo "amss=$AMSS stock_sha=$STOCK_AMSS_SHA"
  echo "candidate=$CPATH sha=$CANDIDATE size=$(file_size "$CPATH" 2>/dev/null)"
  echo "pci=$PCI bridge=$BRIDGE mhi=$MHI_MOD wonder=$WONDER_MOD channel=$AWDL_CHANNEL table=$ROUTE_TABLE"
  echo "state=$(cat "$STATE/status" 2>/dev/null || echo UNKNOWN)"
  echo "wonder_enable=$(cat /proc/sys/net/wonder/wonder_enable 2>/dev/null || echo missing)"
  cat "$W/parameters/pt_activate" 2>/dev/null || true
  cmd wifi status 2>/dev/null | head -2 || true
}

case "${1:-status}" in
  idle) load_idle_modules && echo IDLE_READY ;;
  enter) enter ;;
  restore) restore ;;
  status)
    cat "$STATE/status" 2>/dev/null || echo UNKNOWN
    echo "wonder_enable=$(cat /proc/sys/net/wonder/wonder_enable 2>/dev/null || echo missing)"
    cat "$W/parameters/pt_activate" 2>/dev/null || true
    cmd wifi status 2>/dev/null | head -2 || true ;;
  diag) diag ;;
  *) exit 2 ;;
esac
