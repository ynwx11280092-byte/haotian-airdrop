#!/bin/bash
# 迭代编译辅助模块：modpost 报 undefined 的内核符号 → 从 ACK 树生成 CRC → 重编
# 用法: wsl-iter-build.sh [bridge] [mhi_fw] [wonder] ...
set -u
PROJ=${PROJ:-/mnt/c/Users/Administrator/Documents/deepseek-harness/default-workspace/haotian-airdrop}
KOUT=/root/haotian-build/kernel-out
KERNEL=/root/haotian-build/kernel
BASE="$PROJ/build/phone/Module.symvers"
EXTRA="$KOUT/kernel-extra.symvers"
OUT="$PROJ/build/out/kernel-modules"
mkdir -p "$OUT"
MAX_ROUNDS=${MAX_ROUNDS:-12}
touch "$EXTRA"

declare -A DIRS=( [bridge]="$PROJ/driver/bridge" [wonder]="$PROJ/driver/wonder" [mhi_fw]="$PROJ/driver/mhi_fw" )
declare -A NAMES=( [bridge]=xos_wonder_bridge [wonder]=wonder [mhi_fw]=xos_mhi_fw )
TARGETS=${*:-bridge mhi_fw wonder}

merge_symvers() {
  # 只合并 phone 基础表 + 内核生成表；bridge 的导出通过 KBUILD_EXTRA_SYMBOLS 传入，
  # 否则 modpost 会把同一批导出符号算两次（exported twice）。
  cat "$BASE" "$EXTRA" | awk -F'\t' '!seen[$2]++' > "$KOUT/Module.symvers"
}

errfile=$(mktemp)
for round in $(seq 1 "$MAX_ROUNDS"); do
  merge_symvers
  missing=""
  allok=1
  for t in $TARGETS; do
    src="${DIRS[$t]}"; name="${NAMES[$t]}"
    extra=""
    [ "$t" = "wonder" ] && [ -f "$PROJ/driver/bridge/Module.symvers" ] && extra="$PROJ/driver/bridge/Module.symvers"
    cfg=""
    # wonder 的 Kbuild 用 obj-$(CONFIG_WONDER_SUPPORT)，必须在命令行覆盖
    [ "$t" = "wonder" ] && cfg="CONFIG_WONDER_SUPPORT=m CONFIG_DEBUG_FS=y"
    echo "== [$round] build $name (symvers $(wc -l < "$KOUT/Module.symvers"))"
    ( cd "$src" && make -C "$KERNEL" O="$KOUT" ARCH=arm64 LLVM=1 M="$src" \
        $cfg ${extra:+KBUILD_EXTRA_SYMBOLS="$extra"} modules ) > "$errfile" 2>&1
    if [ -f "$src/$name.ko" ]; then
      cp "$src/$name.ko" "$OUT/$name.ko"
      echo "   OK $name.ko"
      continue
    fi
    allok=0
    grep -E 'ERROR: modpost' "$errfile" | head -n 12 | sed 's/^/   /'
    if grep -qE 'error:' "$errfile"; then
      echo "   -- compile errors (tail):"
      tail -n 25 "$errfile" | sed 's/^/   /'
      echo "   -- stop (需要改代码适配 6.6 API)"
      exit 1
    fi
    syms=$(grep -oE '"[A-Za-z_][A-Za-z0-9_]*" \[[^]]*\] undefined!' "$errfile" | sed 's/"\([^"]*\)".*/\1/' | sort -u)
    for s in $syms; do missing="$missing $s"; done
  done
  missing=$(echo "$missing" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')
  if [ "$allok" = 1 ]; then echo "ALL MODULES OK"; break; fi
  if [ -z "$missing" ]; then
    echo "no undefined kernel symbols parsed; stop"; break
  fi
  echo "== [$round] generate kernel CRCs for: $missing"
  before=$(wc -l < "$EXTRA")
  bash "$PROJ/build/kernel-crc-gen.sh" $missing || true
  after=$(wc -l < "$EXTRA")
  if [ "$after" = "$before" ]; then echo "== no new CRCs generated; stop"; break; fi
done

merge_symvers
echo "== final:"
ls -l "$OUT" 2>/dev/null
