# 三星 S26 Ultra WLAN 固件（需自备）

小米原厂 peach 固件不支持 PASSTHRU vdev，本项目会话期间临时改用三星 Galaxy S26 Ultra（SM-S948B，同为 SM8850 + FastConnect 7900/peach）的 `amss20.bin`。这份固件是三星/高通的闭源文件，**本仓库和发布的安装包都不包含它**，需要你自己从三星官方服务器取得。

| 项目 | 值 |
|---|---|
| 机型 / 地区 | SM-S948B / EUX |
| 固件版本 | S948BXXS6BZK1 |
| 文件 | vendor 分区 `firmware/peach/amss20.bin`（7,364,672 字节） |
| SHA-256 | `71fc5c2eb2df048b6c4b494564cfbef730db879a3d8b4426c31ad23b5d448860` |

## 一键获取（推荐）

在电脑上装好 Python 3.8 或更新版本，然后在本目录运行：

```sh
python get_amss20.py
```

脚本直接连接三星官方固件服务器（FUS），只下载固件包中包含 `amss20.bin` 的那几 MB（整包约 23 GB），在本地还原出文件并核对 SHA-256，保存为当前目录的 `s26u-amss20.bin`。只用 Python 标准库，不需要另装依赖；装了 `pycryptodomex` 或 `cryptography` 时解密会更快。

常用参数：

```sh
python get_amss20.py --push                                   # 同时用 adb 推送到手机 /sdcard/Download/
python get_amss20.py --module pandora-airdrop-v1.0.0.zip      # 同时生成含固件、可直接刷入的安装包
```

原理：`recipe/S948BXXS6BZK1.json` 记录了这个文件在加密固件包里的位置（加密包偏移、deflate 块边界、LZ4 块、sparse 分块和 EROFS 压缩块的偏移与长度）。脚本按这些位置向三星服务器请求一小段数据，依次解密、解压，最后拼出文件。位置文件里只有数字，不含任何三星的数据。

三星服务器通常只保留较新的固件版本。如果脚本提示服务器已不提供这个版本，说明需要为新版本生成位置文件，并在实机上验证新固件后再更新模块，请到项目 Issue 反馈。

## 其他获取方式

- 从你合法取得的 S948BXXS6BZK1 完整固件中，解出 `vendor` 分区里的 `firmware/peach/amss20.bin`。
- `stream_vendor.py`：流式下载整个 AP 包（约 11 GB），只把 vendor/vendor_dlkm 写到磁盘，需要 samloader 的 smart 分支（放在脚本同级的 `samloader-smart/`）以及 `pycryptodomex`、`lz4`。

取得后核对 SHA-256，必须与上表完全一致。

## 安装时如何使用

把文件放到手机的 `/sdcard/Download/s26u-amss20.bin`（或 `/sdcard/Download/amss20.bin`）后再安装模块。安装器校验 SHA-256 后把它复制进模块目录，之后更新模块会自动沿用已部署的副本。

固件只在 AirDrop 会话期间以 bind mount 方式覆盖 `/vendor/firmware_mnt/image/peach/amss20.bin`，会话结束或重启后即失效，不写入任何分区。

## 维护者：为新固件版本生成位置文件

`make_recipe.py`（需要 Linux、`lz4` Python 包、erofs-utils 和约 4 GB 空间）：

```sh
python make_recipe.py scan  --work /var/tmp/s26r   # 完整读取一次 AP 包（约 11 GB），记录各层的块边界
python make_recipe.py build --work /var/tmp/s26r -o recipe/<版本>.json   # 定位文件并向服务器实测验证
```

换版本时先修改脚本开头的 `FW`、`SHA`，并且新固件必须先在手机上验证可用。
