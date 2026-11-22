# 许可与第三方来源

> 说明：本工程是 [AdenXie/pandora-airdrop](https://github.com/AdenXie/pandora-airdrop)（小米 17 Pro）
> 向小米 15 Pro（haotian）的移植衍生工程。以下许可清单沿用上游，并标注本移植新增/改名的文件。
> 新增的移植代码（`device/`、`tools/` 下的打包/校验/CRC 工具、KernelSU 脚本的适配与加固、
> 兼容模块的加固部分）与上游自有部分一致，以 GPL-2.0-only 发布。

本仓库汇集不同来源的代码，不用一个根目录许可证覆盖全部内容。文件内的 SPDX 或版权声明优先。公开本仓库不表示所有内容都取得相同许可。

## 各目录的来源与许可

| 目录 / 文件 | 来源 | 许可 |
|---|---|---|
| `driver/patches/` | 对 MiCode `vendor_qcom_opensource_wlan`（高通 qcacld-3.0 / qca-wifi-host-cmn）的修改；0001 含 houji-airdrop 驱动树的移植代码 | 沿用被修改文件的许可（高通文件为 ISC/GPL-2.0 双许可，见各文件头）；houji 驱动部分为 GPL-2.0 |
| `driver/wonder/` | houji-airdrop `driver/wonder`，加了 `wonder_enable` sysctl | GPL-2.0（SPDX） |
| `driver/bridge/`、`driver/mhi_fw/` | 上游本项目模块；本移植改名为 `xos_wonder_bridge` / `xos_mhi_fw` 并更新字符串 | GPL-2.0-only（SPDX） |
| `owly/pandora-owly.patch` | 对 houji-airdrop `native/houji-runner`（提交 353a076）的修改 | 已获 houji-airdrop 作者许可发布；与上游一致，未授予开源许可（见下文） |
| `runtime/radio.sh`、`runtime/bridge-supervisor.sh` | 由上游 pandora 版改写（本移植：设备参数化、超时/回滚加固、MHI 可降级、SELinux 域兼容），再上溯到 houji-airdrop `runtime/owly-xos` 的同名脚本 | 已获 houji-airdrop 作者许可发布；与上游一致，未授予开源许可（见下文） |
| `compat/` | 上游 LSPosed 模块；本移植改包名为 `org.haotian.xoscompat` 并加固；相册分享跳转修复移植自 houji-airdrop 的 `org.houji.xoscompat` | 移植部分同上；其余为本项目代码，GPL-2.0-only |
| `compat/stubs/` | Xposed API 的编译期桩（只含接口签名，不打包进 APK） | Apache-2.0（XposedBridge API） |
| `module/` | 上游 KernelSU 模块脚本；本移植增加设备校准、vermagic 校验、OTA 保护、后台退避等 | 本项目代码，GPL-2.0-only |
| `device/` | 本移植新增：设备配置模板（haotian 及新机型模板） | 本项目代码，GPL-2.0-only |
| `firmware/stream_vendor.py` | 改写自 houji-airdrop `firmware-acquisition/acquire-ap.py`，运行时调用 samloader | 已获 houji-airdrop 作者许可发布；与上游一致，未授予开源许可；运行时调用的 samloader 为 GPL-3.0+，不随本仓库分发 |
| `firmware/get_amss20.py`、`firmware/make_recipe.py`、`firmware/recipe/` | 上游（独立实现三星 FUS 协议，不含 samloader 代码；位置文件只有偏移和长度，不含三星数据） | 本项目代码，GPL-2.0-only |
| `tools/`、`docs/` | 上游工具 + 本移植新增：`package.mjs`、`verify-modules.mjs`、`ko-crc-extract.mjs`、`preflight.sh`、`build-all.ps1`、`fetch-upstream.*` | 本项目代码，GPL-2.0-only |
| `build/` | 本移植新增：Linux 内核模块构建脚本/Dockerfile/移植资料 | 本项目代码，GPL-2.0-only |

## 安装包中的二进制

| 文件 | 构建来源 |
|---|---|
| `qca_cld3_peach_v2.ko` | MiCode 源码 + `driver/patches/`（GPL-2.0 部分须随附源码，即本仓库）。**必须由使用者在 Linux 上为本机内核重编，本仓库不分发预编译产物** |
| `wonder.ko`、`xos_wonder_bridge.ko`、`xos_mhi_fw.ko` | `driver/` 下的源码（GPL-2.0），由使用者编译 |
| `owly-xosd` | houji-airdrop 353a076 + `owly/pandora-owly.patch`；Owly 协议栈为 MIT。**由使用者根据上游 release 自行下载（`tools/fetch-upstream.*`），本仓库不重新分发** |
| `xos-bridge.zip`、`wonder-init` | houji-airdrop 100c1e0 原样编译；`wonder-init` 为 GPL-2.0-only，XosBridge 同上，未授予开源许可。同样由使用者从上游 release 自取 |
| `Haotian-XOS-Compat.apk` | `compat/`（本仓库源码可重建） |

## 不随本仓库分发的闭源组件

三星 S26 Ultra WLAN 固件 `amss20.bin`、小米 ROM、原厂驱动与小米互传 APK 都不包含在本仓库或发布的安装包里。固件需用户自备，见 `firmware/README.md`。

## houji-airdrop 衍生部分

houji-airdrop 的说明写明，其自有新增文件"暂未另行授予统一开源许可"。本仓库中基于这些文件的部分：

- `runtime/radio.sh`、`runtime/bridge-supervisor.sh`
- `owly/pandora-owly.patch`
- `compat/` 中移植的相册分享跳转修复（`Hook.java` 的 `hookIntentResolver` 方法）
- `firmware/stream_vendor.py`
- 安装包里的 `xos-bridge.zip`，以及 `owly-xosd` 中 houji-runner 的部分

均已取得 houji-airdrop 作者许可发布。与上游保持一致，这些部分不授予开源许可。如需在本项目之外复制、修改或再分发，请先联系 houji-airdrop 作者。

## 本项目自有代码

`device/`、`module/`、`build/`、`compat/` 的非移植部分、`firmware/` 下除 `stream_vendor.py` 以外的脚本与位置文件、`tools/`、`docs/` 以 GPL-2.0-only 发布，与驱动部分一致，全文见根目录 [LICENSE](LICENSE)。根目录 LICENSE 只覆盖这些部分和其他标明 GPL-2.0 的文件，不覆盖上面的 houji-airdrop 衍生部分。
