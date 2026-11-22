"""Stream SM-S948B AP from Samsung FUS and keep only vendor/vendor_dlkm out of super.img.lz4.
Pipeline: Range GET -> AES-ECB -> inflate -> tar stream -> lz4 frame -> android sparse -> LP metadata -> extents.
Based on houji-airdrop firmware-acquisition/acquire-ap.py (official FUS Smart protocol).
Run from a dir containing samloader-smart/ ; output in ./out"""
import hashlib, io, json, struct, sys, tarfile, time, zlib, xml.etree.ElementTree as ET
from pathlib import Path
sys.path.insert(0, 'samloader-smart')
from samloader import fusclient, request
from Cryptodome.Cipher import AES
import lz4.frame

FW = 'S948BXXS6BZK1/S948BOXM6BZK1/S948BXXS6BZK1/S948BXXS6BZK1'
MODEL = 'SM-S948B'
REGION = 'EUX'
WANT = ('vendor_a', 'vendor_dlkm_a')  # S26U super is virtual A/B: names carry _a
OUT = Path('out')
OUT.mkdir(exist_ok=True)


def log(*a):
    print(time.strftime('%H:%M:%S'), *a, flush=True)


c = fusclient.FUSClient()
xml = c.makereq('NF_SmartDownloadBinaryInform.do', request.binaryinform(FW, MODEL, REGION, c.nonce))
(OUT / 'metadata.xml').write_text(xml)
kv = {e.tag: e.findtext('Data') for e in ET.fromstring(xml).iter() if e.find('Data') is not None}
size = int(kv['BINARY_BYTE_SIZE'])
name = kv['BINARY_NAME']
key = hashlib.md5(request.getlogiccheck(FW, kv['LOGIC_VALUE_FACTORY']).encode()).digest()
c.makereq('NF_SmartDownloadBinaryInitForMass.do', request.binaryinit(name, FW, kv['DEVICE_MODEL_TYPE'], REGION, c.nonce))
url = 'https://cloud-neofussvr.samsungmobile.com/NF_SmartDownloadBinaryForMass.do?file=' + kv['MODEL_PATH'] + name
hdr = {'Authorization': f'FUS nonce="{c.nonce}", signature="{c.auth}", nc="", type="", realm="", newauth="1"',
       'User-Agent': 'SMART 2.0'}


def get_range(a, b):
    r = c.sess.get(url, headers=dict(hdr, Range=f'bytes={a}-{b}'), timeout=(30, 300), stream=True)
    r.raise_for_status()
    assert r.status_code == 206, r.status_code
    return r


tail = AES.new(key, AES.MODE_ECB).decrypt(get_range(size - 131072, size - 1).content)
entries = []
p = 0
while True:
    p = tail.find(b'PK\x01\x02', p)
    if p < 0:
        break
    a = struct.unpack_from('<4s6H3I5H2I', tail, p)
    n, x, cm = a[10:13]
    fn = tail[p + 46:p + 46 + n].decode()
    extra = tail[p + 46 + n:p + 46 + n + x]
    usize, csize, off = struct.unpack_from('<QQQ', extra, 4)
    entries.append(dict(name=fn, size=usize, compressed=csize, offset=off, crc32=a[7], method=a[4]))
    p += 46 + n + x + cm
(OUT / 'zip-entries.json').write_text(json.dumps(entries, indent=2))
log('ENTRIES', [e['name'] for e in entries])
entry = next(e for e in entries if e['name'].startswith('AP_'))
off = entry['offset']
al = off // 16 * 16
head = AES.new(key, AES.MODE_ECB).decrypt(get_range(al, al + 4095).content)[off - al:]
assert head[:4] == b'PK\x03\x04'
n, x = struct.unpack_from('<HH', head, 26)
start = off + 30 + n + x
end = start + entry['compressed']
al = start // 16 * 16
al_end = (end + 15) // 16 * 16
resp = get_range(al, al_end - 1)
cipher = AES.new(key, AES.MODE_ECB)
dz = zlib.decompressobj(-15)
stat = dict(enc=0, tar=0)
last = [time.monotonic()]


def blocks():
    skip = start - al
    remaining = entry['compressed']
    pending = b''
    for chunk in resp.iter_content(1 << 20):
        pending += chunk
        k = len(pending) // 16 * 16
        if not k:
            continue
        dec = cipher.decrypt(pending[:k])
        pending = pending[k:]
        if skip:
            dec = dec[skip:]
            skip = 0
        dec = dec[:remaining]
        remaining -= len(dec)
        stat['enc'] += len(dec)
        out = dz.decompress(dec)
        if out:
            stat['tar'] += len(out)
            yield out
        if time.monotonic() - last[0] > 30:
            log(f"PROGRESS zip {stat['enc'] / 2**30:.2f}/{entry['compressed'] / 2**30:.2f} GiB tar {stat['tar'] / 2**30:.2f} GiB")
            last[0] = time.monotonic()
    out = dz.flush()
    if out:
        yield out


class Reader(io.RawIOBase):
    def __init__(s):
        s.it = iter(blocks())
        s.buf = b''

    def readable(s):
        return True

    def readinto(s, b):
        if not s.buf:
            try:
                s.buf = next(s.it)
            except StopIteration:
                return 0
        k = min(len(b), len(s.buf))
        b[:k] = s.buf[:k]
        s.buf = s.buf[k:]
        return k


