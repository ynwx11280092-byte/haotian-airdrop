# 移植报告：pandora-airdrop → 小米 15 Pro（haotian）

本文记录把 [pandora-airdrop](https://github.com/AdenXie/pandora-airdrop)（小米 17 Pro / pandora，内核
6.12.69）移植到 **小米 15 Pro（haotian，2410DPN6CC）+ 澎湃 HyperOS OS4.0.4.0.XOBCNXM（Android 17）**
时，哪些东西可以直接复用、哪些必须重做、哪些必须先在实机确认。

---

## 1. 目标设备事实（2026-11-22 实机采集已确认）

| 项目 | pandora（上游） | haotian（本项目） |
|---|---|---|
| 机型 | 小米 17 Pro | 小米 15 Pro |
| SoC | SM8850 (canoe) | SM8750 (sun) |
| 系统 | HyperOS OS4.0.6.0.XBLCNXM（Android 17 / SDK 37） | HyperOS OS4.0.4.0.XOBCNXM（Android 17 / SDK 37） |
| 内核 | `6.12.69-android16-6-g43b5ab7e247d-abogki561813157-4k` | **`6.6.118-android15-8-gf72a02f47f4b-abogki551678766-4k`**（实机 `uname -r`） |
| WLAN 芯片 | peach_v2（FastConnect 7900） | **peach（FastConnect 7900）**，同一芯片族 |
| 原厂 WLAN 驱动 | `qca_cld3_peach_v2.ko` | **`/vendor_dlkm/lib/modules/qca_cld3_peach_v2.ko`**，sha256 `86d56305…94d197`，build-id `ece9daf2…` |
| 驱动 vermagic | 6.12 构建 | **`6.6.57-android15-8-4k SMP preempt mod_unload modversions aarch64`**（注意 UTS 是 6.6.57，不是内核的 6.6.118） |
| 原厂固件 | `peach/amss20.bin` | **`/vendor/firmware_mnt/image/peach/amss20.bin`**，6,930,496 B，sha256 `90e365a5…a97fc`；同目录另有 `amss.bin` 7,000,128 B |
| 小米互传 | 5.4.1（vc 50401） | **5.5.0_20261029_1004（vc 50500）** |
| wonder / PASSTHRU | 驱动残留字符串、cnss2 有部分导出 | **完全没有**：`wonder_enable` 缺失、`cnss_set_vendor_wonder_priv_data` / `cnss_wonder` 在 kallsyms 中 0 命中 |
| WLAN PCI | `0000:01:00.0` | **`0000:01:00.0`**（wlan0 → `.../0000:00:00.0/0000:01:00.0`） |
| root / LSPosed | 需要 | KernelSU + LSPosed 均已安装 |

**实机采集带来的关键结论：**

1. **内核串与网上资料不同**：deviceinfohw/ROM 站点给出的
   `6.6.118-…-gb9cc6ec16bc8-abogki536571621-4k` 并非本机，实机是
   `…-gf72a02f47f4b-abogki551678766-4k`。工程已按实机值更新（`device/haotian.env`）。
   这也说明不同批次/版本的 15 Pro 内核串可能不同，**安装器必须精确匹配**。
2. **原厂 vendor 模块不是用当前内核编的**：原厂 WLAN 驱动 vermagic 的 UTS 是
   `6.6.57-android15-8-4k`，却能在 `6.6.118` 内核上加载 —— 这实测验证了
   `same_magic()` 在 `CONFIG_MODVERSIONS` 下**只比较 vermagic 第一个空格之后的配置
   后缀 + 符号 CRC**，不比较 UTS_RELEASE。所以自编模块的 UTS 可以不同（但我们仍要求
   配置后缀一致）。
3. **wonder 支持为 0**：15 Pro 的内核/驱动完全没有小米 17 系列那套 wonder/PASSTHRU
   痕迹，必须走"自带 PT 驱动 + bridge + wonder"的完整替换路线，没有"少改驱动"的捷径。
4. **MHI 模块是必须的**：原厂 `amss20.bin` 仅 6,930,496 B，比三星 S26U 的
   7,364,672 B 小 434,176 B；换用 S26U 固件时 FBC 缓冲区一定不够，`xos_mhi_fw.ko`
   不能省（`radio.sh` 也按"必须"处理）。
5. **小米互传 5.5.0**：比上游验证的 5.4.1 新。兼容模块已把 `50500` 加入已知版本
   （Live Photo 的混淆入口仍按候选类名尝试，失败只降级、不影响 Wi-Fi 伪装）。

**结论：内核从 6.12 变成 6.6，所有内核模块必须重编。** 上游 `dist` 里的 4 个 `.ko`
（vermagic 是 6.12.69 的构建）在 haotian 上无法加载，不要尝试直接刷。

---

## 2. 实机采集结果（2026-11-22，已全部完成）

实机已确认：机型/系统/内核串、原厂驱动模块名/路径/哈希/build-id/vermagic、
原厂固件路径/大小/哈希、wonder/PASSTHRU 支持状况、小米互传版本、root/LSPosed、PCI 路径。
这些值已写进 `device/haotian.env` 的 `KNOWN_STOCK_*`，安装器会做严格比对。

随后用 root 采集模块（`dist/haotian-dump-collector.zip`，装在 SukiSU 里即可，不改分区）
把三个厂商 `.ko` 与 `/proc/config.gz` 复制到 `/sdcard/Download/haotian-dump/`，
再通过 adb 拉回 PC，已完成：

1. **符号 CRC 表**（`driver/haotian-phone-data/`）
   * `qca_cld3_peach_v2.ko`：584 个导入符号；
   * `cnss2.ko`：74 导出 / 370 导入；
   * `mhi.ko`：61 导出 / 113 导入；同名符号 CRC 无冲突；
   * `mhi_bdf_to_controller` 已由 mhi.ko 导出（CRC `0x9c26d2b3`）；
   * `cnss_get_wlan_tsf_gpio` 未导出；`cnss_set_vendor_wonder_priv_data`/`cnss_wonder*` 不存在。
2. **内核 `.config`**（`build/phone/config.txt`，本地）：确认 MODVERSIONS + 经典 genksyms
   （无 GENDWARFKSYMS/EXTENDED）、CFI/SCS/KASAN/UBSAN 全开、无 NL80211_TESTMODE、
   TRIM_UNUSED_KSYMS + `abi_symbollist.raw` 白名单等，详见 BUILD-MODULES.md §2。
3. **MHI 结构体偏移**：从 `mhi.ko` 的 `.BTF` + 反汇编推导出 haotian 的
   `img_pre_alloc=0x294 / fbc_image=0x90 / rddm_image=0x98 / rddm_size=0x70 /
   sbl_size=0x78 / seg_len=0x80`，已写入 `driver/mhi_fw/xos_mhi_fw.c`
   （推导记录：`driver/haotian-phone-data/MHI-OFFSETS.md`）。

> 已确认：**不需要**再走"原厂驱动已有完整 PASSTHRU 则简化"的备选路线
> （15 Pro 上完全没有 wonder 支持）。

---

## 3. 可以复用的部分

| 组件 | 说明 |
|---|---|
| `compat/` LSPosed 模块 | 逻辑与机型无关（Wi-Fi 状态伪装 + Live Photo 合成 + 相册跳转）；已重建并加固 |
| `runtime/` 会话脚本 | 逻辑与机型无关，已参数化 + 加固 |
| `module/` KernelSU 脚本 | 已参数化、增加设备校准、OTA 保护、超时与回滚 |
| `owly-xosd` / `wonder-init` / `xos-bridge.zip` | 用户态 aarch64 程序，与内核版本无关；从上游 release 自取（`tools/fetch-upstream.*`） |
| `firmware/get_amss20.py` | 三星 S26U 固件下载脚本，同芯片族可直接用 |
| `driver/wonder/`、`driver/bridge/` | wonder 是独立 mac80211 驱动；bridge 是独立 broker，均只依赖内核标准 API（bridge/mhi 已改名 `xos_*`） |
| `driver/patches/0002–0007` | 策略/调优/生命周期补丁，移植到 6.6 树时参考价值大 |

**不可复用**：`driver/patches/0001`（6.12 的三方合并补丁）不能直接 `git am` 到 6.6 树，
需要按 §4 重新移植；上游预编译的 4 个 `.ko` 不可用。

---

## 4. WLAN 驱动补丁移植（0001–0007）

### 4.1 源码树

* 上游：MiCode `vendor_qcom_opensource_wlan` 的 `popsicle-w-oss` 分支（6.12）。
* haotian：同一仓库的 **`dada-v-oss`** 分支（小米 15 / 15 Pro 同平台 SM8750，
  已确认该分支存在；wlan 仓库无 `haotian-*` / `sun-*` 独立分支，说明 15/15 Pro 共用一份）。
  该分支里有明确的 haotian 板级证据：`wlan-devicetree/haotian-peach-cnss-v8.dts`
  （model "Haotian based on SM8750"）、`sun-peach-cnss-v8.dtsi`（`qcom,cnss-peach`）、
  `fw-api/hw/peach/v1`、`peach_defconfig`，以及两套驱动 profile：
  `sun_gki_peach-v2_defconfig` 与 `sun_gki_peach_defconfig`。源码里 **没有** 
  `passthru/wonder/wondertap/pt_` 相关代码（grep 0 命中），所以必须打补丁。
* 内核源码：MiCode `Xiaomi_Kernel_OpenSource` 的 **`dada-v-oss`** 分支只有 6.6.30
  （2025-03-14，基于 `qcom-LA.VENDOR.15.4.0.r1-08900-r1.0.r1_00022.1`），
  **Android 16/17 的内核源码小米尚未公开（未找到）**，不能单独作为 6.6.118 基座。
  精确基座应使用：ACK 分支 **`android15-6.6-2026-01`**（kernel_version=6.6.118，
  r1 commit `f9c84f40b6ba6152b6f51daba0193c9564af4172`，2026-01-12），
  再叠加 Xiaomi `dada-v-oss` 的 vendor 配置/驱动差异；Xiaomi 官方工具链为
  AOSP clang **r510928**（`build.config.constants`：`CLANG_VERSION=r510928`），
  `KMI_GENERATION=8`（对应 release 串里的 `android15-8`），
  构建配置为 `build.config.msm.sun` + `build.config.msm.perf`（`DEFCONFIG=gki_defconfig`）。
  详见 BUILD-MODULES.md §2。

### 4.2 六个补丁的处理方式

| 补丁 | 处理方式（6.12 → 6.6） |
|---|---|
| 0001 三方合并 wondertap/PASSTHRU | **重新做**：用 `driver/port-scripts/resolve_conflicts.py` + `merge_*.py` 辅助，把 houji（6.1）→ pandora（6.12）的改动按 6.6 的 HDD/DP/WMA API 重新落位。这是整个移植工作量最大的一步。 |
| 0002 策略管理器 next-action 表 | 直接移植，枚举/表结构在 6.6 同名，冲突通常很小 |
| 0003 适配 pandora API、桩掉 `cnss_get_wlan_tsf_gpio` | 需要重新确认 6.6 下这些 API 是否存在；`cnss_get_wlan_tsf_gpio` 在 haotian 的原厂 cnss2 里是否导出用 `grep` 确认，若无则同样桩掉 |
| 0004 PT 调试/调优参数（pt_lowpower_off、pt_sync_lmac、pt_force_tid、pt_tsf、pt_ch_hop） | 纯逻辑，冲突少，注意 6.6 的 WMI/日志 API 差异 |
| 0005 TX bank A/B | 依赖 0004 的诊断接口，按 6.6 适配 |
| 0006 vendor 信道调度 | 依赖 6.6 的 WMI 信道 API，注意 11be 请求接口差异 |
| 0007 PT 远端对端生命周期加固 | 纯 DP/HDD 逻辑加固，建议完整保留（它消除了已知的固件断言 SSR 触发路径） |

做法建议（在 Linux 上）：

```sh
git clone -b dada-v-oss https://github.com/MiCode/vendor_qcom_opensource_wlan wlan-6.6
git clone -b dada-v-oss https://github.com/MiCode/Xiaomi_Kernel_OpenSource kernel-6.6
cd wlan-6.6 && git am /path/to/pandora-airdrop/driver/patches/0001-*.patch   # 大量冲突
# 逐个冲突用 port-scripts 里的脚本处理，编译反馈驱动修正（见 BUILD-MODULES.md §3/§4）
```

### 4.3 构建细节（与上游一致的部分）

* 内核树需要 `KBUILD_GENDWARFKSYMS_STABLE=1`，保证导出符号 CRC 稳定；
* 手机 vendor 的 cfg80211/mac80211 开了 `CONFIG_NL80211_TESTMODE`（ops 表多 0x10 字节），
  vendor 模块编译时必须同样定义；
* vendor 模块需要模拟混合构建：`vendor_defines.h`（由 SoC 仓库的 `*_perf.bzl` 生成）、
  vendor 专用头文件、`EXTENDED_MODVERSIONS` 相关配置；
* 编译后用 `tools/kocrc.py` 把模块导入符号的 CRC 与手机导出值逐一比对，全一致才可加载。

---

## 5. 关键机制：vermagic 与符号 CRC

上游 release 里的模块 vermagic 是：

```
6.12.69-4k-gcf67c9a888dc SMP preempt mod_unload modversions aarch64
```

而手机内核 `uname -r` 是 `6.12.69-android16-6-g43b5ab7e247d-abogki561813157-4k`——
两者 **UTS_RELEASE 不同**，模块却能加载。原因在 `kernel/module/main.c` 的 `same_magic()`：
**当模块带 `__versions`（CONFIG_MODVERSIONS）时，内核只比较 vermagic 第一个空格之后的部分**
（`SMP preempt mod_unload modversions aarch64`），UTS 不参与比较。

实机 .config 进一步确认（2026-11-22 采集）：haotian 的 6.6.118 内核是 **经典 genksyms +
MODVERSIONS**（没有 `GENDWARFKSYMS` / `EXTENDED_MODVERSIONS`），开了 `CFI_CLANG`、
`SHADOW_CALL_STACK`、`KASAN`、`UBSAN`、`TRIM_UNUSED_KSYMS`，且**没有** `NL80211_TESTMODE`
（与 pandora 相反）。因此模块必须按这份 .config 用 Kbuild 正常编译（自动带 CFI/SCS/KASAN/UBSAN
flags），不要照搬 pandora 的 `KBUILD_GENDWARFKSYMS_STABLE` / `EXTENDED_MODVERSIONS` /
`NL80211_TESTMODE` 参数。

所以 haotian 的模块：

* 不要求 UTS_RELEASE 等于手机 `uname -r`（这也意味着不能靠"改 UTS 字符串"糊弄过去）；
* **必须**满足：
  1. vermagic 配置后缀一致（本工程 `device/haotian.env` 的 `EXPECTED_VERMAGIC_SUFFIX`，
     以实机原厂模块的 vermagic 为准）；
  2. 模块导入的每个符号的 CRC 与手机内核/厂商模块的导出值一致（这是真正的门槛）；
  3. 符号 namespace 在编译期满足（modpost）。
* 本工程的 `verify-modules.mjs` / 安装器都只比较配置后缀，并额外核对 CRC 流程（§6）。

---

## 6. 符号 CRC：已从实机模块提取（2026-11-22）

`tools/ko-crc-extract.mjs` 解析厂商 `.ko` 的 ELF：

* `__versions`：模块**导入**符号的 CRC（等于手机内核/厂商模块的导出值）；
* 符号表里的 `__crc_<symbol>`（`__kcrctab` 区）：模块**导出**符号的 CRC
  （兼容“合并 `__ksymtab`”与“每符号 `___ksymtab+<name>`”两种布局）。

已用 root 采集模块（`dist/haotian-dump-collector.zip`）把三个原厂 `.ko` 拉到 PC 并提取完成，
结果在 **`driver/haotian-phone-data/`**：

| 文件 | 内容 |
|---|---|
| `phone-crcs.txt` | 1202 条 `crc / symbol / import|export / file` 记录 |
| `vendor.symvers` | 按 modpost `Module.symvers` 格式整理、按符号去重的片段（可直接追加到内核构建产物） |
| `PHONE-CRC-SUMMARY.md` | 统计、冲突检查、关键符号 CRC |

统计：原厂驱动 **584** 个导入符号；`cnss2.ko` **74** 导出 / 370 导入；`mhi.ko` **61** 导出 / 113 导入；
同名符号 CRC **无冲突**。其中：

* `mhi_bdf_to_controller` 由 `mhi.ko` 导出（CRC `0x9c26d2b3`）→ `xos_mhi_fw.ko` 可以按原设计调用；
* `cnss_get_wlan_tsf_gpio` **没有**被 cnss2 导出、也没有模块导入它 → 补丁 0003 里的桩必须保留；
* `cnss_set_vendor_wonder_priv_data` / `cnss_wonder*` 在 cnss2 的导出与导入表里都不存在 →
  原厂完全没有 wonder 支持，本项目自带的 bridge/wonder 不依赖这些符号。

构建时仍建议“**内核编译产出的 Module.symvers + 本 vendor.symvers 合并**”：
内核导出的符号 CRC 由同 `.config` 的内核树生成（经典 genksyms，可复现），
厂商侧（cnss2/mhi）CRC 用实机提取值补齐；合并脚本见 BUILD-MODULES.md §6。

> 提醒：不同 haotian 系统版本的模块 CRC 不同；OTA 后必须重新采集（跑 collector 或从新 ROM 提取）。
> 本工程的 `calibration.env` 会在开机时发现原厂驱动/固件变化并自动停用，避免加载旧 CRC 模块。

---



## 7. `xos_mhi_fw.ko` 的偏移量：已从实机 `mhi.ko` 推导

haotian 的 `mhi.ko`（sha256 `6ddee09c…`）自带 `.BTF`（`CONFIG_DEBUG_INFO_BTF_MODULES=y`）。
用 split-BTF 解析 + 对 `mhi_alloc_bhie_table` / `mhi_free_bhie_table` /
`mhi_prepare_for_power_up` / `mhi_fw_load_handler` 的反汇编交叉验证，得到：

| 字段 | haotian 6.6 | pandora 6.12（上游） |
|---|---|---|
| `rddm_size` | +0x70 | +0x78 |
| `sbl_size` | +0x78 | +0x80 |
| `seg_len` | +0x80 | +0x88 |
| `fbc_image` | +0x90 | +0x98 |
| `rddm_image` | +0x98 | +0xa0 |
| `img_pre_alloc` | **+0x294** | +0x264 |
| `image_info.entries` | +0x10 | +0x10 |

`driver/mhi_fw/xos_mhi_fw.c` 的 offset 宏**已按 haotian 值写好**；
完整推导记录（含 BTF 结构、反汇编证据、复现命令）见
`driver/haotian-phone-data/MHI-OFFSETS.md`。

**降级方案不可用**：原厂 `amss20.bin` 只有 6,930,496 B，比 S26U 的 7,364,672 B 小
434,176 B，换固件一定会超过 FBC 缓冲区，所以 `xos_mhi_fw.ko` 是必须的。

---



## 8. 用户态适配（本仓库已完成）

| 文件 | 改动 |
|---|---|
| `module/common.sh` | 设备配置加载、驱动/固件/PCI 实机探测、`calibration.env` 校准、设备报告 |
| `module/customize.sh` | 机型/SDK/内核白名单、4 个 `.ko` 的 vermagic 后缀校验、校准、APK 签名冲突处理、空间检查 |
| `module/service.sh` | OTA 保护、校准校验、运行时重试、supervisor 指数退避、inotifyd 事件驱动 |
| `module/action.sh` | 会话恢复 + 校准/驱动诊断输出 |
| `module/uninstall.sh` | 改名后的 `xos_*` 模块清理、校准清理 |
| `runtime/radio.sh` | 全部设备节点参数化；无界循环加超时；失败必回滚；MHI 可降级 |
| `runtime/bridge-supervisor.sh` | 包名/SELinux 域参数化（platform_app/36/37 都放行）；失败明确退出 |
| `device/haotian.env` | 目标内核、驱动候选、固件候选、vermagic 后缀、小米互传版本、AWDL 参数 |

---

## 9. 实机验证清单（按顺序）

1. `insmod xos_wonder_bridge.ko` → `insmod wonder.ko synthetic_provider=1` →
   `insmod xos_mhi_fw.ko`，`cat /proc/sys/net/wonder/wonder_enable` 应为 1；
2. `radio.sh idle` 返回 `IDLE_READY`，小米互传里**出现**「与Apple设备互传」入口；
3. 打开该界面 → `radio.sh enter`，`cat $W/parameters/pt_activate` 到 phase=3、freq=5745；
4. iPhone 隔空投送看到本机 → 传一张照片（先小后大）；
5. Live Photo 是否合成为动态照片（看小米相册）；
6. 退出界面/锁屏 → 5 秒内恢复原厂 Wi-Fi 并自动重连；
7. 断网/异常路径：kill XosBridge、断 Wi-Fi、拔 SIM，确认 `radio.sh restore` 均能恢复；
8. OTA 保护：改一个原厂驱动/固件哈希后重启，确认模块说明变成 "[⚠ 已自动停用：…]"；
9. 功耗：待机 10 分钟 `top`/`/proc/stat` 对比开/关模块，确认无持续 CPU 占用。

任一步失败，先重启手机（不修改分区，重启必恢复原厂 Wi-Fi），保留
`/data/local/tmp/xos/native/module.log`、`/data/local/tmp/xos/owly/state/radio.log`、
`dmesg` 后再排查。

---

## 10. 未验证项 / 风险

已通过实机采集消除：驱动名/路径/哈希、固件路径/大小/哈希、cnss2/mhi 导出符号、
wonder 支持状况、CRC 表、MHI 偏移、小米互传版本、内核 .config。

仍未验证：

* 三星 S26U 固件在 haotian 的 peach 硬件上能否正常加载/工作（同芯片族，但未实测）；
* 6.6 树上的 0001–0007 补丁移植未经编译（需要 Linux + 迭代调试）；
* 小米互传 5.5.0 的混淆类名/回调签名是否与 5.4.1 相同（兼容模块做了候选类 + 失败降级，
  最多失去 Live Photo 合成，不影响 Wi-Fi 伪装与接收）；
* `xos_mhi_fw.ko` 的偏移虽来自实机 BTF/反汇编，但清除 img_pre_alloc 后的实际效果
  仍需在真机 `insmod` + 换固件场景验证；
* 小米 15 Pro 是否会被官方 OTA 直接支持原生 AirDrop 未可知；若官方支持，优先用官方功能。
