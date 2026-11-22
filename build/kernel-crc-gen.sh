#!/bin/bash
# 从 ACK 内核树为指定导出符号生成 classic-genksyms CRC，并追加到 $KOUT/Module.symvers
# 用法: kernel-crc-gen.sh <symbol> [<symbol> ...]
# 原理: CONFIG_MODVERSIONS 下 Kbuild 会把 genksyms 结果以 `#SYMVER <sym> 0x<crc>`
#       写进每个对象的 .cmd 文件；编该符号所在 .c 的 .o 即可拿到与手机一致的 CRC。
# 已验证: kstrtouint 0x3b6c41ea 与手机原厂模块导入的 CRC 完全一致。
set -u
TREE=${TREE:-/root/haotian-build/kernel}
KOUT=${KOUT:-/root/haotian-build/kernel-out}
SYMVERS="$KOUT/Module.symvers"
EXTRA="$KOUT/kernel-extra.symvers"

have_sym() { grep -qE "^[0-9a-fx]+\t$1\t" "$SYMVERS" 2>/dev/null; }

append_sym() { # <crc> <sym>
  printf '%s\t%s\tvmlinux\tEXPORT_SYMBOL\t\n' "$1" "$2" >> "$EXTRA"
  grep -qE "^[0-9a-fx]+\t$2\t" "$SYMVERS" || \
    printf '%s\t%s\tvmlinux\tEXPORT_SYMBOL\t\n' "$1" "$2" >> "$SYMVERS"
  echo "  + $2 = $1"
}

build_and_read() { # <rel source path> <sym>  -> 0 if found
  local rel="$1" sym="$2" obj dir base cmd crc
  case "$rel" in *.c) obj="${rel%.c}.o" ;; *.S) obj="${rel%.S}.o" ;; *) return 1 ;; esac
  dir=$(dirname "$rel"); base=$(basename "$rel"); base="${base%.*}"
  make -C "$TREE" O="$KOUT" ARCH=arm64 LLVM=1 "$obj" >/dev/null 2>&1
  cmd="$KOUT/$dir/.$base.o.cmd"
  [ "$dir" = "." ] && cmd="$KOUT/.$base.o.cmd"
  crc=$(grep -m1 "^#SYMVER $sym " "$cmd" 2>/dev/null | awk '{print $3}')
  [ -n "$crc" ] || return 1
  append_sym "$crc" "$sym"
  return 0
}

gen_one() { # <sym>
  local sym="$1" hits src hdr inc rel
  if have_sym "$sym"; then echo "  = $sym (already)"; return 0; fi
  # 1) 直接在 .c / .S 里找 EXPORT_SYMBOL
  hits=$(grep -rlE --include='*.c' "EXPORT_SYMBOL[A-Z_]*[[:space:]]*\([[:space:]]*$sym([[:space:]]*[,)]|$)" "$TREE" 2>/dev/null | head -n 4)
  if [ -z "$hits" ]; then
    hits=$(grep -rlE --include='*.S' "EXPORT_SYMBOL[A-Z_]*[[:space:]]*\([[:space:]]*$sym([[:space:]]*[,)]|$)" "$TREE" 2>/dev/null | head -n 2)
  fi
  # 2) 导出写在头文件里（如 kernel/rcu/tree_plugin.h）→ 找包含该头文件的 .c
  if [ -z "$hits" ]; then
    for hdr in $(grep -rlE --include='*.h' "EXPORT_SYMBOL[A-Z_]*[[:space:]]*\([[:space:]]*$sym([[:space:]]*[,)]|$)" "$TREE" 2>/dev/null | head -n 3); do
      inc=$(basename "$hdr")
      hits="$hits $(grep -rlE --include='*.c' "#[[:space:]]*include[[:space:]]*[\"<].*$inc[\">]" "$TREE" 2>/dev/null | head -n 2)"
    done
  fi
  if [ -z "$(echo "$hits" | tr -d ' ')" ]; then echo "  ! $sym: no EXPORT_SYMBOL source found"; return 1; fi
  for src in $hits; do
    rel=${src#$TREE/}
    echo "  * $sym <- $rel"
    build_and_read "$rel" "$sym" && return 0
  done
  echo "  ! $sym: built but no #SYMVER found"; return 1
}

: >> "$EXTRA"
fail=0
for s in "$@"; do gen_one "$s" || fail=1; done
echo "kernel-extra.symvers: $(wc -l < "$EXTRA") entries; failures=$fail"
exit $fail
