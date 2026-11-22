#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Maintainer tool: build recipe/<version>.json for get_amss20.py.

Streams the whole AP once from Samsung FUS (about 11 GB, nothing big is kept except the vendor
partition image), records where every deflate block, LZ4 block and sparse chunk starts, then locates
amss20.bin inside the vendor EROFS image with dump.erofs and writes the minimal byte ranges.

  python make_recipe.py scan  --work DIR        # long: streams the AP, writes DIR/scan.json + DIR/vendor_a.img
  python make_recipe.py build --work DIR -o recipe/S948BXXS6BZK1.json

Needs Linux (libz via ctypes), the `lz4` Python package, erofs-utils (dump.erofs) and ~4 GB free in DIR.
The recipe only contains offsets and lengths; it carries no Samsung data.
"""
import argparse
import ctypes
import ctypes.util
import hashlib
import json
import re
import struct
import subprocess
import sys
import time
from pathlib import Path

import lz4.block

sys.path.insert(0, str(Path(__file__).resolve().parent))
import get_amss20 as g  # noqa: E402

FW = 'S948BXXS6BZK1/S948BOXM6BZK1/S948BXXS6BZK1/S948BXXS6BZK1'
MODEL = 'SM-S948B'
REGION = 'EUX'
PART = 'vendor_a'
TARGET = '/firmware/peach/amss20.bin'
SHA = '71fc5c2eb2df048b6c4b494564cfbef730db879a3d8b4426c31ad23b5d448860'


def log(*a):
    print(time.strftime('%H:%M:%S'), *a, flush=True)

# ------------------------------------------------------------------ raw inflate that reports block boundaries


class ZStream(ctypes.Structure):
    _fields_ = [('next_in', ctypes.c_void_p), ('avail_in', ctypes.c_uint), ('total_in', ctypes.c_ulong),
                ('next_out', ctypes.c_void_p), ('avail_out', ctypes.c_uint), ('total_out', ctypes.c_ulong),
                ('msg', ctypes.c_char_p), ('state', ctypes.c_void_p), ('zalloc', ctypes.c_void_p),
                ('zfree', ctypes.c_void_p), ('opaque', ctypes.c_void_p), ('data_type', ctypes.c_int),
                ('adler', ctypes.c_ulong), ('reserved', ctypes.c_ulong)]


class Inflater:
    """Raw inflate; calls on_boundary(bit_offset_in_input, output_offset) at each deflate block start."""
    OUT = 1 << 20

    def __init__(self, on_boundary):
        self.z = ctypes.CDLL(ctypes.util.find_library('z'))
        self.z.zlibVersion.restype = ctypes.c_char_p
        self.s = ZStream()
        r = self.z.inflateInit2_(ctypes.byref(self.s), -15, self.z.zlibVersion(), ctypes.sizeof(ZStream))
        assert r == 0, r
        self.out = ctypes.create_string_buffer(self.OUT)
        self.cb = on_boundary
        self.done = False
        on_boundary(0, 0)

    def feed(self, data):
        if self.done or not data:
            return
        inb = ctypes.create_string_buffer(data, len(data))
        s = self.s
        s.next_in = ctypes.addressof(inb)
        s.avail_in = len(data)
        while True:
            s.next_out = ctypes.addressof(self.out)
            s.avail_out = self.OUT
            r = self.z.inflate(ctypes.byref(s), 5)  # Z_BLOCK
            n = self.OUT - s.avail_out
            if n:
                yield ctypes.string_at(self.out, n)
            if r == 1:
                self.done = True
                return
            if r < 0 and r != -5:
                raise RuntimeError('inflate %d %s' % (r, s.msg))
            if (s.data_type & 128) and not (s.data_type & 64):
                self.cb(s.total_in * 8 - (s.data_type & 7), s.total_out)
            if s.avail_in == 0 and n < self.OUT:
                return

# ------------------------------------------------------------------ pull reader over the AP byte stream


class Stream:
    def __init__(self, gen):
        self.gen = gen
        self.buf = bytearray()
        self.pos = 0  # AP offset of buf[0]
        self.eof = False

    def _fill(self, n):
        while len(self.buf) < n and not self.eof:
            try:
                self.buf += next(self.gen)
            except StopIteration:
                self.eof = True

    def read(self, n):
        self._fill(n)
        d = bytes(self.buf[:n])
        del self.buf[:n]
        self.pos += len(d)
        return d

    def skip(self, n):
        while n:
            k = len(self.read(min(n, 1 << 22)))
            if not k:
                return
            n -= k


class Sparse:
    """Android sparse parser; records chunks as [lz4out_offset_of_data, type, super_offset, length, pattern]."""

    def __init__(self, sink):
        self.sink = sink
        self.buf = bytearray()
        self.bpos = 0  # lz4-output offset of buf[0]
        self.state = 'hdr'
        self.need = 28
        self.off = 0
        self.chunks = []

    def _take(self, n):
        d = bytes(self.buf[:n])
        del self.buf[:n]
        self.bpos += n
        return d

    def feed(self, data):
        self.buf += data
        while True:
            if self.state == 'raw':
                if not self.buf:
                    return
                k = min(len(self.buf), self.left)
                self.sink(self.off, self._take(k))
                self.off += k
                self.left -= k
                if not self.left:
                    self.state, self.need = 'chunk', self.chsz
                continue
            if len(self.buf) < self.need:
                return
            if self.state == 'hdr':
                magic, _, _, fh, ch, bs, tb, tc, _ = struct.unpack_from('<I4H4I', self.buf)
                assert magic == 0xed26ff3a, 'super is not sparse'
                self.bs, self.chsz = bs, ch
                self._take(fh)
                self.state, self.need = 'chunk', ch
            elif self.state == 'chunk':
                ty, _, csz, _ = struct.unpack_from('<HHII', self._take(self.chsz))
                ln = csz * self.bs
                if ty == 0xCAC1:
                    self.chunks.append([self.bpos, 'raw', self.off, ln, None])
                    if ln:
                        self.state, self.left = 'raw', ln
                elif ty == 0xCAC2:
                    self.state, self.need, self.fl = 'fill', 4, ln
                elif ty == 0xCAC3:
                    self.chunks.append([self.bpos, 'skip', self.off, ln, None])
                    self.off += ln
                elif ty == 0xCAC4:
                    self.state, self.need = 'crc', 4
                else:
                    raise ValueError(hex(ty))
            elif self.state == 'fill':
                pat = self._take(4)
                self.chunks.append([self.bpos - 4, 'fill', self.off, self.fl, pat.hex()])
                blk = pat * (1 << 18)
                o, left = self.off, self.fl
                if pat == bytes(4):
                    left = min(left, 1 << 20)  # zero fills only matter for the LP header area
                while left:
                    k = min(left, len(blk))
                    self.sink(o, blk[:k])
                    o += k
                    left -= k
                self.off += self.fl
                self.state, self.need = 'chunk', self.chsz
            elif self.state == 'crc':
                self._take(4)
                self.state, self.need = 'chunk', self.chsz


def parse_lp(head):
    assert struct.unpack_from('<I', head, 4096)[0] == 0x616c4467, 'no LP geometry'
    m = 12288
    magic, _, _, hsz = struct.unpack_from('<IHHI', head, m)
    assert magic == 0x414c5030
    pt = struct.unpack_from('<3I', head, m + 80)
    ex = struct.unpack_from('<3I', head, m + 92)
    tb = m + hsz
    exts = [struct.unpack_from('<QIQI', head, tb + ex[0] + i * ex[2])[:3] for i in range(ex[1])]
    parts = {}
    for i in range(pt[1]):
        o = tb + pt[0] + i * pt[2]
        nm = head[o:o + 36].split(b'\0')[0].decode()
        _, fe, ne, _ = struct.unpack_from('<4I', head, o + 36)
        parts[nm] = [(td * 512, ns * 512) for ns, tt, td in exts[fe:fe + ne] if tt == 0]
    return parts


def scan(work):
    work.mkdir(parents=True, exist_ok=True)
    fus = g.Fus()
    path, size, key = fus.open_binary(FW, MODEL, REGION)
    cipher = g.aes_ecb(key)
    log('package', size, 'aes', cipher.name)
    tail = cipher.decrypt(fus.get_range(path, size - 131072, size - 1))
    entries, p = [], 0
    while True:
        p = tail.find(b'PK\x01\x02', p)
        if p < 0:
            break
        a = struct.unpack_from('<4s6H3I5H2I', tail, p)
        n, x, cm = a[10:13]
        fn = tail[p + 46:p + 46 + n].decode()
        usize, csize, off = struct.unpack_from('<QQQ', tail[p + 46 + n:p + 46 + n + x], 4)
        entries.append(dict(name=fn, size=usize, compressed=csize, offset=off, method=a[4]))
        p += 46 + n + x + cm
    e = next(e for e in entries if e['name'].startswith('AP_'))
    assert e['method'] == 8
    al = e['offset'] // 16 * 16
    head = cipher.decrypt(fus.get_range(path, al, al + 4095))[e['offset'] - al:]
    assert head[:4] == b'PK\x03\x04'
    n, x = struct.unpack_from('<HH', head, 26)
    start = e['offset'] + 30 + n + x
    end = start + e['compressed']
    bounds = []
    inf = Inflater(lambda bit, out: bounds.append((start * 8 + bit, out)))
    resp = fus.get_range(path, start // 16 * 16, (end + 15) // 16 * 16 - 1, stream=True)
    stat = dict(enc=0, t=time.time())

    def ap_gen():
        skip, left, pend = start % 16, e['compressed'], b''
        while left > 0:
            c = resp.read(1 << 20)
            if not c:
                raise RuntimeError('connection closed at %d' % stat['enc'])
            pend += c
            k = len(pend) // 16 * 16
            if not k:
                continue
            d = cipher.decrypt(pend[:k])
            pend = pend[k:]
            if skip:
                d, skip = d[skip:], 0
            d = d[:left]
            left -= len(d)
            stat['enc'] += len(d)
            yield from inf.feed(d)
            if time.time() - stat['t'] > 60:
                log('progress %.2f / %.2f GiB' % (stat['enc'] / 2**30, e['compressed'] / 2**30))
                stat['t'] = time.time()

    st = Stream(ap_gen())
    rec = dict(fw=FW, model=MODEL, region=REGION, package_size=size, ap_data_start=start, ap_entry=e['name'])
    vimg = open(work / 'vendor_a.img', 'wb')
    sup = dict(head=bytearray(), targets=None, maxend=None)

    def sink(off, data):
        if sup['targets'] is None:
            H = 1 << 20
            if off < H:
                if off > len(sup['head']):
                    sup['head'] += bytes(off - len(sup['head']))
                sup['head'] += data[:H - off]
                if len(sup['head']) < H:
                    return
            else:
                sup['head'] += bytes(max(0, H - len(sup['head'])))
            parts = parse_lp(bytes(sup['head'][:H]))
            rec['lp'] = parts
            tg, tot = [], 0
            for o, ln in parts[PART]:
                tg.append((o, o + ln, tot))
                tot += ln
            vimg.truncate(tot)
            sup['targets'] = tg
            sup['maxend'] = max(t[1] for t in tg)
            log('LP', {k: sum(x[1] for x in v) for k, v in parts.items()})
        a, b = off, off + len(data)
        for t0, t1, base in sup['targets']:
            lo, hi = max(a, t0), min(b, t1)
            if lo < hi:
                vimg.seek(base + lo - t0)
                vimg.write(data[lo - a:hi - a])

    pax_size = None
    while True:
        h = st.read(512)
        if len(h) < 512 or h == bytes(512):
            raise RuntimeError('super.img.lz4 not found')
        name = h[:100].split(b'\0')[0].decode()
        if h[124] & 0x80:
            sz = int.from_bytes(h[125:136], 'big')
        else:
            sz = int(h[124:136].split(b'\0')[0].strip() or b'0', 8)
        if h[156:157] in (b'x', b'g'):
            body = st.read((sz + 511) // 512 * 512)[:sz].decode('utf-8', 'replace')
            m = re.search(r'\d+ size=(\d+)\n', body)
            if h[156:157] == b'x' and m:
                pax_size = int(m.group(1))
            continue
        if pax_size is not None:
            sz, pax_size = pax_size, None
        log('TAR', name, sz, 'at', st.pos)
        if not name.endswith('super.img.lz4'):
            st.skip((sz + 511) // 512 * 512)
            continue
        rec['super_lz4'] = [st.pos, sz]
        magic, flg, bd = struct.unpack('<IBB', st.read(6))
        assert magic == 0x184D2204, hex(magic)
        if flg & 0x08:
            st.read(8)
        if flg & 0x01:
            st.read(4)
        st.read(1)
        linked = not (flg & 0x20)
        bchk = bool(flg & 0x10)
        rec['lz4'] = dict(linked=linked, block_checksum=bchk, block_max=[0, 0, 0, 0, 64 << 10, 256 << 10, 1 << 20, 4 << 20][(bd >> 4) & 7])
        log('LZ4 linked', linked, 'block checksum', bchk, 'max', rec['lz4']['block_max'])
        blocks, outpos, hist = [], 0, b''
        sp = Sparse(sink)
        while True:
            hp = st.pos
            (w,) = struct.unpack('<I', st.read(4))
            if w == 0:
                break
            bl = w & 0x7fffffff
            blk = st.read(bl)
            if bchk:
                st.read(4)
            if w & 0x80000000:
                o = blk
            elif linked:
                o = lz4.block.decompress(blk, uncompressed_size=rec['lz4']['block_max'], dict=hist)
            else:
                o = lz4.block.decompress(blk, uncompressed_size=rec['lz4']['block_max'])
            blocks.append((hp, outpos))
            if linked:
                hist = (hist + o)[-65536:]
            sp.feed(o)
            outpos += len(o)
            if sup['maxend'] is not None and sp.off >= sup['maxend']:
                log('vendor complete at super offset', sp.off)
                break
        rec['lz4_blocks'] = blocks
        rec['chunks'] = sp.chunks
        break
    vimg.close()
    rec['deflate_bounds'] = [b for b in bounds]
    (work / 'scan.json').write_text(json.dumps(rec))
    log('DONE', len(bounds), 'deflate blocks,', len(blocks), 'lz4 blocks,', len(sp.chunks), 'chunks')


def build(work, out):
    rec = json.loads((work / 'scan.json').read_text())
    img = str(work / 'vendor_a.img')
    txt = subprocess.run(['dump.erofs', '--path=' + TARGET, '-e', img], capture_output=True, text=True, check=True).stdout
    data = subprocess.run(['dump.erofs', '--path=' + TARGET, '--cat', img], capture_output=True, check=True).stdout
    assert hashlib.sha256(data).hexdigest() == SHA, 'dump.erofs --cat sha mismatch'
    size = int(re.search(r'Size: (\d+)', txt).group(1))
    exts = []
    vf = open(img, 'rb')
    for m in re.finditer(r'^\s*\d+:\s+(\d+)\.\.\s*(\d+)\s*\|\s*(\d+)\s*:\s*(\d+)\.\.\s*(\d+)\s*\|\s*(\d+)', txt, re.M):
        lo, hi, ll, po, pe, pl = map(int, m.groups())
        vf.seek(po)
        blob = vf.read(pl)
        want = data[lo:hi]
        z = True
        try:
            dec = g.lz4_block(blob.lstrip(b'\0'), bytearray())[:ll]
        except Exception:
            dec = b''
        if bytes(dec) != want:
            assert blob[:ll] == want, 'extent %d..%d neither lz4 nor plain' % (lo, hi)
            z = False
        exts.append(dict(logical=lo, llen=ll, phys=po, plen=pl, z=z))
    assert sum(e['llen'] for e in exts) == size
    v0 = min(e['phys'] for e in exts)
    v1 = max(e['phys'] + e['plen'] for e in exts)
    log('amss20.bin', size, 'bytes,', len(exts), 'extents, vendor window', v0, v1 - v0)
    # vendor window -> super ranges (through the LP extents of vendor_a)
    sup_ranges, base = [], 0
    for so, ln in rec['lp'][PART]:
        lo, hi = max(v0, base), min(v1, base + ln)
        if lo < hi:
            sup_ranges.append((so + lo - base, hi - lo, lo))
        base += ln
    # super ranges -> sparse chunks -> lz4 output ranges
    raw, fill, need_lo, need_hi = [], [], None, None
    for s0, ln, vo in sup_ranges:
        for c in rec['chunks']:
            dpos, ty, coff, clen, pat = c
            lo, hi = max(s0, coff), min(s0 + ln, coff + clen)
            if lo >= hi:
                continue
            v = vo + lo - s0
            if ty == 'raw':
                src = dpos + lo - coff
                raw.append([src, hi - lo, v])
                need_lo = src if need_lo is None else min(need_lo, src)
                need_hi = src + hi - lo if need_hi is None else max(need_hi, src + hi - lo)
            elif ty == 'fill' and pat != '00000000':
                fill.append([v, hi - lo, pat])
    blocks = rec['lz4_blocks']
    bounds = rec['deflate_bounds']
    i0_min = max(i for i, b in enumerate(blocks) if b[1] <= need_lo)
    i1 = max(i for i, b in enumerate(blocks) if b[1] < need_hi)
    ap_end = blocks[i1 + 1][0] if i1 + 1 < len(blocks) else rec['super_lz4'][0] + rec['super_lz4'][1]
    after = [b for b in bounds if b[1] >= ap_end]
    fetch_end = (after[0][0] + 7) // 8 if after else rec['ap_data_start'] + rec['package_size']
    # The deflate window and (for linked LZ4) the LZ4 history before the restart point are unknown and
    # replaced by zeros; pick the smallest margins whose output reproduces amss20.bin exactly.
    for margin in (1 << 20, 4 << 20, 16 << 20, 64 << 20):
        i0 = i0_min
        if rec['lz4']['linked']:
            while i0 > 0 and blocks[i0_min][1] - blocks[i0][1] < margin:
                i0 -= 1
        lz_start = blocks[i0][0]
        cand = [b for b in bounds if b[1] <= lz_start - margin] or [bounds[0]]
        bit, dout = cand[-1]
        recipe = dict(
            fw=rec['fw'], model=rec['model'], region=rec['region'], package_size=rec['package_size'],
            target='vendor' + TARGET, file_size=size, sha256=SHA,
            deflate=dict(bit=bit, out=dout, fetch_end=fetch_end),
            lz4=dict(start=lz_start, out=blocks[i0][1], blocks=i1 - i0 + 1, span=ap_end - lz_start,
                     linked=rec['lz4']['linked'], block_checksum=rec['lz4']['block_checksum']),
            vendor_window=[v0, v1 - v0], raw=raw, fill=fill, extents=exts)
        log('margin %d MB: fetch %.1f MB' % (margin >> 20, (fetch_end - bit // 8) / 2**20))
        try:
            g.fetch(json.loads(json.dumps(recipe)), verbose=False)
        except SystemExit as e:
            log('  failed:', e)
            continue
        Path(out).write_text(json.dumps(recipe, indent=1) + '\n')
        log('recipe verified against FUS and written to', out)
        return
    raise SystemExit('no margin reproduced the file')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('cmd', choices=['scan', 'build'])
    ap.add_argument('--work', required=True)
    ap.add_argument('-o', '--out', default='recipe.json')
    a = ap.parse_args()
    (scan if a.cmd == 'scan' else lambda w: build(w, a.out))(Path(a.work))


if __name__ == '__main__':
    main()
