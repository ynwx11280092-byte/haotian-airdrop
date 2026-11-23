# 小米 15 Pro 原生 AirDrop（haotian / 澎湃 OS 4.0.4.0）移植工程

> **仓库说明（GitHub 发布版）**
> 本仓库只包含源码、脚本、文档与构建工具；**不包含**三星闭源固件 `amss20.bin`、
> 小米 ROM、原厂驱动与小米互传 APK，也不包含预编译内核模块和上游 release 二进制。
> 首次使用请按 [BUILD-MODULES.md](BUILD-MODULES.md) 与 [PORTING.md](PORTING.md) 说明，
> 通过 `firmware/README.md`（BYOB）与 `tools/fetch-upstream.*` 获取所需素材后自行编译。
> 许可与来源见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。


把 [AdenXie/pandora-airdrop](https://github.com/AdenXie/pandora-airdrop)（小米 17 Pro / pandora，
原生 AirDrop：iPhone 隔空投送 ↔ 小米互传）移植到 **小米 15 Pro（codename `haotian`，2410DPN6CC）**、
**澎湃 HyperOS OS4.0.4.0.XOBCNXM（Android 17 / SDK 37）** 的工程。

> 目标内核（已在真机确认）：`6.6.118-android15-8-gf72a02f47f4b-abogki551678766-4k`
>
> 上游项目基于小米 17 Pro 的 `6.12.69` 内核与 `qca_cld3_peach_v2.ko` 驱动。
> 小米 15 Pro 的 WLAN 芯片同属 **peach（FastConnect 7900）** 家族，但内核是 **6.6**，
> 因此**上游预编译的 4 个内核模块完全不能在本机加载**，必须用 haotian 的 6.6 内核源码
> 重新编译（见 [BUILD-MODULES.md](BUILD-MODULES.md)）。

## ⚠️ 当前状态（务必先读）

| 部分 | 状态 |
|---|---|
| 构建/真机（2026-11-22 20:45） | ✅ 5 个内核模块全部编译成功；Wi-Fi 5GHz 正常；PT/AWDL 会话真机验证通过（详见 `build/wsl-port-STATUS.md`） |
| 实机参数采集（2026-11-22） | ✅ 内核/驱动/固件/小米互传/PCI/root 信息已采集并写入 `device/haotian.env` |
| 设备适配层（`device/*.env`）、安装器、运行时脚本、后台守护 | ✅ 已完成移植并针对 haotian 加固/优化 |
| LSPosed 兼容模块（`compat/`） | ✅ 已从源码重建为 `org.haotian.xoscompat`（含版本容错加固，已支持实机 5.5.0/vc 50500） |
| `wonder.ko` / `xos_wonder_bridge.ko` / `xos_mhi_fw.ko` / `rc80211_minstrel_ht.ko` 源码 | ✅ 已按 haotian 改名、参数化，并全部在本机 WSL2 编译成功（见 `build/wsl-port-STATUS.md`） |
| `qca_cld3_peach_v2.ko` PASSTHRU 驱动 | ⚠️ 需把上游 6.12 补丁重新移植到 6.6 WLAN 源码树后编译（本仓库提供补丁与移植脚本） |
| 实机验证 | ✅ **已完成（v1.0.0）**：iPhone ↔ 小米双向发现与互传可用；iPhone→小米接收、小米→iPhone 发送均已实测；Wi-Fi 恢复/回滚正常 |
| 实机数据（CRC/MHI 偏移/内核配置） | ✅ 已从手机原厂 `.ko` + `/proc/config.gz` 提取：`driver/haotian-phone-data/` |

**实机实测要点**（详见 [PORTING.md](PORTING.md) §1）：

* 内核 `6.6.118-android15-8-gf72a02f47f4b-abogki551678766-4k`；原厂 WLAN 驱动
  `qca_cld3_peach_v2`（build-id `ece9daf2…`，vermagic UTS 竟是 `6.6.57-android15-8-4k`）；
* 原厂 `peach/amss20.bin` 只有 6,930,496 B，**比三星 S26U 固件小 434,176 B** →
  `xos_mhi_fw.ko` 在本机是必须的（不能走"固件不更大就跳过"的降级）；
* 15 Pro 内核**完全没有** wonder/PASSTHRU 支持（`wonder_enable` 缺失、相关 kallsyms 0 命中）
  → 只能走"自带驱动 + bridge + wonder"的完整替换路线；
* 小米互传 **5.5.0_20261029_1004（vc 50500）**，兼容模块已加入已知版本；
* KernelSU + LSPosed 已安装，WLAN PCI 为 `0000:01:00.0`，设备上无旧模块残留；
* 已从原厂 `.ko` 提取**符号 CRC 表**（qca 驱动 584 导入 / cnss2 74 导出 / mhi 61 导出，同名无冲突）
  与 **MHI 结构体偏移**（`img_pre_alloc=0x294`、`fbc_image=0x90` 等），见 `driver/haotian-phone-data/`；
  `mhi_bdf_to_controller` 已确认由 mhi.ko 导出，`cnss_get_wlan_tsf_gpio` 未导出（补丁保留桩）；
* 内核配置已采集：**MODVERSIONS + 经典 genksyms（无 GENDWARFKSYMS/EXTENDED）**、
  `CFI_CLANG`/`SHADOW_CALL_STACK`/`KASAN`/`UBSAN` 全开、**无 `NL80211_TESTMODE`**、
  `TRIM_UNUSED_KSYMS` 带 `abi_symbollist.raw` 白名单 —— 与 pandora 6.12 的编译参数不同，
  BUILD-MODULES.md 已按实机配置更新。

因此：**本仓库交付的是"适配完成的工程 + 可复现构建链 + 已编译的 4 个内核模块"**。
`dist/haotian-airdrop-v0.2.0.zip` 就是完整安装包（4 个 `.ko` + 运行时 + 兼容 APK；
三星 S26U 固件未内置，安装器会从手机查找并做 SHA 校验，或用 `--firmware` 重新打包内置）。
剩余的最后一步是**真机 insmod / 功能验证**（手机连 USB 后按 PORTING.md §9 进行）。

## 目录

```
haotian-airdrop/
├── device/                 # 设备配置（haotian.env 为目标设备；_template.env 供其它机型）
├── module/                 # KernelSU 模块脚本（安装器/开机服务/操作按钮/卸载）
├── runtime/                # 会话脚本：radio.sh（切换无线电）+ bridge-supervisor.sh
├── compat/                 # LSPosed 兼容模块源码 + Windows/Linux 构建脚本
├── driver/                 # 内核模块源码/补丁（来自上游，bridge/mhi 已改名 xos_*）
├── firmware/               # 三星 S26U amss20.bin 获取脚本（上游，未改动）
├── tools/                  # 打包、内核模块校验、设备采集、上游二进制获取
├── build/                  # Linux 内核模块构建脚本 + Dockerfile
├── upstream/               # 由 tools/fetch-upstream.* 放人的上游设备无关二进制
└── dist/                   # 构建产物
```

## 快速开始

### 1. 先采集一次手机信息（实机已采集，换机/OTA 后重跑）

把 `tools/preflight.sh`（v2）推到手机，用 root 跑一次：

```sh
adb push tools/preflight.sh /data/local/tmp/
adb shell su -c 'sh /data/local/tmp/preflight.sh'
# 报告：  /sdcard/Download/haotian-airdrop-preflight.txt
# dump：  /sdcard/Download/haotian-dump/（原厂驱动/cnss2/mhi 的 .ko，用于 CRC 与 MHI 偏移）
```

本机 2026-11-22 的采集结果已写进 `device/haotian.env` 的 `KNOWN_STOCK_*`；运行 v2 是为了补上
**内核 `.config` 与三个厂商 `.ko`**（提取符号 CRC、重新推导 MHI 结构体偏移必须用）。
详见 [PORTING.md](PORTING.md) §2。

### 2. 构建内核模块（Linux，必须）

```sh
# 取得手机真实内核 .config（Module.symvers CRC 必须一致）
adb shell su -c 'cat /proc/config.gz' > phone.config.gz
# 在 Linux 上：
./build/build-modules.sh --work ~/haotian-build --config phone.config.gz
# 产物：build/out/kernel-modules/{qca_cld3_peach_v2,wonder,xos_wonder_bridge,xos_mhi_fw}.ko
```

详细步骤、补丁移植方法、符号 CRC 核对见 [BUILD-MODULES.md](BUILD-MODULES.md)。

### 3. Windows 打包（本机即可完成的部分）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\build-all.ps1                 # 预览包（无内核模块，安装器会中止）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\build-all.ps1 -RequireKernelModules -Firmware C:\Download\s26u-amss20.bin
```

也可以分步：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File compat\build.ps1                    # 构建兼容 APK -> compat/dist/
powershell -NoProfile -ExecutionPolicy Bypass -File tools\fetch-upstream.ps1            # 从上游 release 取 3 个运行时二进制 -> upstream/
node tools/verify-modules.mjs --inputs build/out/kernel-modules --profile haotian
node tools/package.mjs --inputs build/out --upstream upstream [--firmware ...]
```

### 4. 产物

* `dist/haotian-airdrop-v0.2.0.zip`：**完整安装包**（约 7 MB），含 4 个已编译内核模块
  （`qca_cld3_peach_v2.ko` / `wonder.ko` / `xos_wonder_bridge.ko` / `xos_mhi_fw.ko`）、
  运行时、兼容 APK 与安装/校准/回滚脚本。S26U 固件默认不内置（安装时从手机查找）。
* `dist/haotian-modules-2026-11-22.zip`：4 个内核模块 + SHA256SUMS（供检查/手动 insmod 测试）。
* `dist/Haotian-XOS-Compat.apk`：已构建并签名的 LSPosed 兼容模块
  （`org.haotian.xoscompat`，v0.2.0，versionCode 2，`apksigner` 验证通过）。
* `dist/haotian-airdrop-v0.2.0-source.zip`：完整源工程快照。
* 重新打包：`node tools/package.mjs --inputs build/out --upstream upstream --firmware <s26u-amss20.bin>`
  可产出内置三星固件的完整包。

### 5. 安装（KernelSU）

1. KernelSU 里刷入 `dist/haotian-airdrop-v0.2.0.zip`（**必须含 4 个内核模块**，否则安装器会中止）。
2. 重启。
3. 首次安装：LSPosed 里启用「小米15 Pro AirDrop 兼容」，作用域保持默认（小米互传 + 系统分享），再重启。
4. 打开小米互传 →「与Apple设备互传」，iPhone 隔空投送即可看到本机。

## 相对上游的关键改动

### 设备适配

* 所有 pandora 硬编码（机型/内核/驱动名/固件路径/PCI 节点/模块名）收进 `device/haotian.env`；
* **运行时实机探测**驱动名、固件路径、WLAN PCI 电源节点；haotian 的驱动名保留
  `qca_cld3_peach_v2` / `qca_cld3_peach` 两个候选，避免猜错；
* 安装时把当前健康原厂状态的"驱动哈希 + 驱动 build-id + 固件哈希 + 内核"写进
  `calibration.env`，之后每次开机校验；OTA 改变任何一项 → **自动停用并恢复 Wi-Fi**，
  不再依赖写死的 pandora 哈希；
* 安装器校验 4 个 `.ko` 的 vermagic 配置后缀 + 内核主系列（CONFIG_MODVERSIONS 下 UTS 可不同），
  并在安装前与实机采集的 `KNOWN_STOCK_*` 指纹严格比对，任何一项不符都在改动任何东西前中止；
* 内核模块 `pandora_mhi_fw.ko` / `pandora_wonder_bridge.ko` 改名为 `xos_mhi_fw.ko` /
  `xos_wonder_bridge.ko`（源码、Makefile、运行时脚本同步更新）。

### 稳定性（避免重大报错）

* `radio.sh` 所有可能无界等待/死循环的地方加上限并明确回滚：`umount` 最多 20 次、
  等待 `refcnt`/`pt_activate`/owly ready 均有超时、失败设置 `RESTORE_FAILED`，
  开机服务会再次恢复；
* `enter` 全程 `trap ... EXIT` 回滚；`restore` 先冻结+清空 PT 对端再卸载驱动；
* 安装器先做完全部校验再动手，任何失败分支都不写系统、不改设置；
* 服务连续启动失败有次数上限与明确提示，不会无限重启把 CPU 占满；
* 兼容模块对小米互传版本做门控 + 所有 hook 异常隔离，版本不符时自动跳过
  Live Photo/相册跳转 hook，绝不因钩子缺失拖垮小米互传进程。

### 后台/功耗

* 开机服务仍是事件驱动（busybox `inotifyd`），没有轮询；无 inotifyd 时退化为 30 秒
  一次"标志位比较"，状态不变不做任何事；
* supervisor 崩溃重启由上游固定 5 秒改为 **5→10→20→40→60 秒指数退避**，
  异常崩溃循环的唤醒次数大幅下降；
* idle 模块加载带 3 次重试，避免开机时序问题导致模块入口缺失；
* 日志统一 512 KiB/tail 2000 行截断，避免长期写放大；
* 会话结束/锁屏由 XosBridge 触发 `radio.sh restore`，不额外引入常驻轮询进程。

## 已知限制（与上游一致）

* 大文件首次发送 iPhone 可能显示"等待中"30–40 秒（iPhone 端 AWDL 省电行为，未解决）；
* HEIC 格式的 Live Photo 不合成，会收到照片 + 视频两个文件；
* 固件断言后 SSR 重新初始化失败，目前只能重启恢复（补丁 0007 已消除已知触发路径）；
* 不支持小米 17/18 系列以外的其它机型直接复用内核模块。

### 兼容模块的小米互传版本门控

`compat/Hook.java` 里 `KNOWN_MISHARE_VERSIONS = {50401, 50501}` 是已确认的 Live Photo /
相册跳转 hook 适用版本。若你手机上的版本不同（LSPosed 日志会出现
`MIShare versionCode NNNNN not in known set, advanced hooks skipped`）：

* Wi-Fi 状态伪装（会话必需的基础能力）**仍然生效**，只是 Live Photo 合成/相册跳转不会挂载；
* 把日志里的 versionCode 加进该数组，然后用 `compat/build.ps1` 重新构建 APK 并重打包即可尝试；
* Live Photo 的混淆入口也可能随版本变化：`Hook.java` 的
  `LIVE_PHOTO_COMMIT_CANDIDATES_EXTRA` 预留了候选类名表，可把新版本的混淆类名加进去。

## 许可与来源

* 本项目是 pandora-airdrop 的移植衍生工程：上游 GPL-2.0 部分（驱动补丁、wonder、bridge、
  MHI 辅助模块、KernelSU 模块脚本、兼容模块自有部分、辅助工具和文档）继续 GPL-2.0，
  见 [LICENSE](LICENSE)；
* 基于 houji-airdrop 的运行脚本、owly 补丁、兼容模块移植部分和固件下载脚本的许可与上游
  一致（不授予开源许可），见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)；
