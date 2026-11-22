#!/usr/bin/env node
/**
 * verify-modules.mjs — 校验 4 个内核模块是否与目标内核匹配。
 *
 * 用法：
 *   node tools/verify-modules.mjs --inputs build/out/kernel-modules --profile haotian
 *   node tools/verify-modules.mjs --inputs <dir> --kernel 6.6.118-...
 *
 * 检查项：
 *   * 4 个模块文件存在、是 ELF、非空；
 *   * 内嵌 .modinfo 里 vermagic 的"配置后缀"（第一个空格之后，例如
 *     `SMP preempt mod_unload modversions aarch64`）必须与设备配置一致。
 *     开启 CONFIG_MODVERSIONS 的内核加载模块时只比较这段 + 符号 CRC，
 *     UTS_RELEASE 前缀可以不同（上游 6.12 模块就是这样加载到手机上的）；
 *   * 内核主系列号（6.6 / 6.12）必须与目标一致，挡住误用其它内核的 .ko；
 *   * 打印 modinfo（name/depends/retpoline）与 SHA-256；
 *   * 写出 <inputs>/MODULES.info（JSON），供人工核对/留档。
 *
 * 退出码：0 全部符合；1 有不符合项（--allow-mismatch 时只警告）。
 */
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const REQUIRED = ['qca_cld3_peach_v2.ko', 'wonder.ko', 'xos_wonder_bridge.ko', 'xos_mhi_fw.ko'];

function parseArgs(argv) {
  const a = { inputs: null, profile: 'haotian', kernel: null, suffix: null, out: null, allowMismatch: false };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    const v = () => argv[++i];
    if (k === '--inputs') a.inputs = v();
    else if (k === '--profile') a.profile = v();
    else if (k === '--kernel') a.kernel = v();
    else if (k === '--suffix') a.suffix = v();
    else if (k === '--out') a.out = v();
    else if (k === '--allow-mismatch') a.allowMismatch = true;
    else if (k === '-h' || k === '--help') { console.log(help()); process.exit(0); }
    else { console.error(`unknown arg: ${k}`); process.exit(2); }
  }
  return a;
}
const help = () => `usage: node tools/verify-modules.mjs --inputs DIR [--profile haotian|--kernel STR] [--suffix 'SMP preempt ...'] [--out PATH] [--allow-mismatch]`;

function readProfileEnv(root, profile) {
  const p = path.join(root, 'device', `${profile}.env`);
  if (!existsSync(p)) throw new Error(`profile not found: ${p}`);
  const env = {};
  for (const raw of readFileSync(p, 'utf8').split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const m = line.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
    if (!m) continue;
    let val = m[2].trim();
    if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) val = val.slice(1, -1);
    env[m[1]] = val;
  }
  return env;
}

/** 从 ELF 的 .modinfo 里找 vermagic=...（null 结尾的 ASCII） */
function readVermagic(buf) {
  const s = buf.toString('latin1');
  const m = s.match(/vermagic=([^\0\n\r]{1,200})/);
  return m ? m[1] : null;
}
function readModinfo(buf, key) {
  const s = buf.toString('latin1');
  const m = s.match(new RegExp(`(?:^|\\0)${key}=([^\\0]{0,300})`));
  return m ? m[1] : null;
}
function isElf(buf) {
  return buf.length > 4 && buf[0] === 0x7f && buf[1] === 0x45 && buf[2] === 0x4c && buf[3] === 0x46;
}
/** vermagic 第一个空格之后的部分（same_magic() 在有 __versions 时只比较这段） */
function vermagicSuffix(vermagic) {
  if (!vermagic) return null;
  const i = vermagic.indexOf(' ');
  return i < 0 ? '' : vermagic.slice(i + 1);
}
/** 内核主系列号，如 6.6 / 6.12 */
function kernelSeries(release) {
  if (!release) return null;
  return release.split('-')[0].split('.').slice(0, 2).join('.');
}

