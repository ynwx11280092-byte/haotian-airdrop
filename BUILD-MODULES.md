# 内核模块构建指南（haotian / 6.6.118）

本文件是让 4 个内核模块能在小米 15 Pro（HyperOS OS4.0.4.0，内核
`6.6.118-android15-8-gf72a02f47f4b-abogki551678766-4k`）上 `insmod` 的完整步骤。

先读 [PORTING.md](PORTING.md) 了解"为什么必须重编"和"先要实机确认什么"。

---

## 0. 前置条件

* **Linux x86_64**（推荐 Ubuntu 24.04；也可用 `build/Dockerfile`）
* 16 GB 内存 + 50 GB 磁盘（完整内核编译）；只编模块约需 20 GB
* `build-essential git curl wget python3 python3-pip perl bc flex bison cpio rsync lz4
  xz-utils libssl-dev libelf-dev dwarves zstd device-tree-compiler clang lld llvm nodejs`
* 一台能 root 的小米 15 Pro（KernelSU），用来导出 `.config`、拉厂商模块、做加载测试
* 可选：`tools/ko-crc-extract.mjs`（本机 Node 即可运行）

```sh
# 在项目根目录
docker build -t haotian-build build/
docker run --rm -it -v "$PWD:/work" haotian-build bash
```

---

## 1. 采集手机侧输入

> 2026-11-22 已在该用户实机完成 v1 采集，结果已写入 `device/haotian.env` 的
> `KNOWN_STOCK_*`：内核 `6.6.118-android15-8-gf72a02f47f4b-abogki551678766-4k`；
> 驱动 `qca_cld3_peach_v2.ko`（sha256 `86d56305…`，build-id `ece9daf2…`，
> vermagic 的 UTS 是 `6.6.57-android15-8-4k`）；固件 `amss20.bin` 6,930,496 B
> （sha256 `90e365a5…`），同目录另有 `amss.bin` 7,000,128 B；小米互传 5.5.0（vc 50500）；
> wonder/PASSTHRU 支持为 0。
>
> **已全部采集完成（2026-11-22）**：`/proc/config.gz` 与三个厂商 `.ko` 已通过
> `dist/haotian-dump-collector.zip`（临时 root 采集模块，装完可在管理器卸载）拉到 PC。
> 本机产物在 `build/phone/`（本地，不随源包分发）与 `driver/haotian-phone-data/`（随源包分发）：
> `phone-crcs.txt`、`vendor.symvers`、`PHONE-CRC-SUMMARY.md`、`MHI-OFFSETS.md`。
> 换机/OTA 后需要重跑同一流程（collector 模块或 root 终端里的 `tools/preflight.sh` v2）。

在电脑上（有 adb、手机已 root）：

```sh
mkdir -p build/phone
# 1) 内核 .config（最关键）
adb shell su -c 'cat /proc/config.gz' > build/phone/config.gz
#    若无 /proc/config.gz：
#    adb pull /dev/block/by-name/boot 或从系统 ROM 的 boot.img 里用
#    scripts/extract-ikconfig 提取（ack-6.6/scripts/extract-ikconfig boot.img > config）

# 2) 厂商内核模块（CRC 提取 + 驱动名核对 + mhi 偏移反汇编）
adb shell su -c 'ls -l /vendor_dlkm/lib/modules/' > build/phone/modules.txt
for f in cnss2.ko qca_cld3_peach_v2.ko qca_cld3_peach.ko mhi.ko; do
  adb shell su -c "test -f /vendor_dlkm/lib/modules/$f" >/dev/null 2>&1 && \
    adb pull "/vendor_dlkm/lib/modules/$f" build/phone/
done
#    mhi 可能是内置的：adb shell su -c "find / -name 'mhi*.ko' 2>/dev/null"

# 3) 原厂 WLAN 固件（哈希/大小，判断 MHI 是否需要）
adb shell su -c 'sha256sum /vendor/firmware_mnt/image/peach/amss20.bin' > build/phone/fw.sha256
adb shell su -c 'ls -l /vendor/firmware_mnt/image/peach/' >> build/phone/fw.sha256

# 4) 完整 preflight 报告 + 厂商模块 dump（v2）
adb push tools/preflight.sh /data/local/tmp/
adb shell su -c 'sh /data/local/tmp/preflight.sh'
adb pull /sdcard/Download/haotian-airdrop-preflight.txt build/phone/
adb pull /sdcard/Download/haotian-dump build/phone/
```

