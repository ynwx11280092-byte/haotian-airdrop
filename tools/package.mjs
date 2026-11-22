#!/usr/bin/env node
/**
 * package.mjs — 组装可刷入的 KernelSU 模块 zip（haotian-airdrop）
 *
 * 用法（在项目根目录）：
 *   node tools/package.mjs --inputs build/out --upstream upstream
 *   node tools/package.mjs --inputs build/out --firmware /path/s26u-amss20.bin
 *   node tools/package.mjs --inputs build/out --allow-missing-kernel-modules   # 预览包
 *
 * --inputs 目录布局（也支持扁平放置）：
 *   build/out/kernel-modules/{qca_cld3_peach_v2.ko,wonder.ko,xos_wonder_bridge.ko,xos_mhi_fw.ko}
 *   build/out/runtime/{owly-xosd,wonder-init,xos-bridge.zip}
 *   build/out/compat/Haotian-XOS-Compat.apk
 * 或者用 --upstream <解压后的 pandora v1.0.0 payload 目录> 提供 3 个设备无关运行时文件。
 *
 * 打包前会校验：
 *   * 4 个内核模块存在，vermagic 的配置后缀与 device/<profile>.env 一致，
 *     且内核主系列号与目标内核一致（防止误用 pandora 6.12 的产物）；
 *   * 内核模块/运行时二进制的 SHA-256 写进 installation.sha256；
 *   * 可选的三星固件必须匹配 S26U_FW_SHA；
 *   * compat APK 必须存在且像 zip。
 */
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import zlib from 'node:zlib';

const ROOT = path.resolve(fileURLToPath(new URL('..', import.meta.url)));
const FIXED_DATE = new Date(2026, 10, 19, 0, 0, 0); // 固定时间戳，保证可复现
const REQUIRED_KERNEL_MODULES = ['qca_cld3_peach_v2.ko', 'wonder.ko', 'xos_wonder_bridge.ko', 'xos_mhi_fw.ko', 'rc80211_minstrel_ht.ko'];
const REQUIRED_RUNTIME = ['owly-xosd', 'wonder-init', 'xos-bridge.zip'];
const EXEC = new Set(['radio.sh', 'bridge-supervisor.sh', 'owly-xosd', 'wonder-init']);

const sha = (buf) => createHash('sha256').update(buf).digest('hex');

function parseArgs(argv) {
  const a = {
    profile: 'haotian',
    inputs: path.join(ROOT, 'build', 'out'),
    upstream: null,
    firmware: null,
    compat: null,
    out: path.join(ROOT, 'dist'),
    allowMissingKernelModules: false,
    allowMismatch: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i], v = () => argv[++i];
    if (k === '--profile') a.profile = v();
    else if (k === '--inputs') a.inputs = v();
    else if (k === '--upstream') a.upstream = v();
    else if (k === '--firmware') a.firmware = v();
    else if (k === '--compat') a.compat = v();
    else if (k === '--out') a.out = v();
    else if (k === '--allow-missing-kernel-modules') a.allowMissingKernelModules = true;
    else if (k === '--allow-mismatch') a.allowMismatch = true;
    else if (k === '-h' || k === '--help') { console.log(help()); process.exit(0); }
    else { console.error(`unknown arg: ${k}`); process.exit(2); }
  }
  return a;
}
const help = () => `usage: node tools/package.mjs [--profile haotian] [--inputs DIR] [--upstream DIR] [--firmware FILE] [--compat APK] [--out DIR] [--allow-missing-kernel-modules]`;

function readProfile(profile) {
  const p = path.join(ROOT, 'device', `${profile}.env`);
  if (!existsSync(p)) throw new Error(`设备配置不存在: ${p}`);
  const env = {};
  for (const raw of readFileSync(p, 'utf8').split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const m = line.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
    if (!m) continue;
    let v = m[2].trim();
    if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1);
    env[m[1]] = v;
  }
  return env;
}

function findFile(dirs, name) {
  for (const d of dirs) {
    if (!d) continue;
    const p = path.join(d, name);
    if (existsSync(p) && statSync(p).isFile()) return p;
  }
  return null;
}

