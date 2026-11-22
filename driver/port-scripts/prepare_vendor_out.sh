#!/bin/bash
# Mixed-build emulation: vendor modules compile against GKI .config + canoe vendor fragment
# (Xiaomi soc-repo configs/canoe_perf.bzl), while vmlinux/Module.symvers stay from the GKI build.
set -euo pipefail
B=/data/build
export PATH=/usr/local/bin:$B/tc/clang/bin:$PATH KBUILD_GENDWARFKSYMS_STABLE=1
mkdir -p $B/out-vendor
cp $B/out/.config $B/out-vendor/.config
python3 - "$B" <<'EOF'
import re, sys, subprocess
B = sys.argv[1]
src = open('/tmp/canoe_perf.bzl').read()
args = []
for name, val in re.findall(r'"(CONFIG_\w+)":\s*"([^"]*)"', src):
    n = name[len('CONFIG_'):]
    if val in ('y', 'm'):
        args += ['-' + ('e' if val == 'y' else 'm'), n]
    elif val == 'n':
        args += ['-d', n]
    else:
        args += ['--set-val', n, val]
subprocess.run([f'{B}/src/ack/scripts/config', '--file', f'{B}/out-vendor/.config'] + args, check=True)
print(len(args) // 2, 'fragment options applied')
EOF
cd $B/src/ack
make -s ARCH=arm64 LLVM=1 O=$B/out-vendor olddefconfig
make -s ARCH=arm64 LLVM=1 O=$B/out-vendor -j4 modules_prepare
cp $B/out/Module.symvers $B/out-vendor/Module.symvers
grep -E '^CONFIG_(ARM_SMMU|QCOM_IOMMU_UTIL|CFG80211|MAC80211|ARCH_CANOE)=' $B/out-vendor/.config
