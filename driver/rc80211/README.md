# rc80211_minstrel_ht.ko（独立 RC 算法模块）

## 为什么需要它

小米 15 Pro 原厂 `mac80211.ko` 编译时 `CONFIG_MAC80211_RC_MINSTREL=n`，
内核里**没有任何速率控制算法**。wonder（mac80211 虚拟驱动）注册 wiphy 时
`ieee80211_register_hw()` 会因 "Failed to select rate control algorithm" 返回 -ENOENT。

本目录把 Linux 6.6 的 `rc80211_minstrel_ht.c` 编成**独立内核模块**，
并在 `rc80211_compat.c` 里补上 mac80211 内置但未导出的 `ieee80211_frame_duration`。
加载顺序：`xos_wonder_bridge → rc80211_minstrel_ht → wonder`。

## 文件来源

- `minstrel_ht_main.c`：`kernel/net/mac80211/rc80211_minstrel_ht.c`（ACK android15-6.6-2026-01，6.6.118）
- `rc80211_compat.c`：本工程新增（frame_duration 实现 + 模块 license + module_init 包装）
- `mac80211.symvers`：从**手机原厂 mac80211.ko 的 `__kcrctab` 段提取**的 134 个导出符号 CRC，
  用于让独立模块的 modpost/insmod 通过符号版本校验
- `Makefile`：外部模块构建（`CONFIG_MAC80211_RC_MINSTREL=1` 等编译宏）

## 构建

```bash
cd driver/rc80211
make -j4        # 使用 /root/haotian-build/kernel + kernel-out（见 build/wsl-build.sh）
# 产物：rc80211_minstrel_ht.ko
```

构建脚本参考 `build/wsl-build-minstrel.sh`。

## 验证

```bash
adb push rc80211_minstrel_ht.ko /data/local/tmp/
adb shell su -c 'insmod /data/local/tmp/rc80211_minstrel_ht.ko'
adb shell su -c 'cat /sys/module/mac80211/parameters/ieee80211_default_rc_algo'  # 仍为空
# 再加载 wonder 时会看到：ieee80211 wonder: Selected rate control algorithm 'minstrel_ht'
```