把 preflight 输出的这些值填进 `device/haotian.env`（如果和默认值不同）：

* `DRIVER_CANDIDATES` / `DRIVER_KO_CANDIDATES`（原厂驱动模块名）
* `FW_CANDIDATES`（原厂固件路径）
* `EXPECTED_VERMAGIC_SUFFIX`（用原厂 `.ko` 里的 `vermagic=` 第一个空格之后的部分；
  v1 的脚本只截到第一个空格，v2 才会打印完整 vermagic）

```sh
# 读原厂模块的 vermagic / 导出的符号 CRC
node tools/ko-crc-extract.mjs --vermagic build/phone/*.ko
node tools/ko-crc-extract.mjs --all build/phone/cnss2.ko build/phone/qca_cld3_peach_v2.ko \
  > build/phone/phone-crcs.txt
```

**实机注意**：原厂 WLAN 驱动的 vermagic UTS 是 `6.6.57-android15-8-4k`（Xiaomi 的
vendor 模块没有跟着内核升级到 6.6.118 重编），但它在 6.6.118 内核上能加载 ——
说明 kernel 侧 CRC 在 KMI generation 8 内是稳定的，而 **vendor 侧（cnss2 等）的 CRC
必须从手机里的 `cnss2.ko` 提取**，不能靠自己编内核猜。

---

## 2. 准备源码树

```sh
mkdir -p build/src && cd build/src

# 内核基座：ACK android15-6.6-2026-01（kernel_version=6.6.118）
#   手机实机 release: 6.6.118-android15-8-gf72a02f47f4b-abogki551678766-4k
#   先在该分支里找 g-hash gf72a02f47f4b：
#     https://android.googlesource.com/kernel/common/+/gf72a02f47f4b
#     （或 clone 后 git rev-parse / git log 查找）
#   若它不是上游 ACK 提交（小米本地 patch 后重新构建也是可能的），就用
#   「同 sublevel 的 ACK + 手机 .config + 实机原厂模块 CRC」：KMI generation 8
#   的导出 CRC 稳定，vendor 侧 CRC 从手机模块提取（见 §1）。
#   该分支 release tag 例如 android15-6.6-2026-01_r1
#   （commit f9c84f40b6ba6152b6f51daba0193c9564af4172，2026-01-12，bid 14657223）
git clone https://android.googlesource.com/kernel/common ack-6.6
cd ack-6.6 && git checkout android15-6.6-2026-01_r1 && cd ..
# 或清华镜像：
#   git clone https://mirrors.tuna.tsinghua.edu.cn/git/AOSP/kernel/common ack-6.6

# Xiaomi vendor 侧：MiCode/Xiaomi_Kernel_OpenSource 的 dada-v-oss
# （注意：该分支停留在 6.6.30/2025-03，Android 16/17 的内核源码小米尚未公开；
#  它只用于提供 sun/dada 的 vendor 配置与驱动差异，不能单独作为 6.6.118 基座）
git clone -b dada-v-oss --depth 1 https://github.com/MiCode/Xiaomi_Kernel_OpenSource xiaomi-6.6

# WLAN 源码：MiCode/vendor_qcom_opensource_wlan 的 dada-v-oss
# 已确认其中含 haotian 的板级证据：
#   wlan-devicetree/haotian-peach-cnss-v8.dts（model "Haotian based on SM8750"）
#   sun-peach-cnss-v8.dtsi（qcom,cnss-peach）、fw-api/hw/peach/v1、
#   peach_defconfig，以及 profile: sun_gki_peach-v2_defconfig / sun_gki_peach_defconfig
git clone -b dada-v-oss --depth 1 https://github.com/MiCode/vendor_qcom_opensource_wlan wlan-6.6
```

> 国内网络可用镜像前缀（任选其一，拼在 GitHub URL 前）：
> `https://gh-proxy.com/`、`https://ghfast.top/`；或先下载 codeload tarball。
> AOSP 源可用清华镜像（上面示例）。仓库较大（ACK 内核 ~2–3 GB），请预留时间。

