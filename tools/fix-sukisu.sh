#!/system/bin/sh
# 清理导致 SukiSU 管理器崩溃的重复模块目录（haotian_dump）。
# 在 MT 管理器 / MT Termex 的 root 终端里执行：
#   su -c 'sh /sdcard/Download/fix-sukisu.sh'
# 或终端本来就是 root：sh /sdcard/Download/fix-sukisu.sh
echo "== id: $(id)"
echo "== before:"
ls -la /data/adb/modules 2>/dev/null | grep haotian
ls -la /data/adb/modules_update 2>/dev/null | grep haotian
rm -rf /data/adb/modules/haotian_dump
rm -rf /data/adb/modules_update/haotian_dump
rm -rf /data/adb/modules_update/.haotian_dump
echo "== after:"
ls -la /data/adb/modules 2>/dev/null | grep haotian || echo "  modules: clean"
ls -la /data/adb/modules_update 2>/dev/null | grep haotian || echo "  modules_update: clean"
echo "== done. Reboot the phone, then open SukiSU."
echo "== if rm says Permission denied, this terminal has no root; use a root file manager instead."
