# owly-xosd

AWDL 协议栈来自 houji-airdrop 的 Owly（`native/owly`，MIT）与 `native/houji-runner`。本项目基于 houji-airdrop 提交 `353a076`，只改了 `houji-runner` 的两个文件，见 `pandora-owly.patch`：

- sysfs 路径从 `qca_cld3_kiwi_v2` 改为 `qca_cld3_peach_v2`。
- **对端门控**：AWDL 邻居先作为候选，只有给本机发过 TCP 单播、或发过带 `_airdrop` 的组播的设备才加入驱动对端表（上限 6，空闲 30 秒后可被淘汰），避免周围 Apple 设备占满驱动的 8 个槽位。`OWLY_PEER_GATE=0` 可关闭。
- 同一 MAC 从驱动删除后 5 秒内不再添加，两次驱动对端操作至少间隔 300 ms。
- `max_peers` 从 8 提高到 64（`OWLY_MAX_PEERS` 可调），避免周围设备多时 owly 内部对端表反复挤出正在传输的 iPhone。
- 数据帧计入 RX 活动，用于门控的空闲判断。

## 编译

```sh
git clone https://github.com/ha0xin/houji-airdrop && cd houji-airdrop
git checkout 353a076
find native/houji-runner/src -name '*.rs' -exec sed -i 's/\r$//' {} +   # 补丁按 LF 生成
patch -p1 < /path/to/pandora-airdrop/owly/pandora-owly.patch
cd runtime/owly-xos && ANDROID_NDK_HOME=... bash build-native.sh     # 产物 dist/owly-xosd
```

需要 rustup（目标 `aarch64-linux-android`）和 NDK r27c。`xos-bridge.zip` 与 `wonder-init` 直接用 houji-airdrop 提交 `100c1e0` 的 `runtime/owly-xos`、`native/wonder-init` 编译，未修改。
