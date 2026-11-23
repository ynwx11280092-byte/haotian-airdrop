# WSL2 构建/适配最终状态（v1.0.5，2026-11-23 01:30）

## 结论：功能已跑通

- 5 个内核模块全部编译通过并在 haotian（小米 15 Pro，OS4.0.40，内核 6.6.118）加载：
  `qca_cld3_peach_v2.ko`、`wonder.ko`、`xos_wonder_bridge.ko`、`xos_mhi_fw.ko`、`rc80211_minstrel_ht.ko`；
- iPhone → 小米接收：可用（Live Photo 合成按 MiShare 版本能力）；
- 小米 → iPhone 发送：可用（需 iPhone AirDrop「所有人，10 分钟」）；
- PT/AWDL 会话：`pt_activate published=1 phase=3 freq=5745`、wonder0/wondertap0/xos0 正常、owly-xosd 运行；
- 退出恢复：~1.7–1.9 s 回到原厂驱动/Wi-Fi，不写系统分区。

## 关键适配点（最终）

1. 头文件 ABI 对齐手机原厂 cfg80211/mac80211（testmode 指针）；
2. 原厂 mac80211 无 RC 算法 → 自带 `rc80211_minstrel_ht.ko`（CRC 取自手机 mac80211.ko）；
3. 驱动固件路径 `CHIP_NAME=peach_v2`；
4. Kbuild 打开 `CONFIG_DRIVER_PASSTHRU_OWNER/MODE/RUNTIME/DP=y`；
5. PT 参数按 pandora v1.1.2 原样（`pt_single_ring=1`、`pt_remote_reo=2` 等）；
6. 兼容模块（LSPosed）：
   - Wi-Fi 状态伪装；
   - 跳过 MiShare 5.5.0 的 5GHz STA handoff（v1.1.2 同款修复）；
   - MiShare 进程内 mDNS 探测（xos0 Network 绑定 socket 发 QU/QM + 单播响应扇出为组播，单进程/去重/限速防风暴）。

## v1.0.5 说明

- 用户态发现：MiShare 进程内 mDNS 探测 + 缓存 iPhone 源地址 + QU 单播查询 + 单播响应组播扇出；
- 实测「关开 iPhone 隔空投送」后设备显示稳定；
- iPhone 端 AirDrop 需为「所有人（10 分钟）」。

## 最终产物

- `dist/haotian-airdrop-v1.0.5-with-firmware.zip`（模块安装包，含 5 个 ko + 固件 + 兼容 APK）
- `dist/Haotian-XOS-Compat.apk`
- `dist/haotian-modules-2026-11-23.zip`
- `dist/haotian-airdrop-v1.0.5-source.zip`
- `dist/haotian-phone-data.zip`
