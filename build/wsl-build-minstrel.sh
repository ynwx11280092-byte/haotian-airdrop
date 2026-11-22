#!/bin/bash
# 构建独立的 rc80211_minstrel_ht.ko（原厂 mac80211.ko 没有内置 RC 算法时使用）
#
# 前置：已按 build/wsl-build.sh 准备好 kernel / kernel-out / 手机 CRC 表。
# 用法：bash build/wsl-build-minstrel.sh
set -u
PROJ=${PROJ:-/mnt/c/Users/Administrator/Documents/deepseek-harness/default-workspace/haotian-airdrop}
KERNEL=${KERNEL:-/root/haotian-build/kernel}
KOUT=${KOUT:-/root/haotian-build/kernel-out}
SRC="$PROJ/driver/rc80211"

cd "$SRC" || exit 1
# 只保留源文件：Makefile 每次都重新生成，避免绝对路径残留
make -C "$KERNEL" O="$KOUT" ARCH=arm64 LLVM=1 M="$SRC" \
  KBUILD_EXTRA_SYMBOLS="$SRC/mac80211.symvers" modules 2>&1 | tail -20

mkdir -p "$PROJ/build/out/kernel-modules"
cp -f "$SRC/rc80211_minstrel_ht.ko" "$PROJ/build/out/kernel-modules/rc80211_minstrel_ht.ko"
chmod 644 "$PROJ/build/out/kernel-modules/rc80211_minstrel_ht.ko"
modinfo "$PROJ/build/out/kernel-modules/rc80211_minstrel_ht.ko" 2>/dev/null | grep -E 'vermagic|depends|name'
ls -l "$PROJ/build/out/kernel-modules/rc80211_minstrel_ht.ko"