**内核版本对齐检查**：

```sh
make -s -C ack-6.6 kernelversion        # 必须是 6.6.118
```

**实机内核 .config 已采集**（2026-11-22，本地存档 `build/phone/config.txt`，来自手机 `/proc/config.gz`），
与 pandora(6.12) 的关键差异（直接影响编译参数）：

| 配置 | 值 | 对移植的影响 |
|---|---|---|
| `CONFIG_MODVERSIONS` | y | 符号 CRC 校验开启（与上游一致） |
| `CONFIG_EXTENDED_MODVERSIONS` | **未设置** | modversion 条目是经典 `unsigned long crc + char name[56]`（64 字节） |
| `CONFIG_GENDWARFKSYMS` | **未设置** | **和 pandora 6.12 不同**：不要设 `KBUILD_GENDWARFKSYMS_STABLE=1`，这里走经典 genksyms，CRC 由源码 + `.config` 决定 |
| `CONFIG_CFI_CLANG` / `CONFIG_SHADOW_CALL_STACK` / `ARM64_PTR_AUTH/BTI` | y | 模块必须按同一内核树/配置编，Kbuild 会自动带 CFI/SCS/PAC/BTI flags |
| `CONFIG_KASAN` / `CONFIG_UBSAN` | y | 同上，模块会带 KASAN/UBSAN instrumentation，用 Kbuild 正常编即可 |
| `CONFIG_TRIM_UNUSED_KSYMS` + `CONFIG_UNUSED_KSYMS_WHITELIST="abi_symbollist.raw"` | y | 导出符号有裁剪；补丁新增调用若不在 KMI/白名单，insmod 会 Unknown symbol，需用 root 下 `/proc/kallsyms` 确认 |
| `CONFIG_MODULE_SIG` | y（`SIG_FORCE` 未开） | 未签名/自签名模块可以加载（会 taint），KernelSU/SukiSU 环境正常 |
| `CONFIG_NL80211_TESTMODE` | **未设置** | **与 pandora 相反**：编驱动时不要定义 TESTMODE，否则 ops 偏移错位 |
| `CONFIG_PREEMPT` / `SMP` / `LOCALVERSION="-4k"` / `LOCALVERSION_AUTO=y` | — | 推出 vermagic 后缀 = `SMP preempt mod_unload modversions aarch64`（与 device/haotian.env 一致） |

所以本机路线是：**用与手机一致的 .config 在 ACK 6.6.118 树上编（genksyms CRC 可复现），
vendor 侧（cnss2 等）CRC 从手机模块提取**；不要照搬 pandora 的 EXTENDED_MODVERSIONS /
GENDWARFKSYMS 参数。

---

## 3. 移植 WLAN 驱动补丁

补丁规模与移植状态见 **`driver/PATCH-PORT-STATUS.md`**（0001 涉及 120 个文件 / +16018 −1062，
0002–0007 共 28 个文件、很小）。0001 是 `git format-patch`，index 行引用 pandora(6.12) 的 blob，
本机没有那棵树，`git am -3` 无法三方合并；用 GNU patch 带 merge 更实际：

```sh
cd wlan-6.6
git checkout -b haotian-pt
patch -p1 --fuzz=3 --merge < /work/driver/patches/0001-port-houji-wondertap-passthru-onto-pandora-via-3-way.patch
#   冲突文件里会有 <<<<<<< / >>>>>>>；按 6.6 的 HDD/DP/WMA API 修正
#   可参考 /work/driver/port-scripts/ 的处理思路：
#     resolve_conflicts.py / merge_wma_hdd.py / merge_dp_tx.py / merge_dp_be_tx.py
#     merge_hdd_vdev_destroy.py / fix_api.py / fix_kbuild.py
# 0002-0007 逐个 apply，遇到 6.6 API 差异手工修
for p in /work/driver/patches/000[2-7]-*.patch; do
  git apply --check "$p" && git apply "$p" || echo "需要手工处理: $p"
done
```

移植目标（与上游一致）：