* `upstream/` 里的 `owly-xosd`、`wonder-init`、`xos-bridge.zip` 由**你自己**从上游 release
  下载（`tools/fetch-upstream.*`），本仓库不重新分发。

## 免责声明

替换 WLAN 驱动与固件存在风险。本工程不修改任何分区，模块运行文件在
`/data/local/tmp/xos`，固件替换是临时 bind mount，重启即恢复；但仍请理解原理后自行决定是否使用。
本工程与小米、苹果、三星、高通无关。


## v1.0.5（最终稳定版，2026-11-23）

### 已验证功能
- iPhone → 小米：隔空投送发送/接收正常（含 Live Photo 合成，受 MiShare 版本支持范围限制）；
- 小米 → iPhone：MiShare「与 Apple 设备互传」可发现 iPhone 并发送；
- 会话期间 Wi-Fi 自动关闭、退出后 2 秒左右恢复；PT 驱动/固件全部临时替换，不写系统分区。

### 发现机制
- 小米互传 5.5.0 的 `RawMdnsBrowser` 只监听不发查询，且其 `WifiConflictManager` 会先断开 5GHz STA 并等待/重试；
- 兼容模块（LSPosed）负责：Wi-Fi 状态伪装、**跳过 5.5.0 的 STA 5GHz handoff**、在 MiShare 进程内用 xos0 网络绑定 socket 发 QU/QM mDNS 查询并把单播响应扇出为组播；
- 内核侧：PASSTHRU/PT 驱动 + S26U amss20 固件 + wonder/owly 提供 xos0 AWDL 链路。

