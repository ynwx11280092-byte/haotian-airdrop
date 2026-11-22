#!/usr/bin/env bash
# ============================================================================
# haotian-airdrop 内核模块构建脚本（在 Linux 上运行）
#
# 目标：为小米 15 Pro (haotian) 内核
#       6.6.118-android15-8-gf72a02f47f4b-abogki551678766-4k
# 构建 4 个可 insmod 的模块：
#   qca_cld3_peach_v2.ko  wonder.ko  xos_wonder_bridge.ko  xos_mhi_fw.ko
#
# ⚠ 这不是"一键必然成功"的脚本：驱动补丁需要从 pandora(6.12) 重新移植到
#    haotian(6.6) 的 WLAN 源码树，且必须在拿到手机真实 .config 后再编译。
#    脚本把整个过程拆成可检查的步骤，任何一步失败都会明确停下。
#
# 用法：
#   ./build/build-modules.sh --work /path/to/work --config /path/to/phone.config
#   ./build/build-modules.sh --help
#
# 前置条件：
#   * Linux x86_64，≥ 8 GB RAM / 40 GB 磁盘；git/curl/tar
#   * clang + LLVM (AOSP prebuilt 或系统 clang-17+)、make、bc、flex、bison、
#     python3、perl、cpio、rsync、lz4、libssl-dev、libelf-dev、dwarves(pahole)
#   * 手机 root 权限（用于导出 .config、cnss2.ko、原厂 WLAN 驱动）
# ============================================================================
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
WORK=${WORK:-$HOME/haotian-airdrop-build}
JOBS=${JOBS:-$(nproc)}
KERNEL_VER="6.6.118-android15-8-gf72a02f47f4b-abogki551678766-4k"
KERNEL_BRANCH=${KERNEL_BRANCH:-dada-v-oss}   # Xiaomi 侧 vendor 配置来源（6.6.30，较旧）
WLAN_BRANCH=${WLAN_BRANCH:-dada-v-oss}   # 含 haotian-peach-cnss-v8.dts / sun_gki_peach-v2_defconfig
MIRRORS=("https://gh-proxy.com/" "https://ghfast.top/" "")
OUT=$ROOT/build/out

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
  echo
  echo "参数："
  echo "  --work DIR       构建目录（默认 $WORK）"
  echo "  --config FILE    手机内核 .config / config.gz（必填，见 BUILD-MODULES.md §1）"
  echo "  --kernel-src DIR 已解压的小米内核源码（缺省自动下载 $KERNEL_BRANCH）"
  echo "  --wlan-src DIR   已解压的 WLAN 源码（缺省自动下载 $WLAN_BRANCH）"
  echo "  --toolchain DIR  clang 目录（缺省使用 PATH 里的 clang）"
  echo "  --out DIR        输出目录（默认 $OUT）"
  echo "  --print-config   只打印需要导出到手机的信息，不编译"
  exit 0
}

CONFIG=
KERNEL_SRC=
WLAN_SRC=
TOOLCHAIN=
PRINT_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --work) WORK=$2; shift 2 ;;
    --config) CONFIG=$2; shift 2 ;;
    --kernel-src) KERNEL_SRC=$2; shift 2 ;;
    --wlan-src) WLAN_SRC=$2; shift 2 ;;
    --toolchain) TOOLCHAIN=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --print-config) PRINT_ONLY=1; shift ;;
    -h|--help) usage ;;
    *) echo "未知参数: $1"; exit 2 ;;
  esac
done
mkdir -p "$WORK" "$OUT/kernel-modules" "$OUT/runtime" "$OUT/compat"

step() { echo; echo "==== [$1] $2"; }
die() { echo "❌ $*" >&2; exit 1; }

# ---- 0. 前置检查 -----------------------------------------------------------
step 0 "依赖检查"
for c in make clang ld.lld python3 perl bc flex bison cpio rsync lz4 git curl tar; do
  command -v "$c" >/dev/null || echo "! 缺少命令: $c"
done
command -v make >/dev/null || die "安装 make 后重试"
command -v clang >/dev/null || die "安装 clang / 指定 --toolchain 后重试"
echo "OK（缺 pahole/dwarves 时 GENDWARFKSYMS 可能失败，见 BUILD-MODULES.md）"

step 0b "目标内核与设备信息"
cat <<EOF
手机内核 release : $KERNEL_VER
内核源码分支     : MiCode/Xiaomi_Kernel_OpenSource  $KERNEL_BRANCH（建议替换为 ACK android15-6.6-2026-01 作为基座）
WLAN 源码分支    : MiCode/vendor_qcom_opensource_wlan  $WLAN_BRANCH
构建目录         : $WORK
输出目录         : $OUT
EOF
[ "$PRINT_ONLY" = 1 ] && exit 0