* PT 参数齐全：`pt_exclusive pt_zero_serial pt_rx_metadata pt_rx_msdu_buf pt_rx_ezif_marked
  pt_remote_multi pt_remote_assoc pt_remote_ast_override pt_remote_hash_override pt_remote_reo
  pt_remote_rx_window pt_rate_observe pt_single_ring pt_sync_lmac pt_vendor_chan
  pt_dynamic_rate pt_vht80 pt_vht80_2ss pt_tx_ampdu pt_rx_capacity_4224`；
* `pt_remote_peer_ctl`、`pt_activate`、`pt_release` 三个 sysfs 节点可用；
* 驱动模块名保持 `qca_cld3_peach_v2.ko`（与原厂一致，wlan 加载路径/固件名依赖它）。

---

## 4. 编译内核树（生成 Module.symvers）

```sh
cd /work
KERNEL=build/src/ack-6.6
KOUT=build/kernel-out
mkdir -p $KOUT
cp build/phone/config.gz - | gunzip > $KOUT/.config

# 注意：本机内核没有 CONFIG_GENDWARFKSYMS，不需要 KBUILD_GENDWARFKSYMS_STABLE；
# CRC 由经典 genksyms 按「源码 + .config」计算，必须用手机同款 .config。
export LOCALVERSION=-4k
make -C $KERNEL O=$KOUT ARCH=arm64 LLVM=1 olddefconfig
# 核对关键配置（与手机一致）：
grep -E 'CONFIG_(MODVERSIONS|EXTENDED_MODVERSIONS|GENDWARFKSYMS|CFI_CLANG|NL80211_TESTMODE)=' $KOUT/.config

# 完整编译（1–4 小时）
make -C $KERNEL O=$KOUT ARCH=arm64 LLVM=1 -j"$(nproc)" Image modules
```

> 更接近官方的做法：把 Xiaomi `dada-v-oss` 里的 vendor 配置 fragment
> （`arch/arm64/configs/vendor/{sun,dada}_perf.config` 等）叠加到 ACK 的
> `gki_defconfig` 上，再以手机 `.config` 为准 `olddefconfig`；也可以按 Xiaomi 的
> `build.config.msm.perf`（`DEFCONFIG=gki_defconfig`、混合构建）用 Kleaf 流程
> 构建 `kernel-dist`/`vendor_dlkm`。核心要求不变：`ARCH=arm64 LLVM=1`、
> **clang r510928**、`KMI_GENERATION=8`，且导出符号 CRC 与手机一致。
> （本机无 `CONFIG_GENDWARFKSYMS`，不要加 `KBUILD_GENDWARFKSYMS_STABLE`。）

**合并实机提取的厂商符号 CRC（构建 4 个模块前必须做）**：

```sh
# driver/haotian-phone-data/vendor.symvers 是按 modpost 格式整理的 cnss2/mhi 厂商符号 CRC。
# 把它里面“内核构建产物没有的符号”追加进 Module.symvers，避免 modpost 报 undefined。
VENDOR=/work/driver/haotian-phone-data/vendor.symvers
if [ -f "$VENDOR" ]; then
  awk -F'\t' 'NR==FNR{seen[$2]=1; print; next} !seen[$2]' \
    "$KOUT/Module.symvers" "$VENDOR" > "$KOUT/Module.symvers.merged"
  mv "$KOUT/Module.symvers.merged" "$KOUT/Module.symvers"
  echo "merged vendor symvers: $(wc -l < "$KOUT/Module.symvers") symbols"
fi
```

若内存不足（LTO/CFI 链接 OOM）：`CONFIG_LTO_CLANG_THIN=y` 加 `J=1` 链接、或给机器加 swap。
如果只走"CRC 提取"路线（PORTING.md §6-B），可以先跳过这一步，改为：

```sh
make -C $KERNEL O=$KOUT ARCH=arm64 LLVM=1 modules_prepare
# 然后用 build/phone/phone-crcs.txt + driver/port-scripts/make_vendor_symvers.py
# 拼一个 vendor.symvers 给 modpost 用（缺失符号再回来编内核补齐）
```

---

## 5. 编译四个模块

### 5.1 wonder / xos_wonder_bridge / xos_mhi_fw（本项目源码，直接编）

