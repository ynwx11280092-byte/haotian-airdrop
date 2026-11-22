#!/usr/bin/env bash
# ============================================================================
# WSL2 内构建（Haotian 4 个内核模块，6.6.118）
#
# 前提：Windows 已装好 WSL2 + Ubuntu 24.04，且已跑过 C:\wsl\setup-inner.sh 装好依赖。
# 用法（WSL root）：
#   bash /mnt/c/Users/Administrator/Documents/deepseek-harness/default-workspace/haotian-airdrop/build/wsl-build.sh
#
# 设计（省内存/省时间）：
#   * 内核树：清华 AOSP 镜像的 ACK android15-6.6-2026-01（6.6.118），--depth 1；
#   * WLAN 源码：MiCode dada-v-oss（GitHub 直连，失败再走代理）；
#   * 内核只 configure + modules_prepare，不做全量 Image 编译；
#   * Module.symvers 用手机原厂模块提取的 CRC 表（build/phone/Module.symvers），
#     + 本机构建的 bridge 导出符号 → 可以编 wonder / bridge / mhi。
# ============================================================================
set -uo pipefail

PROJ=${PROJ:-/mnt/c/Users/Administrator/Documents/deepseek-harness/default-workspace/haotian-airdrop}
WORK=${WORK:-$HOME/haotian-build}
KERNEL_TAG=${KERNEL_TAG:-android15-6.6-2026-01_r1}
TSUNA=${TSUNA:-https://mirrors.tuna.tsinghua.edu.cn/git/AOSP}
LOG=$WORK/build.log

mkdir -p "$WORK"
cd "$WORK"
: > "$LOG"

step() { echo; echo "==== [$1] $2" | tee -a "$LOG"; }
runlog() { "$@" 2>&1 | tee -a "$LOG"; }

# ---- 1. 内核树 -------------------------------------------------------------
step 1 "clone ACK kernel ($KERNEL_TAG)"
if [ ! -d kernel/.git ]; then
  rm -rf kernel
  git clone --depth 1 --branch "$KERNEL_TAG" "$TSUNA/kernel/common" kernel 2>&1 | tee -a "$LOG"
  [ -d kernel/.git ] || { echo "clone 失败；可改用 KERNEL_TAG=android15-6.6-2026-01 或手动放源码"; exit 1; }
fi
echo "kernelversion=$(make -s -C kernel kernelversion 2>/dev/null)" | tee -a "$LOG"

# ---- 2. WLAN 源码 ----------------------------------------------------------
step 2 "download WLAN source (MiCode dada-v-oss)"
if [ ! -d wlan ]; then
  ok=0
  # 直连优先（本机实测 GitHub 直连 10MB/s+），失败再走代理
  for m in "" "https://gh-proxy.com/" "https://ghfast.top/"; do
    url="${m}https://codeload.github.com/MiCode/vendor_qcom_opensource_wlan/tar.gz/refs/heads/dada-v-oss"
    echo "  try $url" | tee -a "$LOG"
    if curl -fL --retry 2 --connect-timeout 20 -o wlan.tar.gz "$url" && tar tzf wlan.tar.gz >/dev/null 2>&1; then ok=1; break; fi
  done
  [ "$ok" = 1 ] || { echo "WLAN 下载失败"; exit 1; }
  mkdir -p wlan && tar xzf wlan.tar.gz -C wlan --strip-components=1
fi
echo "wlan files: $(find wlan -type f | wc -l)" | tee -a "$LOG"

# ---- 3. 内核配置 + modules_prepare ----------------------------------------
step 3 "configure kernel with phone .config + modules_prepare"
KOUT=$WORK/kernel-out
mkdir -p "$KOUT"
gzip -dc "$PROJ/build/phone/config.gz" > "$KOUT/.config"
(
  cd kernel
  make O="$KOUT" ARCH=arm64 LLVM=1 olddefconfig
  make -j"$(nproc)" O="$KOUT" ARCH=arm64 LLVM=1 modules_prepare
) >>"$LOG" 2>&1 || { echo "modules_prepare 失败，见 $LOG"; tail -n 40 "$LOG"; exit 1; }
echo "modules_prepare done" | tee -a "$LOG"

# ---- 4. Module.symvers（手机 CRC + 本机 bridge 导出） ----------------------
step 4 "install phone Module.symvers"
cp "$PROJ/build/phone/Module.symvers" "$KOUT/Module.symvers"
echo "  $(wc -l < "$KOUT/Module.symvers") symbols" | tee -a "$LOG"

# ---- 5. 编译模块（bridge 先，wonder 依赖 bridge 的导出符号） --------------
step 5 "build xos_wonder_bridge / wonder / xos_mhi_fw"
OUT="$PROJ/build/out/kernel-modules"
mkdir -p "$OUT"

build_ext() { # <src dir> <module name> [extra symvers]
  local src="$1" name="$2" extra="${3:-}"
  echo "-- build $name" | tee -a "$LOG"
  ( cd "$src" && make -C "$WORK/kernel" O="$KOUT" ARCH=arm64 LLVM=1 \
      M="$src" ${extra:+KBUILD_EXTRA_SYMBOLS="$extra"} modules ) >>"$LOG" 2>&1
  if [ -f "$src/$name.ko" ]; then
    cp "$src/$name.ko" "$OUT/$name.ko"
    echo "   OK $name.ko" | tee -a "$LOG"
  else
    echo "   FAILED $name (tail):" | tee -a "$LOG"; tail -n 30 "$LOG"
    return 1
  fi
}

build_ext "$PROJ/driver/bridge" xos_wonder_bridge || true
BRIDGE_SYM=$PROJ/driver/bridge/Module.symvers
[ -f "$BRIDGE_SYM" ] || BRIDGE_SYM=$KOUT/Module.symvers

build_ext "$PROJ/driver/wonder" wonder "$BRIDGE_SYM" || true
build_ext "$PROJ/driver/mhi_fw" xos_mhi_fw || true

# 把 bridge 的导出符号并入 kernel symvers，供后面 WLAN 驱动使用
if [ -f "$PROJ/driver/bridge/Module.symvers" ]; then
  awk -F'\t' 'NR==FNR{seen[$2]=1;print;next} !seen[$2]' \
    "$KOUT/Module.symvers" "$PROJ/driver/bridge/Module.symvers" > "$KOUT/Module.symvers.merged"
  mv "$KOUT/Module.symvers.merged" "$KOUT/Module.symvers"
fi

# ---- 6. 汇总 --------------------------------------------------------------
step 6 "result"
ls -l "$OUT" | tee -a "$LOG"
echo "build log: $LOG"
