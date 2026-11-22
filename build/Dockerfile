# haotian-airdrop 内核模块构建环境（参考）
#
# 用法：
#   docker build -t haotian-build build/
#   docker run --rm -it -v "$PWD:/work" -v /path/to/sources:/src haotian-build bash
#   cd /work && ./build/build-modules.sh --work /build --config /src/phone.config \
#       --kernel-src /src/kernel --wlan-src /src/wlan --toolchain /opt/clang
#
# 注意：容器只是提供可复现的工具链；驱动补丁移植和手机 .config 仍需人工完成。
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential git curl wget ca-certificates \
      python3 python3-pip perl bc flex bison cpio rsync lz4 xz-utils \
      libssl-dev libelf-dev dwarves zstd device-tree-compiler \
      clang lld llvm android-sdk-libsparse-utils e2fsprogs \
      zip unzip nodejs npm file && \
    rm -rf /var/lib/apt/lists/*

# 可选：使用 AOSP 预编译 clang（与 ACK 6.6 推荐版本一致），需网络可访问 googlesource。
# 若下载失败，可删掉下面这段，改用系统 clang（apt 的 clang-18 通常也能编译 6.6，
# 但 CFI/LTO 细节可能与小米官方构建不同，务必用 kocrc.py 核对符号 CRC）。
ARG CLANG_URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main/clang-r510928.tar.gz"
RUN mkdir -p /opt/clang && (curl -fL "$CLANG_URL" | tar xz -C /opt/clang) || \
    echo "警告: AOSP clang 下载失败，改用系统 clang"

WORKDIR /work
CMD ["/bin/bash"]