```sh
K=$KERNEL; O=$KOUT
make -C $K O=$O ARCH=arm64 LLVM=1 M=/work/driver/wonder modules
make -C $K O=$O ARCH=arm64 LLVM=1 M=/work/driver/bridge modules
make -C $K O=$O ARCH=arm64 LLVM=1 M=/work/driver/mhi_fw modules
# 产物: driver/wonder/wonder.ko, driver/bridge/xos_wonder_bridge.ko, driver/mhi_fw/xos_mhi_fw.ko
```

说明：

* `wonder.ko`/PT 驱动依赖内核的 mac80211/cfg80211；**实机 .config 里没有
  `CONFIG_NL80211_TESTMODE`**（与 pandora 相反），编译时保持与手机一致即可，
  不要手工定义 TESTMODE，否则 cfg80211 ops 偏移错位；
* `xos_wonder_bridge.ko` 只依赖标准 platform device API，并导出 `cnss_wonder_*`
  给 PT 驱动和 wonder 用；
* `xos_mhi_fw.ko` 的偏移量已按 haotian 的 `mhi.ko` 推导好（`.BTF` + 反汇编，见
  `driver/haotian-phone-data/MHI-OFFSETS.md`）：`img_pre_alloc=0x294`、`fbc_image=0x90`、
  `rddm_image=0x98`、`rddm_size=0x70`、`sbl_size=0x78`、`seg_len=0x80`。直接编译即可；
  OTA 换内核后需重新提取。

### 5.2 qca_cld3_peach_v2.ko（WLAN 驱动，混合构建）

先确认原厂模块名（`tools/preflight.sh`）：WLAN 源码里同时存在
`sun_gki_peach-v2_defconfig`（peach_v2）与 `sun_gki_peach_defconfig`（peach）两套 profile，
具体用哪套由设备配置决定（pandora 的 UI 是 `canoe_gki_peach-v2`，同 SoC 的一加 13 实机是
`qca_cld3_peach_v2.ko`）。用错 profile 会得到不能用的模块。

按上游 `driver/README.md` 的"编译要点"：

1. 生成 `vendor_defines.h`：`driver/port-scripts/make_vendor_defines.py`。
   pandora 的输入是 SoC 仓库的 `canoe_perf.bzl`；haotian 没有公开的同名 bzl（未找到），
   改用 Xiaomi `dada-v-oss` 的构建配置推导：`build.config.msm.perf`、
   `arch/arm64/configs/vendor/{sun,dada}_perf.config`、`build.config.common`
   （KMI_GENERATION=8）里的宏，再以手机 `.config`/厂商头文件补齐；
2. `make_vendor_symvers.py` + `build/phone/phone-crcs.txt` 生成 vendor.symvers
   （手机原厂 `cnss2.ko` 导出 + 原厂 `qca_cld3_peach_v2.ko` 导入的 CRC，用
   `tools/ko-crc-extract.mjs` 提取）；
3. 把 vendor 头文件（cfg80211/mac80211 的 vendor 版）放进 `prepare_vendor_out.sh` 准备的输出目录；
4. 按 `wlan-6.6` 的 Kbuild 编译（注意它用 `MODNAME`/`WLAN_PROFILE` 决定模块名，
   `Android.mk` 里是 `qca_cld3_$(CHIPSET).ko`，需要把 profile 设为 `sun_gki_peach-v2`）：

```sh
cd build/src/wlan-6.6
make -C $KERNEL O=$KOUT ARCH=arm64 LLVM=1 M=$PWD \
  # 注意：不要加 CONFIG_NL80211_TESTMODE（本机内核未开） \
  WLAN_PROFILE=sun_gki_peach-v2 \
  ...（vendor defines/headers，参考 wlan 仓库 README）  modules
```

产物 `qca_cld3_peach_v2.ko`。

### 5.3 CRC 核对（必须做）

> 实机三个原厂模块的 CRC 已经提取好：`driver/haotian-phone-data/phone-crcs.txt`；
> 编完驱动后把它的导入符号 CRC 与这份表逐个比对即可（同名符号必须同 CRC）。

```sh
# 1) 用上游工具从手机符号表核对（tools/kocrc.py 的输入格式见其 docstring）
python3 tools/kocrc.py --help

# 2) 或者用本工程的纯 Node 工具直接看驱动导入符号的 CRC 值
node tools/ko-crc-extract.mjs --imports build/out/kernel-modules/qca_cld3_peach_v2.ko > my-imports.txt
#    与 build/phone/phone-crcs.txt 里同名符号逐一 diff；不一致的符号会 insmod 报
#    "disagrees about version of symbol ..."
```

