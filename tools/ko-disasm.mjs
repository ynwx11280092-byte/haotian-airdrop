#!/usr/bin/env node
/**
 * ko-disasm.mjs — 反汇编 arm64 .ko（基于 capstone-wasm），用于移植内核模块时
 * 推导结构体字段偏移 / 确认符号关系。
 *
 * 依赖：`npm install capstone-wasm`（纯 wasm，不需要本机编译工具链）。
 *
 * 用法：
 *   node tools/ko-disasm.mjs mhi.ko --sym mhi_bdf_to_controller
 *   node tools/ko-disasm.mjs mhi.ko --func mhi_alloc_bhie_table --max 200
 *   node tools/ko-disasm.mjs mhi.ko --displacements --func mhi_alloc_bhie_table
 *   node tools/ko-disasm.mjs mhi.ko --functions | grep mhi_
 *
 * 说明：.ko 是 ET_REL，BL/ADR 等跨节引用在文件里是未解析的重定位；工具会把
 * `.rela.text` 里的重定位符号标注在指令后面（`; -> symbol`），便于阅读。
 */
import { readFileSync } from 'node:fs';
import process from 'node:process';
import { loadCapstone, Capstone, Const } from 'capstone-wasm';

const SHT_SYMTAB = 2;
const STT_FUNC = 2;

function parseElf(buf) {
  const e_shoff = Number(buf.readBigUInt64LE(0x28));
  const e_shentsize = buf.readUInt16LE(0x3a);
  const e_shnum = buf.readUInt16LE(0x3c);
  const e_shstrndx = buf.readUInt16LE(0x3e);
  const secs = [];
  for (let i = 0; i < e_shnum; i++) {
    const o = e_shoff + i * e_shentsize;
    secs.push({
      idx: i, nameOff: buf.readUInt32LE(o), type: buf.readUInt32LE(o + 4),
      off: Number(buf.readBigUInt64LE(o + 24)), size: Number(buf.readBigUInt64LE(o + 32)),
      link: buf.readUInt32LE(o + 40), info: buf.readUInt32LE(o + 44),
      entsize: Number(buf.readBigUInt64LE(o + 56)),
    });
  }
  const shstr = secs[e_shstrndx];
  const shstrData = buf.subarray(shstr.off, shstr.off + shstr.size);
  for (const s of secs) {
    const z = shstrData.indexOf(0, s.nameOff);
    s.name = shstrData.subarray(s.nameOff, z < 0 ? undefined : z).toString('utf8');
  }
  const symtab = secs.find((s) => s.type === SHT_SYMTAB);
  const symbols = [];
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
  // 重定位：offset(相对 info 指向的节) -> 符号名
  const relocsBySection = new Map();
  for (const s of secs) {
    if (!s.name.startsWith('.rela') || !s.entsize) continue;
    const target = secs[s.info];
    const map = new Map();
    for (let r = 0; r < s.size / 24; r++) {
      const o = s.off + r * 24;
      const rOffset = Number(buf.readBigUInt64LE(o));
      const info = buf.readBigUInt64LE(o + 8);
      const addend = Number(buf.readBigInt64LE(o + 16));
      const symIdx = Number(info >> 32n);
      const sym = symbols[symIdx];
      if (sym && sym.name) map.set(rOffset, { name: sym.name, addend });
    }
    if (target) relocsBySection.set(target.idx, map);
  }
  return { buf, secs, symbols, relocsBySection };
}

function fnSymbols(elf) {
  return elf.symbols.filter((s) => (s.info & 0xf) === STT_FUNC && s.shndx > 0 && s.size > 0);
}

function disasmFunction(cs, elf, sym, max, showRelocs) {
  const sec = elf.secs[sym.shndx];
  if (!sec) return [];
  const start = sym.value;
  const end = Math.min(sec.size, start + sym.size);
  const code = elf.buf.subarray(sec.off + start, sec.off + end);
  const insns = cs.disasm(code, start, { count: max || 100000 });
  const relocs = elf.relocsBySection.get(sym.shndx) || new Map();
  return insns.map((ins) => {
    const rel = showRelocs ? relocs.get(Number(ins.address)) : null;
    return { addr: Number(ins.address), mnemonic: ins.mnemonic, opStr: ins.opStr, size: ins.size, reloc: rel };
  });
}

function main() {
  const args = process.argv.slice(2);
  const files = [];
  const funcs = [];
  const syms = [];
  let max = 0, listFunctions = false, displacements = false, showRelocs = true;
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === '--func') funcs.push(args[++i]);
    else if (a === '--sym') syms.push(args[++i]);
    else if (a === '--max') max = Number(args[++i]);
    else if (a === '--functions') listFunctions = true;
    else if (a === '--displacements') displacements = true;
    else if (a === '--no-relocs') showRelocs = false;
    else if (a.startsWith('-')) { console.error(`unknown arg ${a}`); process.exit(2); }
    else files.push(a);
  }
  if (!files.length) {
    console.error('usage: node tools/ko-disasm.mjs file.ko [--func NAME]... [--sym NAME]... [--functions] [--displacements] [--max N] [--no-relocs]');
    process.exit(2);
  }
  return (async () => {
    await loadCapstone();
    const cs = new Capstone(Const.CS_ARCH_ARM64, Const.CS_MODE_LITTLE_ENDIAN);
    for (const f of files) {
      const elf = parseElf(readFileSync(f));
      const funcsAll = fnSymbols(elf);
      if (listFunctions) {
        for (const s of funcsAll) console.log(`0x${s.value.toString(16)}\tsize=${s.size}\t${s.name}`);
        continue;
      }
      if (displacements) {
        const targets = funcs.length ? funcsAll.filter((s) => funcs.includes(s.name)) : funcsAll;
        for (const sym of targets) {
          const insns = disasmFunction(cs, elf, sym, max, false);
          const counts = new Map();
          for (const ins of insns) {
            for (const m of ins.opStr.matchAll(/#0x([0-9a-f]+)/g)) {
              const d = parseInt(m[1], 16);
              counts.set(d, (counts.get(d) || 0) + 1);
            }
          }
          const interesting = [...counts.entries()].filter(([d]) => d >= 0x40).sort((a, b) => b[0] - a[0]).slice(0, 40);
          console.log(`=== ${sym.name} (${sym.size} bytes)`);
          console.log('  ' + interesting.map(([d, c]) => `0x${d.toString(16)}x${c}`).join(' '));
        }
        continue;
      }
      const wanted = funcs.length ? funcs : syms;
      for (const name of wanted) {
        const sym = elf.symbols.find((s) => s.name === name && s.shndx > 0);
        if (!sym) { console.log(`== ${name}: NOT FOUND`); continue; }
        console.log(`== ${name} @0x${sym.value.toString(16)} size=${sym.size}`);
        const insns = disasmFunction(cs, elf, sym, max, showRelocs);
        for (const ins of insns) {
          const rel = ins.reloc ? `  ; -> ${ins.reloc.name}${ins.reloc.addend ? '+' + ins.reloc.addend : ''}` : '';
          console.log(`  0x${ins.addr.toString(16).padStart(6, '0')}: ${ins.mnemonic}\t${ins.opStr}${rel}`);
        }
      }
    }
    cs.close();
  })();
}

main().catch((e) => { console.error(e); process.exit(1); });
