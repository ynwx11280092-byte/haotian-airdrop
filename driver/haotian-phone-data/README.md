# haotian 实机内核模块数据（离线提取）

这些文件来自用户自己的小米 15 Pro（haotian / OS4.0.4.0.XOBCNXM / 内核 6.6.118）上
的原厂 `.ko`，用于在 Linux 上为用户自己的内核编译 4 个移植模块：

- `phone-crcs.txt`：原厂 qca_cld3_peach_v2 / cnss2 / mhi 三个模块的导入+导出符号 CRC 清单
  （`crc<TAB>symbol<TAB>import|export<TAB>file`），由 `tools/ko-crc-extract.mjs` 生成；
- `vendor.symvers`：按 modpost `Module.symvers` 格式整理后的片段（可直接与内核构建产物合并）；
- `PHONE-CRC-SUMMARY.md`：统计、冲突检查与关键符号（mhi_bdf_to_controller 等）。

**注意**：这些 CRC 只对上述系统版本/原厂模块有效；OTA 后必须重新采集（跑 `tools/preflight.sh` +
`haotian-dump-collector.zip`，或在 Linux 上从新 ROM 的 vendor_dlkm 提取）。