# ---- 1. 内核 .config -------------------------------------------------------
# 必须用手机真实 .config：本机内核没有 CONFIG_GENDWARFKSYMS，CRC 由经典 genksyms
# 按「同源码 + 同 .config」计算；配置不同 CRC 就对不上。
step 1 "准备内核 .config"
if [ -z "$CONFIG" ] && [ -f "$ROOT/build/phone/config.gz" ]; then
  CONFIG=$ROOT/build/phone/config.gz
  echo "  使用已采集的 $CONFIG（2026-11-22 haotian 实机 /proc/config.gz）"
fi
[ -n "$CONFIG" ] || die "必须用 --config 指定手机内核 .config（获取方法见 BUILD-MODULES.md §1）
    adb exec-out su -c 'cat /proc/config.gz' > phone.config.gz
    zcat phone.config.gz > phone.config"
if [ ! -f "$CONFIG" ]; then die "找不到 $CONFIG"; fi
case "$CONFIG" in
  *.gz) zcat "$CONFIG" > "$WORK/phone.config" ;;
  *) cp "$CONFIG" "$WORK/phone.config" ;;
esac
grep -q '^CONFIG_LOCALVERSION=' "$WORK/phone.config" || echo "! .config 里没有 CONFIG_LOCALVERSION，将用 LOCALVERSION=-4k 覆盖"
echo "  配置校验: $(grep -c '^CONFIG_MODVERSIONS=y' "$WORK/phone.config") MODVERSIONS, $(grep -c '^CONFIG_GENDWARFKSYMS=y' "$WORK/phone.config") GENDWARFKSYMS (haotian 应为 1/0)"