### 性能（haotian 实测）
| 项目 | 耗时 |
|---|---|
| 首次进入 PT 会话（点击页面 → xos0 ready） | ~3.0–3.4 s |
| 关闭页面后 restore 返回 | ~1.7–1.9 s |
| 会话就绪后 iPhone 出现 | 通常 1–3 s（取决于 iPhone AirDrop 广播时机） |

### 使用前提
- iPhone 隔空投送设为 **「所有人，10 分钟」**（iOS 16.2+ 该设置会自动过期，需重设）；iPhone 解锁、蓝牙/Wi-Fi 开启，关闭个人热点；
- 小米互传版本 5.5.0（vc 50500）/5.4.x 均可；LSPosed 中启用兼容模块并勾选「小米互传」「系统分享」。

### 清理与优化（v1.0.0）
- 删除已废弃的独立 mdns-fanout helper 及其安装逻辑（改由 MiShare 进程内探测）；
- 删除未使用的 wait_wifi 等死代码；
- mDNS 探测：单进程、去重（3 s 内相同响应只扇出一次）、限速 10 次/秒，避免自激风暴；
- query 节奏：会话就绪后 120 ms 起连续快发，之后 300 ms/1.2 s 递减，兼顾速度与空口。


### v1.0.5 发现稳定性（2026-11-23）

- MiShare 进程内 mDNS 探测线程会**缓存上一次 iPhone 的 mDNS 源地址**；
- 下次会话除组播查询外，会直接向该地址发 **QU 单播查询**，并把 iPhone 的单播响应扇出为组播；
- 实测（haotian + iPhone，多次关开 iPhone 隔空投送）：设备显示稳定；
- 仍建议使用顺序：小米页面先打开 → iPhone 关/开一次隔空投送（或重新打开 AirDrop 面板）→ 1–3 秒内出现。
