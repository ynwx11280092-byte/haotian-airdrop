# haotian 实机模块符号 CRC 摘要（2026-11-22）

来源：手机 `/vendor_dlkm/lib/modules/` 中原厂三个 .ko（由 haotian-dump-collector 采集，root 复制到 /sdcard 后 adb 拉取）。
提取工具：`tools/ko-crc-extract.mjs`（导入符号取 `__versions`，导出符号取 `__crc_*` / `__kcrctab`）。

| 模块 | sha256 | 导入符号数 | 导出符号数 | vermagic |
|---|---|---|---|---|
| qca_cld3_peach_v2.ko | `86d56305f1eff270…` | 584 | 0 | 6.6.57-android15-8-4k SMP preempt mod_unload modversions aarch64 |
| cnss2.ko | `6af688ed2ce3e38b…` | 370 | 74 | 6.6.57-android15-8-4k SMP preempt mod_unload modversions aarch64 |
| mhi.ko | `6ddee09c651b9539…` | 113 | 61 | 6.6.57-android15-8-gac38060c57b2-4k SMP preempt mod_unload modversions aarch64 |

- 符号冲突（同名不同 CRC）：**无**
- 原厂驱动 584 个导入符号中，63 个由 cnss2 导出（其余为内核导出符号）。
- `mhi_bdf_to_controller`：**mhi.ko 已导出**（xos_mhi_fw.ko 可用），CRC=0x9c26d2b3
- `cnss_get_wlan_tsf_gpio`：**cnss2.ko 未导出**，也没有模块导入它 → 驱动补丁 0003 的桩需要保留。
- `cnss_set_vendor_wonder_priv_data` / `cnss_wonder*`：cnss2 导出列表与导入表里都没有 → 原厂完全没有 wonder 支持；本项目 bridge/wonder 是自带的，不依赖这些符号。

## 关键符号 CRC（挑选）

| 符号 | 来源 | CRC |
|---|---|---|
| mhi_bdf_to_controller | export / mhi.ko | 0x9c26d2b3 |
| mhi_register_controller | import / cnss2.ko | 0x2f0622d8 |
| mhi_alloc_controller | import / cnss2.ko | 0xa2561515 |
| cnss_get_mem_seg_count | export / cnss2.ko | 0x1d2606f1 |
| cnss_get_wifi_kobj | export / cnss2.ko | 0x0ea16d0e |
| cfg80211_register_netdevice | import / qca_cld3_peach_v2.ko | 0x28ef6805 |

完整表见 `phone-crcs.txt`；modpost 可直接用的片段见 `vendor.symvers`。
