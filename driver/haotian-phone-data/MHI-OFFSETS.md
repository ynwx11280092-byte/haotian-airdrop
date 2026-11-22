# haotian mhi.ko 结构体偏移（xos_mhi_fw.ko 用）

2026-11-22 从手机（小米 15 Pro / OS4.0.4.0.XOBCNXM / 内核 6.6.118）拉取的
`/vendor_dlkm/lib/modules/mhi.ko`（sha256 `6ddee09c…`）中提取。

方法（两条互相印证）：

1. **模块自带 .BTF**（`CONFIG_DEBUG_INFO_BTF_MODULES=y`）：`.BTF` 是 split-BTF，
   先用 `__crc_<sym>` 与已知字段名反推出 base 字符串表长度 2,551,730，
   再解析本地类型。得到：
   * `struct mhi_controller` size=680，字段偏移见下表；
   * `struct image_info` size=24：`mhi_buf +0x00`、`bhi_vec +0x08`、`entries(u32) +0x10`。
2. **反汇编**（`mhi_alloc_bhie_table` / `mhi_free_bhie_table` /
   `mhi_prepare_for_power_up` / `mhi_fw_load_handler`）确认这些字段确实被用作预期用途：
   * `mhi_free_bhie_table`: `ldrb w8,[x0,#0x294]`（img_pre_alloc）为空则直接返回；
   * `mhi_alloc_bhie_table`: 同样先检查 `+0x294`；
   * `mhi_prepare_for_power_up`: 引用 `+0x80`（seg_len）、`+0x90`（fbc_image）、
     `+0x98`（rddm_image）、`+0x296`（fbc_download）；
   * `mhi_fw_load_handler`: 引用 `+0x78/+0x80/+0x90` 等；
   * `mhi_bdf_to_controller`: 内部用格式串 `mhi_%04x_%02u.%02u.%02u` 构造设备名，
     与手机 sysfs 的 `mhi_110e_00.01.00` 吻合 → 签名是
     `mhi_bdf_to_controller(u32 domain, u32 bus, u32 slot, u32 dev_id)`，调用取 `(0,1,0,0x110e)`。

## struct mhi_controller（haotian，size 680）

| 偏移 | 字段 | 类型 | 说明 |
|---|---|---|---|
| +0x50 | fw_image | base PTR | `const struct firmware *` |
| +0x58 | fw_data | base PTR | |
| +0x60 | fw_sz | base#35 | |
| +0x70 | rddm_size | base#35 | 64 位，用于 sanity |
| +0x78 | sbl_size | base#35 | |
| +0x80 | seg_len | base#35 | sanity：必须是 4K–16M 的 2 的幂 |
| +0x90 | fbc_image | PTR → struct image_info | |
| +0x98 | rddm_image | PTR → struct image_info | |
| +0x288 | buffer_len | base#35 | |
| +0x294 | img_pre_alloc | bool | **本模块清除的字段** |
| +0x296 | fbc_download | bool | 诊断输出 |

## struct image_info（size 24）

| 偏移 | 字段 | 说明 |
|---|---|---|
| +0x00 | mhi_buf | `struct mhi_buf_info *` |
| +0x08 | bhi_vec | |
| +0x10 | entries | u32，BHIe/fbc 条目数（`fbc_capacity = (entries-1) * seg_len`） |

## 与 pandora(6.12) 的差异

| 字段 | pandora 6.12 | haotian 6.6 |
|---|---|---|
| rddm_size | 0x78 | **0x70** |
| sbl_size | 0x80 | **0x78** |
| seg_len | 0x88 | **0x80** |
| fbc_image | 0x98 | **0x90** |
| rddm_image | 0xa0 | **0x98** |
| img_pre_alloc | 0x264 | **0x294** |
| image_info.entries | +0x10 | +0x10（相同） |

`driver/mhi_fw/xos_mhi_fw.c` 已按本表写入 offset 宏；换内核/OTA 后请重新提取。

## 复现命令

```sh
# 1) 在手机 root 环境下把 mhi.ko 拉到 PC（collector 模块会自动做）
# 2) .BTF / 反汇编（PC 上，Node + capstone-wasm）
node tools/btf-dump.mjs build/phone/mhi.ko            # 结构体总览
node tools/ko-disasm.mjs build/phone/mhi.ko --func mhi_free_bhie_table
node tools/ko-disasm.mjs build/phone/mhi.ko --func mhi_prepare_for_power_up
```
