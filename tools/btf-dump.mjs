#!/usr/bin/env node
/**
 * btf-dump.mjs — 读取内核模块里的 .BTF（BTFv1）类型信息，用于推导结构体字段偏移。
 *
 * 背景：xos_mhi_fw.ko 需要访问 `struct mhi_controller` / `struct image_info` 的
 * 内部字段（img_pre_alloc、fbc_image、rddm_image、rddm_size、sbl_size、seg_len …），
 * 这些偏移随内核版本/配置变化。haotian 的 mhi.ko 带 CONFIG_DEBUG_INFO_BTF_MODULES，
 * 直接解析 .BTF 就能拿到**精确偏移**，比反汇编更可靠。
 *
 * 用法：
 *   node tools/btf-dump.mjs --sections mhi.ko
 *   node tools/btf-dump.mjs mhi.ko --struct mhi_controller
 *   node tools/btf-dump.mjs mhi.ko --find img_pre_alloc --find fbc_image
 *   node tools/btf-dump.mjs mhi.ko --json > btf.json
 *
 * 只依赖 Node 标准库。
 */
import { readFileSync } from 'node:fs';
import process from 'node:process';

const KINDS = [
  'UNKN', 'INT', 'PTR', 'ARRAY', 'STRUCT', 'UNION', 'ENUM', 'FWD', 'TYPEDEF',
  'VOLATILE', 'CONST', 'RESTRICT', 'FUNC', 'FUNC_PROTO', 'VAR', 'DATASEC',
  'FLOAT', 'DECL_TAG', 'TYPE_TAG', 'ENUM64',
];

function elfSection(buf, name) {
  const shoff = Number(buf.readBigUInt64LE(0x28));
  const shentsize = buf.readUInt16LE(0x3a);
  const shnum = buf.readUInt16LE(0x3c);
  const shstrndx = buf.readUInt16LE(0x3e);
  const secs = [];
  for (let i = 0; i < shnum; i++) {
    const o = shoff + i * shentsize;
    secs.push({
      nameOff: buf.readUInt32LE(o),
      type: buf.readUInt32LE(o + 4),
      off: Number(buf.readBigUInt64LE(o + 24)),
      size: Number(buf.readBigUInt64LE(o + 32)),
    });
  }
  const shstr = secs[shstrndx];
  const shstrData = buf.subarray(shstr.off, shstr.off + shstr.size);
  for (const s of secs) {
    const z = shstrData.indexOf(0, s.nameOff);
    s.name = shstrData.subarray(s.nameOff, z < 0 ? undefined : z).toString('utf8');
  }
  const hit = secs.find((s) => s.name === name);
  if (!hit) return null;
  return buf.subarray(hit.off, hit.off + hit.size);
}