function main() {
  const a = parseArgs(process.argv.slice(2));
  if (!a.inputs) { console.error(help()); process.exit(2); }
  const root = path.resolve(fileURLToPath(new URL('..', import.meta.url)));
  const profile = readProfileEnv(root, a.profile);
  const expectedKernel = a.kernel || profile.EXPECTED_KERNEL;
  const expectedSuffix = a.suffix || profile.EXPECTED_VERMAGIC_SUFFIX || '';
  const expectedSeries = kernelSeries(expectedKernel);
  const dir = path.resolve(a.inputs);
  console.log(`目标内核: ${expectedKernel}（系列 ${expectedSeries}）`);
  console.log(`vermagic 配置后缀: ${expectedSuffix}`);
  console.log(`输入目录: ${dir}`);
  let bad = 0;
  const out = {
    expected_kernel: expectedKernel,
    expected_vermagic_suffix: expectedSuffix,
    generated_at: new Date().toISOString(),
    modules: {},
  };
  for (const name of REQUIRED) {
    const p = path.join(dir, name);
    if (!existsSync(p)) {
      console.log(`✗ ${name}: 缺少文件`);
      bad++;
      out.modules[name] = { present: false };
      continue;
    }
    const buf = readFileSync(p);
    const sha = createHash('sha256').update(buf).digest('hex');
    const vermagic = readVermagic(buf);
    const modname = readModinfo(buf, 'name');
    const depends = readModinfo(buf, 'depends');
    const retpoline = readModinfo(buf, 'retpoline');
    const suffix = vermagicSuffix(vermagic);
    const uts = vermagic ? vermagic.split(' ')[0] : null;
    const seriesOk = kernelSeries(uts) === expectedSeries;
    const crcMode = /\bmodversions\b/.test(suffix || '');
    const okElf = isElf(buf);
    const okSuffix = !!expectedSuffix && suffix === expectedSuffix;
    const utsMismatch = uts && uts !== expectedKernel;
    out.modules[name] = {
      size: buf.length,
      sha256: sha,
      vermagic: vermagic,
      vermagic_suffix: suffix,
      uts_release: uts,
      kernel_series_ok: seriesOk,
      crc_mode: crcMode,
      name: modname,
      depends: depends,
      retpoline: retpoline,
      elf: okElf,
      suffix_ok: okSuffix,
    };
    if (!okElf || !okSuffix || !seriesOk) bad++;
    const lines = [`${okElf && okSuffix && seriesOk ? '✓' : '✗'} ${name}`];
    lines.push(`  size=${buf.length} sha256=${sha}`);
    lines.push(`  vermagic=${vermagic ?? '(缺失)'}`);
    lines.push(`  配置后缀=${suffix ?? '?'}${okSuffix ? '  ✓' : `  ← 应为 ${expectedSuffix}`}`);
    if (!seriesOk) {
      lines.push(`  ✗ 内核系列 ${kernelSeries(uts)} != ${expectedSeries}：这不是本机内核的模块（是不是误用了 pandora 6.12 的产物？）`);
    }
    if (utsMismatch) {
      lines.push('  提示: UTS_RELEASE 与手机不同；CONFIG_MODVERSIONS 下内核只比较配置后缀 + 符号 CRC，一般可加载，但必须核对 CRC（见 BUILD-MODULES.md §5）');
      if (!crcMode) {
        lines.push('  ✗ 该模块没有 modversions 后缀：内核会严格比较完整 vermagic，UTS 不同将无法加载');
        bad++;
      }
    }
    lines.push(`  modinfo: name=${modname ?? '?'} depends=${depends ?? ''} retpoline=${retpoline ?? '?'}`);
    console.log(lines.join('\n'));
  }
  const outp = a.out || path.join(dir, 'MODULES.info');
  try {
    writeFileSync(outp, JSON.stringify(out, null, 2) + '\n');
    console.log(`已写出 ${outp}`);
  } catch (e) {
    console.error(`写 ${outp} 失败: ${e.message}`);
  }
  if (bad) {
    console.error(`\n${bad} 项不符合${a.allowMismatch ? '（--allow-mismatch：仅警告）' : ''}`);
    process.exit(a.allowMismatch ? 0 : 1);
  }
  console.log('\n全部符合目标内核的配置后缀。');
}

if (process.argv[1]?.endsWith('verify-modules.mjs')) main();
