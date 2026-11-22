#!/usr/bin/env node
/**
 * ko-crc-extract.mjs — 从 .ko 里提取符号 CRC（给移植驱动做 Module.symvers 用）
 *
 * 背景：手机内核开启 CONFIG_MODVERSIONS。在手机上 insmod 自编模块时，模块导入的
 * 每个符号的 CRC 必须与手机内核/厂商模块导出值一致。手机不公开 Module.symvers，
 * 但把厂商模块拉下来，ELF 里就带着这些信息：
 *   * `__versions` 区：本模块**导入**符号的 CRC（= 内核/其它模块的导出值）
 *   * 符号表里的 `__crc_<symbol>` 符号（`__kcrctab` 区）：本模块**导出**符号的 CRC
 *     （老式合并布局）或每个符号一个 `___kcrctab+<symbol>` 区
 *
 * 用法：
 *   node tools/ko-crc-extract.mjs --imports cnss2.ko
 *   node tools/ko-crc-extract.mjs --exports qca_cld3_peach_v2.ko
 *   node tools/ko-crc-extract.mjs --all cnss2.ko qca_cld3_peach_v2.ko > phone-crcs.txt
 *   node tools/ko-crc-extract.mjs --vermagic build/out/kernel-modules/wonder.ko
 *   node tools/ko-crc-extract.mjs --json --all a.ko
 *
 * 输出格式（与 driver/port-scripts/make_vendor_symvers.py 的 phone-crcs.txt 兼容，
 * 但用 tab 分隔：crc  name  kind  file）：
 *   0x08a1b2c3	symbol_name	import	cnss2.ko
 *   0x08a1b2c3	symbol_name	export	qca_cld3_peach_v2.ko
 *
 * 只依赖 Node 标准库；Windows/Linux 都能跑。
 */
import { readFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';

const SHT_SYMTAB = 2;

function parseElf(buf) {
  if (!(buf.length > 64 && buf[0] === 0x7f && buf[1] === 0x45 && buf[2] === 0x4c && buf[3] === 0x46)) {
    throw new Error('不是 ELF 文件（magic 不匹配）');
  }
  const is64 = buf[4] === 2;
  if (!is64) throw new Error('只支持 64 位 ELF（arm64 ko）');
  if (buf[5] !== 1) throw new Error('只支持小端 ELF');
  const e_shoff = Number(buf.readBigUInt64LE(0x28));
  const e_shentsize = buf.readUInt16LE(0x3a);
  const e_shnum = buf.readUInt16LE(0x3c);
  const e_shstrndx = buf.readUInt16LE(0x3e);
  const secs = [];
  for (let i = 0; i < e_shnum; i++) {
    const o = e_shoff + i * e_shentsize;
    secs.push({
      idx: i,
      nameOff: buf.readUInt32LE(o),
      type: buf.readUInt32LE(o + 4),
      flags: Number(buf.readBigUInt64LE(o + 8)),
      addr: Number(buf.readBigUInt64LE(o + 16)),
      off: Number(buf.readBigUInt64LE(o + 24)),
      size: Number(buf.readBigUInt64LE(o + 32)),
      link: buf.readUInt32LE(o + 40),
      info: buf.readUInt32LE(o + 44),
      entsize: Number(buf.readBigUInt64LE(o + 56)),
    });
  }
  const shstr = secs[e_shstrndx];
  const shstrData = buf.subarray(shstr.off, shstr.off + shstr.size);
  for (const s of secs) {
    const z = shstrData.indexOf(0, s.nameOff);
    s.name = shstrData.subarray(s.nameOff, z < 0 ? undefined : z).toString('utf8');
  }
  const byName = new Map();
  for (const s of secs) if (s.name && !byName.has(s.name)) byName.set(s.name, s);

  const symbols = [];
  const symtab = secs.find((s) => s.type === SHT_SYMTAB);
  if (symtab) {
    const strSec = secs[symtab.link];
    const strData = buf.subarray(strSec.off, strSec.off + strSec.size);
    const n = symtab.size / 24;
    for (let i = 0; i < n; i++) {
      const o = symtab.off + i * 24;
      const nameOff = buf.readUInt32LE(o);
      const z = strData.indexOf(0, nameOff);
      symbols.push({
        idx: i,
        name: strData.subarray(nameOff, z < 0 ? undefined : z).toString('utf8'),
        info: buf.readUInt8(o + 4),
        shndx: buf.readUInt16LE(o + 6),
        value: Number(buf.readBigUInt64LE(o + 8)),
        size: Number(buf.readBigUInt64LE(o + 16)),
      });
    }
  }
  return { buf, secs, byName, symbols };
}

/** 读 section 内的 C 字符串 */
function strAt(elf, sec, offset) {
  const { buf } = elf;
  if (!sec || offset < 0 || offset >= sec.size) return null;
  const start = sec.off + offset;
  const z = buf.indexOf(0, start);
  const end = z < 0 || z > sec.off + sec.size ? sec.off + sec.size : z;
  return buf.subarray(start, end).toString('utf8');
}

/** __versions: struct modversion_info { unsigned long crc; char name[56]; } (64 bytes) */
function imports(elf, fileName) {
  const v = elf.byName.get('__versions');
  if (!v) return [];
  if (v.size % 64 !== 0) throw new Error(`__versions size=${v.size} 不是 64 的倍数，未知 modversion 结构`);
  const out = [];
  for (let i = 0; i < v.size / 64; i++) {
    const o = v.off + i * 64;
    const crc = Number(elf.buf.readBigUInt64LE(o));
    const name = elf.buf.subarray(o + 8, o + 64).toString('latin1').split('\0')[0];
    if (!name) continue;
    out.push({ crc, name, kind: 'import', file: fileName });
  }
  return out;
}

/**
 * 从符号表里提取导出符号 CRC。
 * 优先用 `__crc_<name>` 符号（新内核 genksyms 会生成），兼容两种 section 布局：
 *   - 合并布局：所有 __crc_* 在 __kcrctab，st_value 是区内偏移
 *   - 每符号布局：每个符号一个 ___kcrctab+<name> 区，st_value=0
 * 回退：合并 __ksymtab + .rela__ksymtab 的旧解析。
 */
function exportsFromSymtab(elf, fileName) {
  const crcSyms = elf.symbols.filter((s) => s.name.startsWith('__crc_') && s.shndx > 0);
  const out = [];
  if (crcSyms.length) {
    for (const s of crcSyms) {
      const name = s.name.slice('__crc_'.length);
      if (!name) continue;
      const sec = elf.secs[s.shndx];
      if (!sec || !/kcrctab/.test(sec.name || '')) continue;
      const off = sec.off + s.value;
      if (off + 4 > elf.buf.length) continue;
      const crc = elf.buf.readUInt32LE(off);
      // namespace（如果要写进 Module.symvers 才需要；这里可选输出）
      out.push({ crc, name, kind: 'export', file: fileName });
    }
  }
  if (out.length) return out;
  return exportsFromRelocs(elf, fileName);
}

/** 旧布局：合并 __ksymtab + .rela__ksymtab（pandora 的驱动模块是这种） */
function exportsFromRelocs(elf, fileName) {
  const ks = elf.byName.get('__ksymtab');
  const kc = elf.byName.get('__kcrctab');
  const strSec = elf.byName.get('__ksymtab_strings');
  const relaSec = elf.byName.get('.rela__ksymtab');
  if (!ks || !kc || !relaSec) return [];
  const nEntries = ks.size / 12;
  if (kc.size % nEntries !== 0) throw new Error('__kcrctab 与 __ksymtab 数量不匹配');
  const crcSize = kc.size / nEntries;
  const nameOffsets = new Map();
  for (let r = 0; r < relaSec.size / 24; r++) {
    const o = relaSec.off + r * 24;
    const rOffset = Number(elf.buf.readBigUInt64LE(o));
    const info = elf.buf.readBigUInt64LE(o + 8);
    const addend = Number(elf.buf.readBigInt64LE(o + 16));
    const symIdx = Number(info >> 32n);
    const entry = Math.floor(rOffset / 12);
    const field = rOffset % 12;
    if (field === 4) nameOffsets.set(entry, { addend, sym: elf.symbols[symIdx] });
  }
  const out = [];
  for (let i = 0; i < nEntries; i++) {
    const nr = nameOffsets.get(i);
    let name = null;
    if (nr) {
      if (nr.sym && nr.sym.name && !nr.sym.name.startsWith('__')) name = nr.sym.name;
      if (!name) name = strAt(elf, strSec, nr.addend);
    }
    if (!name || !/^[A-Za-z_][A-Za-z0-9_.$]*$/.test(name)) continue;
    const crc = crcSize === 4 ? elf.buf.readUInt32LE(kc.off + i * 4) : Number(elf.buf.readBigUInt64LE(kc.off + i * 8));
    out.push({ crc, name, kind: 'export', file: fileName });
  }
  return out;
}

export function extractKo(filePath) {
  const buf = readFileSync(filePath);
  const elf = parseElf(buf);
  const fileName = path.basename(filePath);
  const vermagicMatch = buf.toString('latin1').match(/vermagic=([^\0\n\r]{1,200})/);
  const nameMatch = buf.toString('latin1').match(/(?:^|\0)name=([^\0]{1,64})/);
  return {
    file: fileName,
    vermagic: vermagicMatch ? vermagicMatch[1] : null,
    moduleName: nameMatch ? nameMatch[1] : null,
    imports: imports(elf, fileName),
    exports: exportsFromSymtab(elf, fileName),
  };
}

function main() {
  const args = process.argv.slice(2);
  const files = [];
  let mode = 'all', json = false;
  for (const a of args) {
    if (a === '--imports') mode = 'imports';
    else if (a === '--exports') mode = 'exports';
    else if (a === '--all') mode = 'all';
    else if (a === '--json') json = true;
    else if (a === '--vermagic') mode = 'vermagic';
    else if (a.startsWith('-')) { console.error(`unknown arg ${a}`); process.exit(2); }
    else files.push(a);
  }
  if (!files.length) {
    console.error('usage: node tools/ko-crc-extract.mjs [--imports|--exports|--all|--vermagic] [--json] file.ko [...]');
    process.exit(2);
  }
  const results = files.map((f) => extractKo(f));
  if (mode === 'vermagic') {
    for (const r of results) console.log(`${r.file}: module=${r.moduleName ?? '?'} vermagic=${r.vermagic ?? '(缺失)'}`);
    return;
  }
  if (json) {
    const obj = results.map((r) => ({
      file: r.file,
      module_name: r.moduleName,
      vermagic: r.vermagic,
      imports: mode === 'exports' ? undefined : r.imports,
      exports: mode === 'imports' ? undefined : r.exports,
    }));
    console.log(JSON.stringify(obj, null, 2));
    return;
  }
  const rows = [];
  for (const r of results) {
    if (mode !== 'exports') rows.push(...r.imports);
    if (mode !== 'imports') rows.push(...r.exports);
  }
  const seen = new Set();
  const uniq = rows.filter((r) => {
    const k = `${r.file}|${r.name}|${r.kind}`;
    if (seen.has(k)) return false;
    seen.add(k);
    return true;
  });
  uniq.sort((a, b) => a.name.localeCompare(b.name) || a.file.localeCompare(b.file));
  for (const r of uniq) console.log(`0x${(r.crc >>> 0).toString(16).padStart(8, '0')}\t${r.name}\t${r.kind}\t${r.file}`);
  console.error(`# ${files.length} 个文件: ${uniq.filter((r) => r.kind === 'import').length} imports, ${uniq.filter((r) => r.kind === 'export').length} exports`);
}

if (process.argv[1]?.endsWith('ko-crc-extract.mjs')) main();