function parseBtf(buf) {
  const magic = buf.readUInt16LE(0);
  if (magic !== 0xeb9f) throw new Error(`BTF magic 0x${magic.toString(16)} != 0xeb9f`);
  const version = buf.readUInt8(2);
  const hdrLen = buf.readUInt32LE(4);
  const typeOff = buf.readUInt32LE(8);
  const typeLen = buf.readUInt32LE(12);
  const strOff = buf.readUInt32LE(16);
  const strLen = buf.readUInt32LE(20);
  const types = buf.subarray(hdrLen + typeOff, hdrLen + typeOff + typeLen);
  const strs = buf.subarray(hdrLen + strOff, hdrLen + strOff + strLen);
  const localTypes = [{ id: 0, kind: 'VOID', name: '' }];
  let off = 0;
  while (off < types.length) {
    const start = off;
    const nameOff = types.readUInt32LE(off);
    const info = types.readUInt32LE(off + 4);
    const vlen = info & 0xffff;
    const kind = (info >>> 24) & 0x1f;
    const kindFlag = (info >>> 31) & 1;
    const sizeType = types.readUInt32LE(off + 8);
    off += 12;
    const z = strs.indexOf(0, nameOff);
    const name = strs.subarray(nameOff, z < 0 ? undefined : z).toString('utf8');
    const t = { id: localTypes.length, kind: KINDS[kind] || `K${kind}`, kindId: kind, name, size: sizeType, vlen, kindFlag, members: [] };
    if (kind === 4 || kind === 5) {
      for (let m = 0; m < vlen; m++) {
        const nameOff2 = types.readUInt32LE(off);
        const mtype = types.readUInt32LE(off + 4);
        const raw = types.readUInt32LE(off + 8);
        off += 12;
        const z2 = strs.indexOf(0, nameOff2);
        const mname = strs.subarray(nameOff2, z2 < 0 ? undefined : z2).toString('utf8');
        let bitOffset, bitfieldSize = 0;
        if (kindFlag) { bitOffset = raw & 0xffffff; bitfieldSize = (raw >>> 24) & 0xff; }
        else { bitOffset = raw; }
        t.members.push({ name: mname, type: mtype, bitOffset, byteOffset: bitOffset / 8, bitfieldSize });
      }
    } else if (kind === 1) { off += 4; }
    else if (kind === 3) { off += 12; }
    else if (kind === 6) { off += vlen * 8; }
    else if (kind === 19) { off += vlen * 12; }
    else if (kind === 13) { off += vlen * 8; }
    else if (kind === 14) { off += 4; }
    else if (kind === 15) { off += vlen * 12; }
    else if (kind === 17) { off += 4; }
    // PTR/TYPEDEF/VOLATILE/CONST/RESTRICT/FWD/FUNC/FLOAT/TYPE_TAG: no extra payload
    if (off <= start) throw new Error('BTF parser stalled');
    localTypes.push(t);
  }
  void version; void strLen;
  return localTypes;
}

function main() {
  const args = process.argv.slice(2);
  const files = [];
  const wantStructs = [];
  const wantMembers = [];
  let json = false, sections = false;
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === '--struct') wantStructs.push(args[++i]);
    else if (a === '--find') wantMembers.push(args[++i]);
    else if (a === '--json') json = true;
    else if (a === '--sections') sections = true;
    else if (a.startsWith('-')) { console.error(`unknown arg ${a}`); process.exit(2); }
    else files.push(a);
  }
  if (!files.length) { console.error('usage: node tools/btf-dump.mjs file.ko [--struct NAME] [--find MEMBER] [--json] [--sections]'); process.exit(2); }
  for (const f of files) {
    const buf = readFileSync(f);
    if (sections) {
      const btf = elfSection(buf, '.BTF');
      console.log(`${f}: .BTF ${btf ? btf.length + ' bytes' : 'NOT FOUND'}`);
      continue;
    }
    const raw = elfSection(buf, '.BTF');
    if (!raw) { console.error(`${f}: 没有 .BTF 区（CONFIG_DEBUG_INFO_BTF_MODULES 未开？）`); continue; }
    const types = parseBtf(raw);
    if (json) { console.log(JSON.stringify({ file: f, types }, null, 2)); continue; }
    const structs = types.filter((t) => (t.kind === 'STRUCT' || t.kind === 'UNION') && t.name && t.name !== '__btf_dump_avoid_typedef');
    if (!wantStructs.length && !wantMembers.length) {
      console.log(`${f}: ${types.length} types, ${structs.length} struct/union`);
      for (const s of structs.slice(0, 40)) console.log(`  ${s.kind} ${s.name} size=${s.size} members=${s.members.length}`);
      continue;
    }
    for (const name of wantStructs) {
      const hit = structs.find((s) => s.name === name);
      if (!hit) { console.log(`${name}: NOT FOUND`); continue; }
      console.log(`struct ${hit.name} size=${hit.size}`);
      for (const m of hit.members) console.log(`  +0x${m.byteOffset.toString(16).padStart(3, '0')} ${m.name} (bit ${m.bitOffset}${m.bitfieldSize ? ', field ' + m.bitfieldSize : ''}) type=${m.type}`);
    }
    for (const member of wantMembers) {
      for (const s of structs) {
        const m = s.members.find((x) => x.name === member);
        if (m) console.log(`member ${member}: struct ${s.name} size=${s.size} +0x${m.byteOffset.toString(16)} (bit ${m.bitOffset}) type=${m.type}`);
      }
    }
  }
}

main();