function readVermagic(buf) {
  const m = buf.toString('latin1').match(/vermagic=([^\0\n\r]{1,200})/);
  return m ? m[1] : null;
}
/** 内核 same_magic()：模块有 __versions 时只比较 vermagic 第一个空格之后的部分 */
function vermagicSuffix(v) {
  if (!v) return null;
  const i = v.indexOf(' ');
  return i < 0 ? '' : v.slice(i + 1);
}
/** 内核主系列号（6.6 / 6.12），用来挡住误用其它内核系列模块的情况 */
function kernelSeries(release) {
  if (!release) return null;
  return release.split('-')[0].split('.').slice(0, 2).join('.');
}

// ---- 最小 ZIP 写入器（deflate + unix 权限位） ------------------------------
function crc32(buf) {
  let c, crc = 0xffffffff;
  for (let i = 0; i < buf.length; i++) {
    c = (crc ^ buf[i]) & 0xff;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    crc = (crc >>> 8) ^ c;
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function zipWrite(files) {
  const chunks = [], central = [];
  let offset = 0;
  const dosTime = ((FIXED_DATE.getHours() << 11) | (FIXED_DATE.getMinutes() << 5) | (FIXED_DATE.getSeconds() >> 1)) & 0xffff;
  const dosDate = (((FIXED_DATE.getFullYear() - 1980) << 9) | ((FIXED_DATE.getMonth() + 1) << 5) | FIXED_DATE.getDate()) & 0xffff;
  for (const f of files) {
    const nameBuf = Buffer.from(f.name, 'utf8');
    const data = f.data;
    const crc = zlib.crc32 ? zlib.crc32(data) >>> 0 : crc32(data);
    const comp = zlib.deflateRawSync(data, { level: 9 });
    const useDeflate = comp.length < data.length;
    const payload = useDeflate ? comp : data;
    const method = useDeflate ? 8 : 0;
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(0, 6);
    local.writeUInt16LE(method, 8);
    local.writeUInt16LE(dosTime, 10);
    local.writeUInt16LE(dosDate, 12);
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(payload.length, 18);
    local.writeUInt32LE(data.length, 22);
    local.writeUInt16LE(nameBuf.length, 26);
    local.writeUInt16LE(0, 28);
    chunks.push(local, nameBuf, payload);
    const cen = Buffer.alloc(46);
    cen.writeUInt32LE(0x02014b50, 0);
    cen.writeUInt16LE(0x031e, 4); // made by unix
    cen.writeUInt16LE(20, 6);
    cen.writeUInt16LE(0, 8);
    cen.writeUInt16LE(method, 10);
    cen.writeUInt16LE(dosTime, 12);
    cen.writeUInt16LE(dosDate, 14);
    cen.writeUInt32LE(crc, 16);
    cen.writeUInt32LE(payload.length, 20);
    cen.writeUInt32LE(data.length, 24);
    cen.writeUInt16LE(nameBuf.length, 28);
    cen.writeUInt16LE(0, 30);
    cen.writeUInt16LE(0, 32);
    cen.writeUInt16LE(0, 34);
    cen.writeUInt16LE(0, 36);
    cen.writeUInt32LE((((f.mode & 0o7777) | 0o100000) << 16) >>> 0, 38);
    cen.writeUInt32LE(offset, 42);
    central.push(cen, nameBuf);
    offset += local.length + nameBuf.length + payload.length;
  }
  const centralBuf = Buffer.concat(central);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(0, 4);
  end.writeUInt16LE(0, 6);
  end.writeUInt16LE(files.length, 8);
  end.writeUInt16LE(files.length, 10);
  end.writeUInt32LE(centralBuf.length, 12);
  end.writeUInt32LE(offset, 16);
  end.writeUInt16LE(0, 20);
  return Buffer.concat([...chunks, centralBuf, end]);
}

// ---- 主流程 ----------------------------------------------------------------
function main() {
  const a = parseArgs(process.argv.slice(2));
  const env = readProfile(a.profile);
  const expectedKernel = env.EXPECTED_KERNEL;
  if (!expectedKernel) throw new Error('设备配置缺少 EXPECTED_KERNEL');
  const expectedSuffix = env.EXPECTED_VERMAGIC_SUFFIX || '';
  const fwSha = env.S26U_FW_SHA;
  const fwRel = env.S26U_FW_REL || 'firmware/s26u-amss20.bin';
  const apkName = env.COMPAT_APK_NAME || 'Haotian-XOS-Compat.apk';

  const kmDirs = [path.join(a.inputs, 'kernel-modules'), a.inputs, a.upstream, path.join(ROOT, 'build', 'out')];
  const rtDirs = [path.join(a.inputs, 'runtime'), a.inputs, a.upstream, path.join(ROOT, 'upstream')];
  const apk = a.compat || findFile([path.join(a.inputs, 'compat'), a.inputs, path.join(ROOT, 'compat', 'dist')], apkName);
  if (!apk) throw new Error(`找不到兼容模块 APK: ${apkName}（先运行 compat/build.ps1 或 compat/build.sh）`);
  const apkBuf = readFileSync(apk);
  if (apkBuf.length < 1024 || apkBuf[0] !== 0x50 || apkBuf[1] !== 0x4b) throw new Error(`APK 不是有效 zip: ${apk}`);

  const payload = new Map();
  for (const s of ['radio.sh', 'bridge-supervisor.sh']) {
    const p = path.join(ROOT, 'runtime', s);
    if (!existsSync(p)) throw new Error(`缺少 runtime/${s}`);
    payload.set(s, readFileSync(p));
  }
  for (const b of REQUIRED_RUNTIME) {
    const p = findFile(rtDirs, b);
    if (!p) throw new Error(`缺少运行时文件 ${b}（用 --upstream 指向 pandora release 的 payload 目录）`);
    payload.set(b, readFileSync(p));
  }

  const missing = [];
  const kmBuf = new Map();
  for (const name of REQUIRED_KERNEL_MODULES) {
    const p = findFile(kmDirs, name);
    if (!p) { missing.push(name); continue; }
    const buf = readFileSync(p);
    const vermagic = readVermagic(buf);
    const suffix = vermagicSuffix(vermagic);
    const uts = vermagic ? vermagic.split(' ')[0] : null;
    if (expectedSuffix && suffix !== expectedSuffix) {
      const msg = `${name}: vermagic 配置后缀 "${suffix ?? '(缺失)'}" 与设备配置 "${expectedSuffix}" 不一致`;
      if (!a.allowMismatch) throw new Error(msg + '\n（没有对应内核模块的包装出来也不能用；用 --allow-mismatch 仅用于调试预览）');
      console.warn('警告:', msg);
    }
    if (uts && kernelSeries(uts) !== kernelSeries(expectedKernel)) {
      const msg = `${name}: 内核系列 ${kernelSeries(uts)}（${uts}）与目标 ${kernelSeries(expectedKernel)} 不一致，不是本机模块`;
      if (!a.allowMismatch) throw new Error(msg + '\n（是不是误用了 pandora 6.12 的 .ko？）');
      console.warn('警告:', msg);
    }
    if (uts && uts !== expectedKernel) {
      console.log(`提示: ${name} 的 UTS_RELEASE=${uts} 与手机内核 ${expectedKernel} 不同；CONFIG_MODVERSIONS 下只比较配置后缀 + 符号 CRC（详见 BUILD-MODULES.md §5）`);
    }
    kmBuf.set(name, buf);
  }
  if (missing.length && !a.allowMissingKernelModules) {
    throw new Error(`缺少内核模块: ${missing.join(', ')}\n请先按 BUILD-MODULES.md 在 Linux 上编译，或加 --allow-missing-kernel-modules 生成预览包`);
  }
  if (missing.length) console.warn('警告: 预览包不含内核模块，安装器会安全中止，无法实际使用:', missing.join(', '));

  let fw = null;
  if (a.firmware) {
    fw = readFileSync(a.firmware);
    if (sha(fw) !== fwSha) throw new Error(`${a.firmware}: SHA-256 不是期望的三星 S26U 固件 ${fwSha}`);
  }

  const prop = readFileSync(path.join(ROOT, 'module', 'module.prop'), 'utf8');
  const version = prop.match(/^version=(.+)$/m)[1].trim();
  const suffixName = (kmBuf.size === 0 ? '-preview' : '') + (fw ? '-with-firmware' : '');
  const zipName = `haotian-airdrop-${version}${suffixName}.zip`;

  const manifestLines = [];
  for (const [name, data] of payload) manifestLines.push(`${sha(data)}  ${name}`);
  for (const [name, data] of kmBuf) manifestLines.push(`${sha(data)}  ${name}`);
  if (fw) payload.set(fwRel, fw);
  // 固件行始终存在：radio.sh 会校验候选固件；未内置时安装器从手机复制到 payload
  manifestLines.push(`${fwSha}  ${fwRel}`);
  const manifest = Buffer.from(manifestLines.join('\n') + '\n');

  const lf = (b) => Buffer.from(b.toString('utf8').replace(/\r\n/g, '\n'));
  const files = [];
  const add = (name, data, mode) => files.push({ name, data, mode });
  const metaDir = path.join(ROOT, 'module', 'META-INF', 'com', 'google', 'android');
  add('META-INF/com/google/android/update-binary', lf(readFileSync(path.join(metaDir, 'update-binary'))), 0o755);
  add('META-INF/com/google/android/updater-script', lf(readFileSync(path.join(metaDir, 'updater-script'))), 0o644);
  add('module.prop', lf(readFileSync(path.join(ROOT, 'module', 'module.prop'))), 0o644);
  add('README.txt', lf(readFileSync(path.join(ROOT, 'module', 'README.txt'))), 0o644);
  for (const s of ['customize.sh', 'service.sh', 'action.sh', 'uninstall.sh', 'common.sh']) {
    add(s, lf(readFileSync(path.join(ROOT, 'module', s))), 0o755);
  }
  add(`device/${a.profile}.env`, lf(readFileSync(path.join(ROOT, 'device', `${a.profile}.env`))), 0o644);
  add('device/profile', Buffer.from(`${a.profile}\n`), 0o644);
  add('tools/preflight.sh', lf(readFileSync(path.join(ROOT, 'tools', 'preflight.sh'))), 0o755);
  add('tools/verify-modules.mjs', lf(readFileSync(path.join(ROOT, 'tools', 'verify-modules.mjs'))), 0o644);
  for (const [name, data] of payload) {
    add(`payload/${name}`, name === 'radio.sh' || name === 'bridge-supervisor.sh' ? lf(data) : data, EXEC.has(name) ? 0o755 : 0o644);
  }
  // 内核模块：installer 期望 payload/<name>.ko（customize.sh 的 KERNEL_MODULES 检查）
  for (const [name, data] of kmBuf) {
    add(`payload/${name}`, data, 0o644);
  }
  add('payload/installation.sha256', manifest, 0o644);
  add(`apks/${apkName}`, apkBuf, 0o644);
  add('apks/APKS.sha256', Buffer.from(`${sha(apkBuf)}  ${apkName}\n`), 0o644);

  files.sort((x, y) => (x.name < y.name ? -1 : x.name > y.name ? 1 : 0));
  const zip = zipWrite(files);
  mkdirSync(a.out, { recursive: true });
  const zpath = path.join(a.out, zipName);
  writeFileSync(zpath, zip);
  console.log(`产出: ${zpath}`);
  console.log(`大小: ${zip.length} bytes  sha256: ${sha(zip)}`);
  console.log(`内核模块: ${kmBuf.size ? [...kmBuf.keys()].join(', ') : '(无，预览包)'}`);
  console.log(`兼容 APK: ${apk} (${sha(apkBuf)})`);
  console.log(`固件: ${fw ? '已内置' : '未内置（安装时从手机查找）'}`);
  writeFileSync(path.join(a.out, `${zipName}.sha256`), `${sha(zip)}  ${zipName}\n`);
}

try { main(); } catch (e) { console.error('打包失败:', e.message); process.exit(1); }
