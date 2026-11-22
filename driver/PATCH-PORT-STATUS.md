# 驱动补丁移植状态（0001–0007 → 6.6 / dada-v-oss）

统计（`git apply --numstat`，2026-11-22）：

| 补丁 | 文件数 | + | − | 说明 |
|---|---|---|---|---|
| 0001 port houji wondertap/PASSTHRU onto pandora（6.12 三方合并） | 120 | 16018 | 1062 | 工作量最大，需要重放到 6.6 WLAN 树 |
| 0002 policy next-action 表 | 2 | 4 | 0 | 直接可用 |
| 0003 适配 pandora API / 桩掉 cnss_get_wlan_tsf_gpio | 11 | 40 | 22 | 保留桩（实机确认 cnss2 未导出该符号） |
| 0004 PT 诊断/低功耗/信道跳变接口 | 5 | 220 | 1 | 逻辑为主 |
| 0005 PT TX bank A/B | 5 | 46 | 2 | 依赖 0004 |
| 0006 PT vendor 信道 | 1 | 25 | 5 | 依赖 0003/0004 |
| 0007 PT 远端对端生命周期加固 | 4 | 244 | 90 | 完整保留（消除已知 SSR 诱因） |

## 目标源码树

* WLAN：MiCode `vendor_qcom_opensource_wlan` 的 **`dada-v-oss`** 分支
  （head `0e5909a0…`，2025-03-14；含 `haotian-peach-cnss-v8.dts`、
  `sun_gki_peach-v2_defconfig`；全树 grep `passthru|wonder|wondertap|pt_` = 0 命中）。
* 内核：ACK `android15-6.6-2026-01`（6.6.118）+ 手机 `.config`；
  Xiaomi `dada-v-oss` 内核分支只作 vendor 配置参考（停在 6.6.30）。

## 0001 的移植方法（Linux 上）

0001 是 `git format-patch`，index 行引用的是 pandora(popsicle 6.12) 的 blob，
而本机没有那棵树，`git am -3` 无法直接三方合并。推荐流程：

```sh
# 1. 拿到 dada-v-oss 的 WLAN 树
git clone -b dada-v-oss --depth 1 https://github.com/MiCode/vendor_qcom_opensource_wlan wlan-6.6
cd wlan-6.6 && git checkout -b haotian-pt

# 2. 用 GNU patch 带 merge，先整体落一遍，收集冲突
patch -p1 --fuzz=3 --merge < /work/driver/patches/0001-*.patch

# 3. 冲突文件里会有 <<<<<<< / >>>>>>> 标记；按 6.6 的 HDD/DP/WMA API 修正
#    （可参考 driver/port-scripts/ 下的 merge_*.py / resolve_conflicts.py 的处理思路）
grep -rl '^<<<<<<<' . | tee /tmp/0001-conflicts.txt

# 4. 0002-0007 再用 git apply / patch 应用（体积小，接口差异少）
for p in /work/driver/patches/000[2-7]-*.patch; do
  git apply --check "$p" && git apply "$p" || echo "需要手工: $p"
done

# 5. 编驱动（见 BUILD-MODULES.md §4/§5）
```

编译迭代时优先看：

* `con_driver` / `hdd` / `wma` / `dp` 的 6.6 API 重命名与参数变化；
* `cfg80211/mac80211` vendor 头文件（手机 .config 无 `NL80211_TESTMODE`，与 pandora 相反）；
* `pt_*` sysfs 节点与 `pt_remote_peer_ctl` 的接口在 6.6 下的首次编译错误。

## 三个小模块（wonder / bridge / mhi）

* `wonder.ko`：独立 mac80211 驱动，源码完整，预计只需按 6.6 `cfg80211/mac80211` 头文件做少量适配；
* `xos_wonder_bridge.ko`：只依赖标准 platform device API，基本无适配；
* `xos_mhi_fw.ko`：偏移已按实机 `mhi.ko` BTF/反汇编写好
  （`driver/haotian-phone-data/MHI-OFFSETS.md`），`mhi_bdf_to_controller` 确认已导出。

## 当前阻塞

本机（Windows）没有 Linux/gcc/clang，无法执行 Kbuild。需要一台 Linux
（或 WSL2/云主机）跑 `build/build-modules.sh`；脚本会自动使用已采集的
`build/phone/config.gz` 与 `driver/haotian-phone-data/vendor.symvers`。