class Super:
    """Receives the logical (unsparsed) super image as (offset, bytes) pieces in increasing order."""
    HEAD = 1 << 20

    def __init__(s):
        s.head = bytearray()
        s.targets = None
        s.files = {}
        s.maxend = None
        s.sizes = {}

    def parse_lp(s):
        h = bytes(s.head)
        assert struct.unpack_from('<I', h, 4096)[0] == 0x616c4467, 'no LP geometry'
        m = 12288
        magic, major, minor, hsz = struct.unpack_from('<IHHI', h, m)
        assert magic == 0x414c5030, hex(magic)
        pt = struct.unpack_from('<3I', h, m + 80)
        ex = struct.unpack_from('<3I', h, m + 92)
        tb = m + hsz
        exts = [struct.unpack_from('<QIQI', h, tb + ex[0] + i * ex[2])[:3] for i in range(ex[1])]
        parts = {}
        for i in range(pt[1]):
            o = tb + pt[0] + i * pt[2]
            nm = h[o:o + 36].split(b'\0')[0].decode()
            attr, fe, ne, g = struct.unpack_from('<4I', h, o + 36)
            parts[nm] = exts[fe:fe + ne]
        (OUT / 'lp-partitions.json').write_text(json.dumps(parts, indent=1))
        log('LP', {k: sum(e[0] for e in v) * 512 for k, v in parts.items()})
        s.targets = []
        for nm in WANT:
            if nm not in parts:
                log('MISSING partition', nm)
                continue
            f = open(OUT / f'{nm}.img', 'wb')
            tot = 0
            for ns, tt, td in parts[nm]:
                assert tt == 0, 'non-linear extent'
                s.targets.append((td * 512, td * 512 + ns * 512, f, tot))
                tot += ns * 512
            f.truncate(tot)
            s.files[nm] = f
            s.sizes[nm] = tot
        s.maxend = max(t[1] for t in s.targets)
        for t in s.targets:
            assert t[0] >= s.HEAD

    def emit(s, off, data):
        if s.targets is None:
            if off < s.HEAD:
                if off > len(s.head):
                    s.head += bytes(off - len(s.head))
                s.head += data[:s.HEAD - off]
                if len(s.head) < s.HEAD:
                    return
            else:
                s.head += bytes(s.HEAD - len(s.head))
            s.parse_lp()
        a, b = off, off + len(data)
        for t0, t1, f, base in s.targets:
            lo, hi = max(a, t0), min(b, t1)
            if lo < hi:
                f.seek(base + lo - t0)
                f.write(data[lo - a:hi - a])

    def done(s, off):
        return s.maxend is not None and off >= s.maxend


class Sparse:
    def __init__(s, sink):
        s.sink = sink
        s.buf = bytearray()
        s.state = 'hdr'
        s.off = 0
        s.need = 28
        s.raw_left = 0
        s.plain = False

    def feed(s, data):
        if s.plain:
            s.sink.emit(s.off, data)
            s.off += len(data)
            return
        s.buf += data
        while True:
            if s.state == 'raw':
                if not s.buf:
                    return
                k = min(len(s.buf), s.raw_left)
                s.sink.emit(s.off, bytes(s.buf[:k]))
                del s.buf[:k]
                s.off += k
                s.raw_left -= k
                if s.raw_left == 0:
                    s.state = 'chunk'
                    s.need = s.chsz
                continue
            if len(s.buf) < s.need:
                return
            if s.state == 'hdr':
                magic, ma, mi, fh, ch, bs, tb, tc, ck = struct.unpack_from('<I4H4I', s.buf)
                if magic != 0xed26ff3a:
                    log('super is not sparse')
                    s.plain = True
                    d = bytes(s.buf)
                    s.buf = bytearray()
                    s.feed(d)
                    return
                s.bs, s.chsz = bs, ch
                del s.buf[:fh]
                s.state = 'chunk'
                s.need = ch
                log('SPARSE blk', bs, 'total', tb * bs)
            elif s.state == 'chunk':
                ty, _, csz, tsz = struct.unpack_from('<HHII', s.buf)
                del s.buf[:s.chsz]
                ln = csz * s.bs
                if ty == 0xCAC1:
                    s.state = 'raw' if ln else 'chunk'
                    s.raw_left = ln
                elif ty == 0xCAC2:
                    s.state = 'fill'
                    s.need = 4
                    s.fill_len = ln
                elif ty == 0xCAC3:
                    s.off += ln
                elif ty == 0xCAC4:
                    s.state = 'crc'
                    s.need = 4
                else:
                    raise ValueError(hex(ty))
            elif s.state == 'fill':
                pat = bytes(s.buf[:4])
                del s.buf[:4]
                if pat != b'\0\0\0\0':
                    blk = pat * (1 << 18)
                    left = s.fill_len
                    o = s.off
                    while left:
                        k = min(left, len(blk))
                        s.sink.emit(o, blk[:k])
                        o += k
                        left -= k
                elif s.sink.targets is None:
                    s.sink.emit(s.off, bytes(min(s.fill_len, Super.HEAD)))
                s.off += s.fill_len
                s.state = 'chunk'
                s.need = s.chsz
            elif s.state == 'crc':
                del s.buf[:4]
                s.state = 'chunk'
                s.need = s.chsz


reader = io.BufferedReader(Reader(), buffer_size=1 << 20)
with tarfile.open(fileobj=reader, mode='r|') as tar:
    for m in tar:
        log('TAR', m.name, m.size)
        if Path(m.name).name != 'super.img.lz4':
            continue
        sup = Super()
        sp = Sparse(sup)
        dec = lz4.frame.LZ4FrameDecompressor()
        src = tar.extractfile(m)
        while True:
            b = src.read(1 << 20)
            if not b:
                break
            sp.feed(dec.decompress(b))
            if sup.done(sp.off):
                log('all wanted extents written at logical offset', sp.off)
                break
        for nm, f in sup.files.items():
            f.close()
            log('SAVED', nm, sup.sizes[nm])
        break
log('DONE')
