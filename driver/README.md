# 内核模块

| 模块 | 源码 | 说明 |
|---|---|---|
| `qca_cld3_peach_v2.ko` | MiCode WLAN 源码 + `patches/` | 带 PASSTHRU/wondertap 的 peach 驱动，会话期间替换原厂驱动 |
| `wonder.ko` | `wonder/` | houji-airdrop 的 wonder（mac80211 wiphy），加了 `net.wonder.wonder_enable` sysctl |
| `pandora_wonder_bridge.ko` | `bridge/` | cnss 与 wonder 之间的生命周期桥 |
| `pandora_mhi_fw.ko` | `mhi_fw/` | 让 cnss2 重新分配固件缓冲区，否则加载更大的 S26U 固件会内核崩溃 |

目标内核：`6.12.69-android16-6-g43b5ab7e247d-abogki561813157-4k`（小米 17 Pro，HyperOS OS4.0.6.0.XBLCNXM）。模块需要与该内核的符号 CRC 完全一致，换内核必须重新编译和核对。

## 驱动补丁顺序

基础源码：MiCode `vendor_qcom_opensource_wlan` 仓库 `popsicle-w-oss` 分支，提交 `36df473`（"Kernel: Xiaomi waln for Xiaomi 17, Xiaomi 17 Pro AND Xiaomi 17 Pro Max Android W"）。按顺序应用：

| 补丁 | 内容 |
|---|---|
| 0001 | 以 houji-airdrop 驱动树（基于 a4da9e3b）三方合并移植 wondertap/PASSTHRU |
| 0002 | 策略管理器 next-action 表补上 PASSTHRU 单连接状态 |
| 0003 | 适配 pandora 的 API 差异，桩掉 `cnss_get_wlan_tsf_gpio` |
| 0004 | PASSTHRU 调试与调优参数：会话期间关闭 ILP/IMPS 低功耗（`pt_lowpower_off`，与三星 wondertap 一致）、同步 lmac（`pt_sync_lmac`）、强制 TID（`pt_force_tid`）、TSF 查询与 WMI 信道跳变调度实验接口（`pt_tsf`、`pt_ch_hop`）及诊断日志 |
| 0005 | TX bank A/B 配置 |
| 0006 | vendor 信道调度（`pt_vendor_chan`） |
| 0007 | PT 远端对端生命周期加固：冲突即停 TX、删除重试区分提交失败与确认超时、同 MAC 删除后 2 秒冷却、AUTH 在映射锁下复核 |

0001–0003 是 `git format-patch` 格式（`git am`），0004–0007 是普通 diff（`git apply` 或 `patch -p1`）。按此顺序应用后，源码与实机验证的 v3 驱动（SHA-256 `f3c35464…`）所用源码逐字节一致。

## 编译要点

- 使用 ACK `android16-6.12-2026-03` 分支作为内核树，clang r536225，`gki_defconfig` 加手机配置差异（`EXTENDED_MODVERSIONS`、`GENDWARFKSYMS`、CFI normalize、`LOCALVERSION=-4k`），并设置 `KBUILD_GENDWARFKSYMS_STABLE=1`，否则导出符号 CRC 与手机不一致。
- 手机 vendor 的 cfg80211/mac80211 开启了 `CONFIG_NL80211_TESTMODE`（ops 表多 0x10），vendor 模块编译时必须定义它。
- vendor 模块需要模拟混合构建：`-include` 由 `port-scripts/make_vendor_defines.py` 从 soc-repo `canoe_perf.bzl` 生成的 `vendor_defines.h`，并提供 vendor 专用头文件。
- IPA offload 在本构建中关闭。
- 编译后用 `../tools/kocrc.py` 把模块导入符号的 CRC 与手机导出值逐一比对，全部一致才可加载。

`port-scripts/` 是移植过程中使用的辅助脚本（合并冲突处理、Kbuild 修正、vendor 符号表等），供参考。
