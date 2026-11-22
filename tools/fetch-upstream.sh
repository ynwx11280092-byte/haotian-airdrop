#!/usr/bin/env bash
# ============================================================================
# 获取上游 pandora-airdrop v1.0.0 release 的运行时二进制（Linux 版）
#   owly-xosd / wonder-init / xos-bridge.zip
# 用法：bash tools/fetch-upstream.sh [dest]
# ============================================================================
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEST=${1:-$ROOT/upstream}
URL=https://github.com/AdenXie/pandora-airdrop/releases/download/v1.0.0/pandora-airdrop-v1.0.0.zip
SHA=dfa2d81829ebca155fa768721e73a18d44a59cb0f9c0918edd8e6549ad65fe39
mkdir -p "$DEST"
ZIP=$DEST/pandora-airdrop-v1.0.0.zip

sha() { sha256sum "$1" | awk '{print $1}'; }

if [ ! -f "$ZIP" ] || [ "$(sha "$ZIP")" != "$SHA" ]; then
  ok=0
  for m in "" "https://gh-proxy.com/" "https://ghfast.top/"; do
    echo "下载: ${m}${URL}"
    if curl -fL --retry 2 --connect-timeout 20 -o "$ZIP" "${m}${URL}" 2>/dev/null && [ "$(sha "$ZIP")" = "$SHA" ]; then ok=1; break; fi
  done
  [ "$ok" = 1 ] || { echo "下载失败：请手动从上游 release 下载并解压后，把 payload/ 里的 3 个文件放到 $DEST" >&2; exit 1; }
fi
echo "SHA-256 校验通过: $SHA"
tmp=$DEST/_extract
rm -rf "$tmp"; mkdir -p "$tmp"
tar -xf "$ZIP" -C "$tmp" 2>/dev/null || { command -v unzip >/dev/null && unzip -q "$ZIP" -d "$tmp"; }
for f in owly-xosd wonder-init xos-bridge.zip; do
  cp "$(find "$tmp" -name "$f" -type f | head -n 1)" "$DEST/$f"
  echo "  -> $f sha256=$(sha "$DEST/$f")"
done
rm -rf "$tmp"
echo "完成：$DEST"
