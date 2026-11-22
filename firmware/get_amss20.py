#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Fetch the Samsung Galaxy S26 Ultra WLAN firmware (amss20.bin) from Samsung's official FUS server.

Only a few MB are downloaded: a recipe file (recipe/<version>.json) records where the file's bytes sit
inside the encrypted firmware package, so the script asks the server for just that byte range and
rebuilds amss20.bin locally. The recipe holds offsets only; no Samsung data is shipped with it.

Pipeline (each step uses the offsets in the recipe):
  HTTP Range GET -> AES-128-ECB decrypt -> raw deflate from a block boundary -> LZ4 frame blocks
  -> Android sparse RAW chunks -> vendor EROFS pclusters (LZ4) -> amss20.bin, checked against SHA-256.

Usage:
  python get_amss20.py                       # writes ./s26u-amss20.bin
  python get_amss20.py -o DIR_OR_FILE
  python get_amss20.py --module pandora-airdrop-vX.Y.Z.zip   # also writes a module zip with firmware
  python get_amss20.py --push                # adb push to /sdcard/Download/s26u-amss20.bin

Python 3.8+, standard library only. If pycryptodome(x) or cryptography is installed it is used for AES,
otherwise a built-in pure-Python AES is used (slower, still well under a minute for a few MB).
"""
import argparse
import hashlib
import http.cookiejar
import json
import shutil
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
import zipfile
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_RECIPE = HERE / 'recipe' / 'S948BXXS6BZK1.json'
FW_IN_MODULE = 'payload/firmware/s26u-amss20.bin'

# ---------------------------------------------------------------- AES-128 (encrypt one block, ECB decrypt)


def _gen_tables():
    sbox = [0] * 256
    p = q = 1
    while True:
        p = p ^ ((p << 1) & 0xff) ^ (0x1b if p & 0x80 else 0)
        q ^= (q << 1) & 0xff
        q ^= (q << 2) & 0xff
        q ^= (q << 4) & 0xff
        if q & 0x80:
            q ^= 0x09
        r = lambda v, s: ((v << s) | (v >> (8 - s))) & 0xff
        sbox[p] = q ^ r(q, 1) ^ r(q, 2) ^ r(q, 3) ^ r(q, 4) ^ 0x63
        if p == 1:
            break
    sbox[0] = 0x63
    inv = [0] * 256
    for i, v in enumerate(sbox):
        inv[v] = i

    def mul(a, b):
        o = 0
        while b:
            if b & 1:
                o ^= a
            a = ((a << 1) ^ 0x1b) & 0xff if a & 0x80 else a << 1
            b >>= 1
        return o

    def rot(t):
        return [((x >> 8) | (x << 24)) & 0xffffffff for x in t]

    te0 = [(mul(s, 2) << 24) | (s << 16) | (s << 8) | mul(s, 3) for s in sbox]
    td0 = [(mul(s, 14) << 24) | (mul(s, 9) << 16) | (mul(s, 13) << 8) | mul(s, 11) for s in inv]
    te1 = rot(te0); te2 = rot(te1); te3 = rot(te2)
    td1 = rot(td0); td2 = rot(td1); td3 = rot(td2)
    return sbox, inv, (te0, te1, te2, te3), (td0, td1, td2, td3)


_SBOX, _INV, _TE, _TD = _gen_tables()


class _PyAES:
    def __init__(self, key):
        assert len(key) == 16
        w = list(struct.unpack('>4I', key))
        rcon = 1
        s = _SBOX
        for i in range(4, 44):
            t = w[i - 1]
            if i % 4 == 0:
                t = ((t << 8) | (t >> 24)) & 0xffffffff
                t = (s[t >> 24] << 24) | (s[(t >> 16) & 255] << 16) | (s[(t >> 8) & 255] << 8) | s[t & 255]
                t ^= rcon << 24
                rcon = ((rcon << 1) ^ 0x1b) & 0xff if rcon & 0x80 else rcon << 1
            w.append(w[i - 4] ^ t)
        self.ek = w
        td0, td1, td2, td3 = _TD
        dk = []
        for r in range(10, -1, -1):
            rk = w[4 * r:4 * r + 4]
            if 0 < r < 10:
                rk = [td0[s[x >> 24]] ^ td1[s[(x >> 16) & 255]] ^ td2[s[(x >> 8) & 255]] ^ td3[s[x & 255]] for x in rk]
            dk += rk
        self.dk = dk

    def encrypt_block(self, blk):
        te0, te1, te2, te3 = _TE
        s = _SBOX
        k = self.ek
        s0, s1, s2, s3 = struct.unpack('>4I', blk)
        s0 ^= k[0]; s1 ^= k[1]; s2 ^= k[2]; s3 ^= k[3]
        for r in range(1, 10):
            b = 4 * r
            t0 = te0[s0 >> 24] ^ te1[(s1 >> 16) & 255] ^ te2[(s2 >> 8) & 255] ^ te3[s3 & 255] ^ k[b]
            t1 = te0[s1 >> 24] ^ te1[(s2 >> 16) & 255] ^ te2[(s3 >> 8) & 255] ^ te3[s0 & 255] ^ k[b + 1]
            t2 = te0[s2 >> 24] ^ te1[(s3 >> 16) & 255] ^ te2[(s0 >> 8) & 255] ^ te3[s1 & 255] ^ k[b + 2]
            t3 = te0[s3 >> 24] ^ te1[(s0 >> 16) & 255] ^ te2[(s1 >> 8) & 255] ^ te3[s2 & 255] ^ k[b + 3]
            s0, s1, s2, s3 = t0, t1, t2, t3
        o = []
        for a, b_, c, d, kk in ((s0, s1, s2, s3, k[40]), (s1, s2, s3, s0, k[41]),
                                (s2, s3, s0, s1, k[42]), (s3, s0, s1, s2, k[43])):
            o.append(((s[a >> 24] << 24) | (s[(b_ >> 16) & 255] << 16) | (s[(c >> 8) & 255] << 8) | s[d & 255]) ^ kk)
        return struct.pack('>4I', *o)

    def decrypt(self, data):
        td0, td1, td2, td3 = _TD
        iv = _INV
        k = self.dk
        k0, k1, k2, k3 = k[0:4]
        f0, f1, f2, f3 = k[40:44]
        words = struct.unpack('>%dI' % (len(data) // 4), data)
        out = []
        ap = out.extend
        for j in range(0, len(words), 4):
            s0 = words[j] ^ k0; s1 = words[j + 1] ^ k1; s2 = words[j + 2] ^ k2; s3 = words[j + 3] ^ k3
            for b in range(4, 40, 4):
                t0 = td0[s0 >> 24] ^ td1[(s3 >> 16) & 255] ^ td2[(s2 >> 8) & 255] ^ td3[s1 & 255] ^ k[b]
                t1 = td0[s1 >> 24] ^ td1[(s0 >> 16) & 255] ^ td2[(s3 >> 8) & 255] ^ td3[s2 & 255] ^ k[b + 1]
                t2 = td0[s2 >> 24] ^ td1[(s1 >> 16) & 255] ^ td2[(s0 >> 8) & 255] ^ td3[s3 & 255] ^ k[b + 2]
                t3 = td0[s3 >> 24] ^ td1[(s2 >> 16) & 255] ^ td2[(s1 >> 8) & 255] ^ td3[s0 & 255] ^ k[b + 3]
                s0, s1, s2, s3 = t0, t1, t2, t3
            ap((((iv[s0 >> 24] << 24) | (iv[(s3 >> 16) & 255] << 16) | (iv[(s2 >> 8) & 255] << 8) | iv[s1 & 255]) ^ f0,
               ((iv[s1 >> 24] << 24) | (iv[(s0 >> 16) & 255] << 16) | (iv[(s3 >> 8) & 255] << 8) | iv[s2 & 255]) ^ f1,
               ((iv[s2 >> 24] << 24) | (iv[(s1 >> 16) & 255] << 16) | (iv[(s0 >> 8) & 255] << 8) | iv[s3 & 255]) ^ f2,
               ((iv[s3 >> 24] << 24) | (iv[(s2 >> 16) & 255] << 16) | (iv[(s1 >> 8) & 255] << 8) | iv[s0 & 255]) ^ f3))
        return struct.pack('>%dI' % len(out), *out)


def aes_ecb(key, force_pure=False):
    """Object with encrypt_block(16 bytes) and decrypt(n*16 bytes)."""
    if not force_pure:
        for mod in ('Cryptodome.Cipher.AES', 'Crypto.Cipher.AES'):
            try:
                m = __import__(mod, fromlist=['AES'])
                c = m.new(key, m.MODE_ECB)
                return type('A', (), {'encrypt_block': lambda s, b: c.encrypt(b), 'decrypt': lambda s, d: c.decrypt(d),
                                      'name': mod})()
            except Exception:
                pass
        try:
            from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
            ci = Cipher(algorithms.AES(key), modes.ECB())
            return type('A', (), {'encrypt_block': lambda s, b: ci.encryptor().update(b),
                                  'decrypt': lambda s, d: ci.decryptor().update(d), 'name': 'cryptography'})()
        except Exception:
            pass
    a = _PyAES(key)
    a.name = 'pure-python'
    return a

# ---------------------------------------------------------------- Samsung FUS client (Smart protocol)


FUS_URL = 'https://neofussvr.sslcs.cdngc.net/'
CLOUD_URL = 'https://cloud-neofussvr.samsungmobile.com/NF_SmartDownloadBinaryForMass.do?file='
AUTH_KEY = bytes.fromhex('422e73733617ae2b198940fd4e32b0a5')
UA = 'SMART 2.0'


def logic_check(inp, nonce):
    return ''.join(inp[ord(c) & 15] if (ord(c) & 15) < len(inp) else '.' for c in nonce)


class Fus:
    def __init__(self):
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        self.nonce = ''
        self.sig = ''
        self._auth = aes_ecb(AUTH_KEY)
        self.post('NF_SmartDownloadGenerateNonce.do')

    def authz(self):
        return 'FUS nonce="%s", signature="%s", nc="", type="", realm="", newauth="1"' % (self.nonce, self.sig)

    def post(self, path, body=b''):
        hdr = {'Authorization': self.authz(), 'User-Agent': UA, 'Accept': 'application/xml'}
        if body:
            hdr['Content-Type'] = 'application/xml'
        req = urllib.request.Request(FUS_URL + path, data=body, headers=hdr, method='POST')
        try:
            with self.opener.open(req, timeout=60) as r:
                text, nonce = r.read().decode('utf-8', 'replace'), r.headers.get('NONCE')
        except urllib.error.HTTPError as e:
            raise SystemExit('! 三星服务器返回 HTTP %d（%s）' % (e.code, path))
        if nonce:
            self.nonce = nonce
            self.sig = self._auth.encrypt_block(nonce.encode()[:16].ljust(16, b'0')).hex()
        return text

    @staticmethod
    def _msg(put, get=False):
        m = ET.Element('FUSMsg')
        h = ET.SubElement(m, 'FUSHdr')
        for t, v in (('ProtoVer', '1.0'), ('SessionID', '0'), ('MsgID', '1')):
            ET.SubElement(h, t).text = v
        body = ET.SubElement(m, 'FUSBody')
        p = ET.SubElement(body, 'Put')
        if get:
            ET.SubElement(p, 'CmdID').text = '1'
        for t, v in put.items():
            ET.SubElement(ET.SubElement(p, t), 'Data').text = str(v)
        if get:
            g = ET.SubElement(body, 'Get')
            ET.SubElement(g, 'CmdID').text = '2'
            ET.SubElement(g, 'BINARY_SW_VERSION')
        return ET.tostring(m)

    def open_binary(self, fw, model, region):
        """BinaryInform + BinaryInit. Returns (download path, total size, AES key)."""
        x = self.post('NF_SmartDownloadBinaryInform.do', self._msg({
            'ACCESS_MODE': 1, 'BINARY_NATURE': 1, 'REQUEST_TYPE': 2, 'LOGIC_CHECK': logic_check(fw, self.nonce),
            'BINARY_SW_VERSION': fw, 'BINARY_LOCAL_CODE': region, 'BINARY_MODEL_NAME': model}, get=True))
        kv = {e.tag: e.findtext('Data') for e in ET.fromstring(x).iter() if e.find('Data') is not None}
        if not kv.get('BINARY_NAME'):
            st = ET.fromstring(x).findtext('.//Status')
            raise SystemExit('! 三星服务器已不提供 %s %s %s（状态 %s）。需要新版本的位置文件。' % (model, region, fw.split('/')[0], st))
        name = kv['BINARY_NAME']
        self.post('NF_SmartDownloadBinaryInitForMass.do', self._msg({
            'BINARY_NAME': name, 'BINARY_SW_VERSION': fw, 'DEVICE_LOCAL_CODE': region,
            'DEVICE_MODEL_TYPE': kv['DEVICE_MODEL_TYPE'], 'LOGIC_CHECK': logic_check(name[-25:-9], self.nonce)}))
        key = hashlib.md5(logic_check(fw, kv['LOGIC_VALUE_FACTORY']).encode()).digest()
        return kv['MODEL_PATH'] + name, int(kv['BINARY_BYTE_SIZE']), key

    def get_range(self, path, a, b, stream=False):
        """Bytes [a, b] (inclusive) of the encrypted package."""
        hdr = {'Authorization': self.authz(), 'User-Agent': UA, 'Range': 'bytes=%d-%d' % (a, b)}
        for attempt in range(5):
            try:
                r = self.opener.open(urllib.request.Request(CLOUD_URL + path, headers=hdr), timeout=120)
                if r.status != 206:
                    raise SystemExit('! 服务器不支持分段下载（HTTP %d）' % r.status)
                if stream:
                    return r
                with r:
                    d = r.read()
                if len(d) == b - a + 1:
                    return d
            except (urllib.error.URLError, OSError, TimeoutError) as e:
                if attempt == 4:
                    raise SystemExit('! 下载失败：%s' % e)
            time.sleep(2 + attempt * 3)
        raise SystemExit('! 下载不完整')

# ---------------------------------------------------------------- LZ4 block decoder (raw block format)


def lz4_block(src, dst):
    """Decode one LZ4 block from src, appending to bytearray dst (which may hold history)."""
    i, n = 0, len(src)
    while i < n:
        t = src[i]
        i += 1
        ln = t >> 4
        if ln == 15:
            while True:
                b = src[i]
                i += 1
                ln += b
                if b != 255:
                    break
        if ln:
            dst += src[i:i + ln]
            i += ln
        if i >= n:
            break
        off = src[i] | (src[i + 1] << 8)
        i += 2
        ml = t & 15
        if ml == 15:
            while True:
                b = src[i]
                i += 1
                ml += b
                if b != 255:
                    break
        ml += 4
        st = len(dst) - off
        if off == 0 or st < 0:
            raise ValueError('bad LZ4 offset')
        if off >= ml:
            dst += dst[st:st + ml]
        else:
            pat = bytes(dst[st:])
            dst += (pat * (ml // off + 1))[:ml]
    return dst

# ---------------------------------------------------------------- raw inflate starting at a block boundary


def _deflate_prefix(k):
    """Bits of tiny valid non-final fixed-Huffman blocks, total length = k (mod 8). Returns (bits, literals)."""
    for b in range(8):
        for a in range(8):
            if (10 * a + 19 * b) % 8 == k and (a or b):
                bits = []
                for i in range(a + b):
                    bits += [0, 1, 0]                       # BFINAL=0, BTYPE=01 (fixed)
                    if i >= a:                              # literal 144: 9-bit code 110010000
                        bits += [(0b110010000 >> (8 - j)) & 1 for j in range(9)]
                    bits += [0] * 7                         # end of block
                return bits, b
    raise AssertionError(k)


def inflate_from(raw, k):
    """Inflate raw deflate data whose first block starts at bit k of raw[0]; the 32 KB window is unknown
    and replaced by zeros. Tiny blocks are spliced in front so the original byte alignment (which stored
    blocks depend on) is kept."""
    lit = 0
    if k:
        bits, lit = _deflate_prefix(k)
        j = len(bits) // 8
        pre = bytearray(sum(bits[8 * i + t] << t for t in range(8)) for i in range(j))
        last = sum(bits[8 * j + t] << t for t in range(k))
        pre.append(last | (raw[0] & (0xff << k) & 0xff))
        raw = bytes(pre) + raw[1:]
    out = zlib.decompressobj(-15, zdict=bytes(32768)).decompress(raw)
    return out[lit:]


# ---------------------------------------------------------------- recipe executor


def log(*a):
    print(*a, flush=True)


def fetch(recipe, verbose=True):
    fw, model, region = recipe['fw'], recipe['model'], recipe['region']
    d, l4 = recipe['deflate'], recipe['lz4']
    if verbose:
        log('- 连接三星官方服务器（FUS）: %s %s %s' % (model, region, fw.split('/')[0]))
    fus = Fus()
    path, size, key = fus.open_binary(fw, model, region)
    if size != recipe['package_size']:
        raise SystemExit('! 固件包大小与位置文件不符（%d != %d），可能是不同的打包版本' % (size, recipe['package_size']))
    bit = d['bit']
    a = (bit // 8) // 16 * 16
    b = (d['fetch_end'] + 15) // 16 * 16
    if verbose:
        log('- 下载加密包中的 %.1f MB（整包 %.1f GB）...' % ((b - a) / 2**20, size / 2**30))
    t0 = time.time()
    enc = fus.get_range(path, a, b - 1)
    cipher = aes_ecb(key)
    if verbose:
        log('  用时 %.0f 秒，解密（%s）...' % (time.time() - t0, cipher.name))
    raw = cipher.decrypt(enc)[bit // 8 - a:]
    raw = raw[:d['fetch_end'] - bit // 8]
    ap = inflate_from(raw, bit % 8)
    need = l4['start'] - d['out'] + l4['span']
    if len(ap) < need:
        raise SystemExit('! deflate 解出的数据不够（%d < %d）' % (len(ap), need))
    # LZ4 frame blocks -> one contiguous buffer of LZ4 output starting at `base`
    p = l4['start'] - d['out']
    linked = l4['linked']
    buf = bytearray(65536) if linked else bytearray()
    base = l4['out'] - len(buf)
    for _ in range(l4['blocks']):
        (w,) = struct.unpack_from('<I', ap, p)
        p += 4
        bl = w & 0x7fffffff
        blk = ap[p:p + bl]
        p += bl + (4 if l4['block_checksum'] else 0)
        if w & 0x80000000:
            buf += blk
        elif linked:
            lz4_block(blk, buf)
        else:
            buf += lz4_block(blk, bytearray())

    # sparse chunks -> the vendor partition bytes we need
    v0, vlen = recipe['vendor_window']
    vend = bytearray(vlen)
    for src_off, ln, voff in recipe['raw']:
        q = src_off - base
        if q < 0 or q + ln > len(buf):
            raise SystemExit('! 位置文件与数据不符（LZ4 输出 %d+%d）' % (src_off, ln))
        vend[voff - v0:voff - v0 + ln] = buf[q:q + ln]
    for voff, ln, pat in recipe.get('fill', []):
        vend[voff - v0:voff - v0 + ln] = (bytes.fromhex(pat) * (ln // 4 + 1))[:ln]

    def vendor(o, n):
        if o < v0 or o + n > v0 + vlen:
            raise SystemExit('! 位置文件与数据不符（vendor %d+%d）' % (o, n))
        return bytes(vend[o - v0:o - v0 + n])

    # EROFS extents -> file
    f = bytearray(recipe['file_size'])
    for e in recipe['extents']:
        blob = vendor(e['phys'], e['plen'])
        if e['z']:
            src = blob.lstrip(b'\0')
            dec = lz4_block(src, bytearray())
            data = dec[e.get('skip', 0):e.get('skip', 0) + e['llen']]
        else:
            data = blob[:e['llen']]
        f[e['logical']:e['logical'] + len(data)] = data
    f = bytes(f)
    h = hashlib.sha256(f).hexdigest()
    if h != recipe['sha256']:
        raise SystemExit('! 校验失败：SHA-256 %s，应为 %s' % (h, recipe['sha256']))
    return f


def adb_push(path):
    adb = shutil.which('adb')
    if not adb:
        raise SystemExit('! 没找到 adb，请手动把文件复制到手机 /sdcard/Download/s26u-amss20.bin')
    subprocess.run([adb, 'push', str(path), '/sdcard/Download/s26u-amss20.bin'], check=True)


def build_module(src_zip, fw, out_zip):
    with zipfile.ZipFile(src_zip) as zi:
        names = zi.namelist()
        if 'module.prop' not in names or 'payload/installation.sha256' not in names:
            raise SystemExit('! %s 不像是本项目的 KernelSU 安装包' % src_zip)
        man = zi.read('payload/installation.sha256').decode()
        want = hashlib.sha256(fw).hexdigest()
        if want + '  firmware/s26u-amss20.bin' not in man:
            raise SystemExit('! 安装包清单里的固件哈希与本固件不符，请用匹配的版本')
        with zipfile.ZipFile(out_zip, 'w', zipfile.ZIP_DEFLATED) as zo:
            for it in zi.infolist():
                if it.filename == FW_IN_MODULE:
                    continue
                zo.writestr(it, zi.read(it.filename))
            zo.writestr(FW_IN_MODULE, fw)


def main():
    if not sys.stdout.isatty() and hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')  # e.g. Git Bash/mintty on Windows reads UTF-8 from a pipe
    ap = argparse.ArgumentParser(description='从三星官方服务器取得 S26 Ultra 的 amss20.bin（只下载几 MB）')
    ap.add_argument('-o', '--out', default='s26u-amss20.bin', help='输出文件或目录（默认 ./s26u-amss20.bin）')
    ap.add_argument('--recipe', default=str(DEFAULT_RECIPE), help='位置文件（默认 recipe/S948BXXS6BZK1.json）')
    ap.add_argument('--module', help='本项目不含固件的安装包；额外生成含固件的安装包')
    ap.add_argument('--push', action='store_true', help='用 adb 推送到手机 /sdcard/Download/')
    a = ap.parse_args()
    recipe = json.loads(Path(a.recipe).read_text(encoding='utf-8'))
    out = Path(a.out)
    if out.is_dir():
        out = out / 's26u-amss20.bin'
    if out.exists() and hashlib.sha256(out.read_bytes()).hexdigest() == recipe['sha256']:
        log('- 已有校验通过的 %s，跳过下载' % out)
        fw = out.read_bytes()
    else:
        fw = fetch(recipe)
        out.write_bytes(fw)
        log('- 已保存 %s（%d 字节，SHA-256 %s…）' % (out, len(fw), recipe['sha256'][:16]))
    if a.module:
        mz = Path(a.module)
        dst = mz.with_name(mz.stem + '-with-firmware.zip')
        build_module(mz, fw, dst)
        log('- 已生成含固件的安装包 %s，可直接在 KernelSU 中刷入' % dst)
    if a.push:
        adb_push(out)
        log('- 已推送到手机 /sdcard/Download/s26u-amss20.bin')


if __name__ == '__main__':
    main()