---

## 6. 输出与打包

```sh
mkdir -p build/out/kernel-modules build/out/runtime build/out/compat
cp driver/wonder/wonder.ko driver/bridge/xos_wonder_bridge.ko \
   driver/mhi_fw/xos_mhi_fw.ko <驱动产物>/qca_cld3_peach_v2.ko \
   build/out/kernel-modules/

# 运行时二进制（在 Windows/任意机器上从上游 release 取）
#   tools/fetch-upstream.ps1 / .sh  → upstream/
cp upstream/owly-xosd upstream/wonder-init upstream/xos-bridge.zip build/out/runtime/
# 兼容 APK
cp compat/dist/Haotian-XOS-Compat.apk build/out/compat/

# 校验 + 打包
node tools/verify-modules.mjs --inputs build/out/kernel-modules --profile haotian
node tools/package.mjs --inputs build/out --upstream upstream --firmware /path/s26u-amss20.bin
```

---

## 7. 实机加载测试（不要直接刷模块包，先手动验证）

```sh
adb push build/out/kernel-modules/*.ko /data/local/tmp/
adb push build/out/runtime/* /data/local/tmp/xos-test/
adb shell su
cd /data/local/tmp
insmod xos_wonder_bridge.ko
dmesg | tail -5
insmod wonder.ko synthetic_provider=1
cat /proc/sys/net/wonder/wonder_enable          # 期望 1
insmod xos_mhi_fw.ko                            # 若布局不对，这里会失败
ls /sys/module/xos_mhi_fw/parameters/realloc   # 存在则 OK
# 卸载顺序：wonder -> 驱动(PT) -> bridge；mhi 可最后
```

只有 idle 三件套 + PT 驱动都能加载后，才去刷完整模块包；刷包后按 PORTING.md §9 逐项验证。

---

## 8. 常见错误对照

| dmesg / insmod 报错 | 原因 | 处理 |
|---|---|---|
| `invalid module format` / `version magic ... should be ...` | vermagic 配置后缀不一致，或模块没有 modversions 导致严格比较完整 UTS | 对齐 `EXPECTED_VERMAGIC_SUFFIX`；确认 `CONFIG_MODVERSIONS` 与手机一致 |
| `disagrees about version of symbol X` / `no symbol version for X` | 符号 CRC 不一致（内核配置/头文件/源码版本不符） | 用 kocrc.py / ko-crc-extract.mjs 逐符号核对；用手机 .config 与同 sublevel 源码重编 |
| `Unknown symbol X (err -2)` | 手机内核/厂商模块没有导出 X，或 namespace 未满足 | `grep X /proc/kallsyms`；必要时修改驱动绕开该 API |
| `module verification failed: signature...` | 模块签名 | KernelSU/LSPosed 环境下通常可加载；确认 CONFIG_MODULE_SIG_FORCE 未开 |
| `insmod: can't insert ... : Resource temporarily unavailable` | 模块已加载/被引用 | 按依赖顺序卸载；重启最稳 |
| 加载后 WiFi 掉线 | PT 驱动替代原厂驱动后 Wi-Fi 管理服务状态异常 | 重启；检查 `radio.sh restore` 是否成功执行 |
| 内核 panic / 固件断言（SSR） | 塞入更大固件时 MHI FBC 缓冲区溢出 | 必须处理 `xos_mhi_fw.ko`（PORTING.md §7），不要跳过 |

---

## 9. 维护建议

* 每次系统 OTA（哪怕只是小版本）都可能换内核/驱动/固件：重新跑 `tools/preflight.sh`，
  比对 `EXPECTED_KERNEL`、驱动/固件哈希；不一致就重新编模块。
* 把每版实机验证通过的 `.ko` 和 `MODULES.info` 留档（record SHA-256），
  以后可以填充进 `device/*.env` 的已知哈希做更强的安装校验。
* `driver/port-scripts/`、`driver/patches/` 里是上游移植过程的原样资料，
  遇到 6.6 与 6.12 API 差异时可先翻这些脚本找对应改法。