# ---- 2. 下载源码 -----------------------------------------------------------
download_gh() { # <owner/repo> <branch> <out.tar.gz>
  local repo=$1 branch=$2 out=$3 url
  for m in "${MIRRORS[@]}"; do
    url="${m}https://codeload.github.com/$repo/tar.gz/refs/heads/$branch"
    echo "  下载 $url"
    if curl -fL --retry 2 --connect-timeout 20 -o "$out" "$url" 2>/dev/null && tar tzf "$out" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

step 2 "准备内核与 WLAN 源码"
if [ -z "$KERNEL_SRC" ]; then
  [ -f "$WORK/kernel.tar.gz" ] || download_gh "MiCode/Xiaomi_Kernel_OpenSource" "$KERNEL_BRANCH" "$WORK/kernel.tar.gz" \
    || die "内核源码下载失败：请手动下载 MiCode/Xiaomi_Kernel_OpenSource 分支 $KERNEL_BRANCH 并解压后 --kernel-src 指定"
  KERNEL_SRC=$WORK/kernel-src
  [ -d "$KERNEL_SRC" ] || { mkdir -p "$KERNEL_SRC" && tar xzf "$WORK/kernel.tar.gz" -C "$KERNEL_SRC" --strip-components=1; }
fi
make -s -C "$KERNEL_SRC" kernelversion >/dev/null 2>&1 || die "$KERNEL_SRC 不是有效的内核源码树"
echo "  内核源码: $KERNEL_SRC ($(make -s -C "$KERNEL_SRC" kernelversion))"

if [ -z "$WLAN_SRC" ]; then
  [ -f "$WORK/wlan.tar.gz" ] || download_gh "MiCode/vendor_qcom_opensource_wlan" "$WLAN_BRANCH" "$WORK/wlan.tar.gz" \
    || die "WLAN 源码下载失败：请手动下载 MiCode/vendor_qcom_opensource_wlan 分支 $WLAN_BRANCH 并解压后 --wlan-src 指定"
  WLAN_SRC=$WORK/wlan-src
  [ -d "$WLAN_SRC" ] || { mkdir -p "$WLAN_SRC" && tar xzf "$WORK/wlan.tar.gz" -C "$WLAN_SRC" --strip-components=1; }
fi
echo "  WLAN 源码: $WLAN_SRC"

# ---- 3. 驱动补丁（需要人工移植） ------------------------------------------
step 3 "应用 WLAN 驱动补丁"
echo "  上游 driver/patches/ 是 pandora(6.12) 的三方合并补丁，不能直接 git am 到 6.6 树。"
echo "  需要按 BUILD-MODULES.md §3 用 driver/port-scripts/ 重新移植到 $WLAN_SRC。"
if [ -d "$ROOT/build/patches-haotian" ] && ls "$ROOT/build/patches-haotian"/*.patch >/dev/null 2>&1; then
  for p in "$ROOT/build/patches-haotian"/*.patch; do
    echo "  git apply $(basename "$p")"
    ( cd "$WLAN_SRC" && git apply --check "$p" && git apply "$p" ) || die "补丁 $(basename "$p") 无法直接应用，需要手工解决冲突"
  done
else
  echo "! 没有 build/patches-haotian/*.patch。可以先跳过驱动编译，先构建 3 个辅助模块验证内核工具链；"
  echo "  或完成移植后把补丁放进 build/patches-haotian/ 再运行本脚本。"
  SKIP_DRIVER=1
fi

# ---- 4. 编译内核（生成与手机一致的 Module.symvers） -----------------------
step 4 "编译内核树（生成 Module.symvers；这一步最慢，1~4 小时）"
KOUT=$WORK/kernel-out
mkdir -p "$KOUT"
cp "$WORK/phone.config" "$KOUT/.config"
if [ -n "$TOOLCHAIN" ]; then
  export PATH="$TOOLCHAIN/bin:$PATH"
  CC="$TOOLCHAIN/bin/clang"
else
  CC=clang
fi
# 注意：haotian 的 6.6.118 内核没有 CONFIG_GENDWARFKSYMS（经典 genksyms），
# 不需要 KBUILD_GENDWARFKSYMS_STABLE；CRC 由源码 + 手机同款 .config 决定。
export LOCALVERSION=-4k
# shellcheck disable=SC2086
make -C "$KERNEL_SRC" O="$KOUT" ARCH=arm64 CC="$CC" LLVM=1 \
  HOSTCC=gcc HOSTCXX=g++ \
  olddefconfig
# shellcheck disable=SC2086
make -C "$KERNEL_SRC" O="$KOUT" ARCH=arm64 CC="$CC" LLVM=1 \
  HOSTCC=gcc HOSTCXX=g++ \
  -j"$JOBS" Image modules 2>&1 | tee "$WORK/kernel-build.log"
[ -f "$KOUT/Module.symvers" ] || die "内核编译没有产出 Module.symvers"
echo "  Module.symvers: $(wc -l < "$KOUT/Module.symvers") 行"

# 合并实机提取的厂商符号 CRC（cnss2/mhi 导出的符号；内核树 Module.symvers 里没有）
VENDOR_SYM="$ROOT/driver/haotian-phone-data/vendor.symvers"
if [ -f "$VENDOR_SYM" ]; then
  echo "  合并 vendor.symvers（实机 cnss2/mhi 导出符号 CRC）"
  awk -F'\t' 'NR==FNR{seen[$2]=1; print; next} !seen[$2]' \
    "$KOUT/Module.symvers" "$VENDOR_SYM" > "$KOUT/Module.symvers.merged"
  cp "$KOUT/Module.symvers" "$KOUT/Module.symvers.kernelonly"
  mv "$KOUT/Module.symvers.merged" "$KOUT/Module.symvers"
  echo "  合并后 Module.symvers: $(wc -l < "$KOUT/Module.symvers") 行"
else
  echo "! 未找到 $VENDOR_SYM：驱动可能因 cnss2 等厂商符号 undefined 而链接失败（见 BUILD-MODULES.md §4）"
fi

# ---- 5. 编译 wonder / xos_wonder_bridge / xos_mhi_fw ----------------------
step 5 "编译 wonder / xos_wonder_bridge / xos_mhi_fw"
KHEADERS="$KOUT"
build_ext() { # <src dir> <name>
  local src=$1 name=$2
  echo "  -> $name"
  make -C "$KERNEL_SRC" O="$KHEADERS" ARCH=arm64 CC="$CC" LLVM=1 M="$src" \
    modules \
    || die "编译 $name 失败（6.6 与源码所用内核 API 不一致时需要按 PORTING.md 修）"
  cp "$src/$name.ko" "$OUT/kernel-modules/$name.ko"
}
build_ext "$ROOT/driver/wonder" wonder
build_ext "$ROOT/driver/bridge" xos_wonder_bridge
build_ext "$ROOT/driver/mhi_fw" xos_mhi_fw

# ---- 6. 编译 PT WLAN 驱动 --------------------------------------------------
step 6 "编译 qca_cld3_peach_v2.ko"
if [ "${SKIP_DRIVER:-0}" = 1 ]; then
  echo "! 跳过（补丁未移植）。qca_cld3_peach_v2.ko 是核心，缺它不能工作。"
else
  # 混合构建：vendor 模块需要 vendor 头文件/defines 和 phone 侧符号 CRC。
  # 详细步骤见 BUILD-MODULES.md §4；这里执行最小验证：
  echo "  TODO: 按 BUILD-MODULES.md §4 生成 vendor_defines.h 与 vendor.symvers 后："
  echo "    make -C $WLAN_SRC M=... -j$JOBS ..."
  echo "  然后把产物拷到 $OUT/kernel-modules/qca_cld3_peach_v2.ko"
  [ -f "$OUT/kernel-modules/qca_cld3_peach_v2.ko" ] || echo "  （当前缺少该模块，打包器会拒绝生成可刷包）"
fi

# ---- 7. 校验/打包 ----------------------------------------------------------
step 7 "校验模块 vermagic"
if command -v node >/dev/null; then
  node "$ROOT/tools/verify-modules.mjs" --inputs "$OUT/kernel-modules" --profile haotian || true
else
  echo "  无 node，跳过自动校验；可直接 grep -a vermagic= 检查 $OUT/kernel-modules/*.ko"
fi
echo
echo "完成。把 4 个 .ko 放进 build/out/kernel-modules/，运行时二进制放进 build/out/runtime/，"
echo "兼容 APK 放进 build/out/compat/，然后："
echo "  node tools/package.mjs --inputs build/out"
