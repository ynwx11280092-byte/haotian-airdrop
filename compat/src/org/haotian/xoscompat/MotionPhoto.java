package org.haotian.xoscompat;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.RandomAccessFile;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

/**
 * Apple Live Photo (JPEG + QuickTime MOV) -> Android Motion Photo 1.0 JPEG, the format Xiaomi Gallery reads
 * for its own MVIMG_*.jpg (GCamera:MotionPhoto XMP + Container:Directory, MP4 appended after the JPEG).
 *
 * Pure java.io so it runs inside MIShare and on a desktop JVM. The MOV is not re-encoded: the video and
 * audio tracks are kept byte for byte (including the full tkhd matrix, so mirrored front-camera clips stay
 * mirrored), Apple's metadata (mebx) tracks and the moov-level meta box are dropped, ftyp becomes mp42 and
 * the chunk offsets are rebased. The cover time comes from Apple's still-image-time metadata track.
 */
final class MotionPhoto {
    static final int MAX_INPUT = 96 << 20;
    private static final byte[] XMP_NS = "http://ns.adobe.com/xap/1.0/\0".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] XMP_EXT_NS = "http://ns.adobe.com/xmp/extension/\0".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] STILL_KEY = "com.apple.quicktime.still-image-time".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] CONTENT_ID = "com.apple.quicktime.content.identifier".getBytes(StandardCharsets.US_ASCII);

    private MotionPhoto() {}

    /** Bakes a mirrored display matrix into the pixels (Android MediaCodec implementation in OrientTranscoder). */
    interface VideoFixer {
        File fix(File mov, int[] matrix, File outDir) throws Exception;
    }

    static final class Result {
        final long mp4Length;
        final long coverUs;
        final long gainMapLength;
        final long outLength;
        String mirror = "none";

        Result(long mp4Length, long coverUs, long gainMapLength, long outLength) {
            this.mp4Length = mp4Length;
            this.coverUs = coverUs;
            this.gainMapLength = gainMapLength;
            this.outLength = outLength;
        }

        @Override
        public String toString() {
            return "mp4=" + mp4Length + " coverUs=" + coverUs + " gainMap=" + gainMapLength + " out=" + outLength + " mirror=" + mirror;
        }
    }

    /** Writes the motion photo to {@code out}; throws (and leaves no file) if either input is not as expected. */
    static Result merge(File jpeg, File mov, File out) throws IOException {
        return merge(jpeg, mov, out, null);
    }

    /**
     * Mirrored (front-camera) clips: like Xiaomi's iOS MIShare, keep the cover as is and bake the video
     * orientation into the pixels with {@code fixer}; if that is unavailable or fails, remove the mirror on
     * both sides instead (EXIF 5->6, matrix transpose->rotation). Other clips are remuxed losslessly.
     */
    static Result merge(File jpeg, File mov, File out, VideoFixer fixer) throws IOException {
        byte[] j = read(jpeg);
        byte[] m = read(mov);
        Mov movInfo = remux(m, false);
        int exifFixed = 0;
        String mirrorNote = "none";
        if (movInfo.mirrored) {
            String why = "no fixer";
            if (fixer != null) {
                try {
                    File baked = fixer.fix(mov, movInfo.matrix, out.getAbsoluteFile().getParentFile());
                    try {
                        movInfo.mp4 = read(baked);
                    } finally {
                        baked.delete();
                    }
                    mirrorNote = "baked";
                    why = null;
                } catch (Throwable t) {
                    why = String.valueOf(t);
                }
            }
            if (why != null) {
                long cover = movInfo.coverUs;
                movInfo = remux(m, true);
                movInfo.coverUs = cover;
                exifFixed = unmirrorExif(j);
                mirrorNote = "removed exif=" + exifFixed + " (" + why + ")";
            }
        }
        Jpeg jp = parseJpeg(j);
        String xmp = xmp(movInfo.coverUs, jp.gainMapLength, movInfo.mp4.length);
        byte[] xmpPayload = concat(XMP_NS, xmp.getBytes(StandardCharsets.UTF_8));
        if (xmpPayload.length + 2 > 0xffff) throw new IOException("xmp too large");

        File tmp = new File(out.getPath() + ".part");
        try (FileOutputStream os = new FileOutputStream(tmp)) {
            os.write(j, 0, jp.xmpInsertAt);
            os.write(0xff);
            os.write(0xe1);
            int len = xmpPayload.length + 2;
            os.write(len >> 8);
            os.write(len & 0xff);
            os.write(xmpPayload);
            for (int[] keep : jp.keepRanges) os.write(j, keep[0], keep[1] - keep[0]);
            os.write(movInfo.mp4);
            os.getFD().sync();
        } catch (IOException e) {
            tmp.delete();
            throw e;
        }
        if (out.exists() && !out.delete()) {
            tmp.delete();
            throw new IOException("cannot replace " + out);
        }
        if (!tmp.renameTo(out)) {
            tmp.delete();
            throw new IOException("rename failed: " + out);
        }
        Result res = new Result(movInfo.mp4.length, movInfo.coverUs, jp.gainMapLength, out.length());
        res.mirror = mirrorNote;
        return res;
    }

    /** Apple's pairing id from the MOV (com.apple.quicktime.content.identifier), or null. */
    static String movContentId(File mov) {
        try {
            return contentIdAfter(read(mov), CONTENT_ID);
        } catch (IOException e) {
            return null;
        }
    }

    /** Every UUID string in the JPEG's first 256 KiB (Apple's MakerNote carries the Live Photo pairing id). */
    static java.util.Set<String> jpegUuids(File jpeg) {
        java.util.Set<String> ids = new java.util.HashSet<>();
        try {
            long n = Math.min(jpeg.length(), 256 << 10);
            byte[] d = new byte[(int) n];
            try (RandomAccessFile r = new RandomAccessFile(jpeg, "r")) {
                r.readFully(d);
            }
            for (int i = 0; i + 36 <= d.length; i++) {
                if (isUuid(d, i)) ids.add(new String(d, i, 36, StandardCharsets.US_ASCII).toUpperCase());
            }
        } catch (IOException ignored) {
        }
        return ids;
    }

    /** Apple's pairing id from the JPEG (MakerNote / XMP carries it as a UUID string), or null. */
    static String jpegContentId(File jpeg) {
        try {
            byte[] d = read(jpeg);
            int lim = Math.min(d.length, 256 << 10);
            for (int i = 0; i + 36 <= lim; i++) {
                if (isUuid(d, i)) return new String(d, i, 36, StandardCharsets.US_ASCII).toUpperCase();
            }
        } catch (IOException ignored) {
        }
        return null;
    }

    // ---- JPEG ----

    private static final class Jpeg {
        int xmpInsertAt;
        final List<int[]> keepRanges = new ArrayList<>();
        long gainMapLength;
    }

    private static Jpeg parseJpeg(byte[] d) throws IOException {
        if (d.length < 4 || (d[0] & 0xff) != 0xff || (d[1] & 0xff) != 0xd8) throw new IOException("not a jpeg");
        Jpeg jp = new Jpeg();
        List<int[]> dropped = new ArrayList<>();
        int lastApp = 2;
        boolean mpf = false;
        int i = 2;
        while (true) {
            if (i + 4 > d.length || (d[i] & 0xff) != 0xff) throw new IOException("bad jpeg marker at " + i);
            int marker = d[i + 1] & 0xff;
            if (marker == 0xda) break;
            int len = ((d[i + 2] & 0xff) << 8) | (d[i + 3] & 0xff);
            int end = i + 2 + len;
            if (len < 2 || end > d.length) throw new IOException("truncated jpeg segment");
            if (marker == 0xe1 && (startsWith(d, i + 4, XMP_NS) || startsWith(d, i + 4, XMP_EXT_NS))) {
                dropped.add(new int[] {i, end});
            }
            if (marker == 0xe2 && startsWith(d, i + 4, "MPF\0".getBytes(StandardCharsets.US_ASCII))) mpf = true;
            if (marker >= 0xe0 && marker <= 0xef && dropped.isEmpty()) lastApp = end;
            i = end;
        }
        // first EOI after SOS ends the primary image (entropy-coded data byte-stuffs 0xff)
        int eoi = -1;
        for (int k = i; k + 1 < d.length; k++) {
            if ((d[k] & 0xff) == 0xff && (d[k + 1] & 0xff) == 0xd9) {
                eoi = k;
                break;
            }
        }
        if (eoi < 0) throw new IOException("no EOI");
        int primaryEnd = eoi + 2;
        int trailing = d.length - primaryEnd;
        int keepEnd = primaryEnd;
        if (mpf && trailing > 4 && (d[primaryEnd] & 0xff) == 0xff && (d[primaryEnd + 1] & 0xff) == 0xd8) {
            jp.gainMapLength = trailing; // MPF secondary image (Apple HDR gain map), kept in place
            keepEnd = d.length;
        } // any other trailer would break the Container:Directory offsets: dropped
        // the new XMP goes where the old one was (or after the leading APPn run), i.e. before the MPF
        // APP2, so MPF offsets (relative to its own header) stay valid
        jp.xmpInsertAt = dropped.isEmpty() ? lastApp : dropped.get(0)[0];
        int pos = jp.xmpInsertAt;
        for (int[] r : dropped) {
            if (r[0] > pos) jp.keepRanges.add(new int[] {pos, r[0]});
            pos = Math.max(pos, r[1]);
        }
        jp.keepRanges.add(new int[] {pos, keepEnd});
        return jp;
    }

    private static String xmp(long coverUs, long gainMap, long mp4) {
        StringBuilder sb = new StringBuilder(1024);
        sb.append("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\" x:xmptk=\"Adobe XMP Core 5.1.0-jc003\">\n");
        sb.append("  <rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">\n");
        sb.append("    <rdf:Description rdf:about=\"\"\n");
        sb.append("        xmlns:GCamera=\"http://ns.google.com/photos/1.0/camera/\"\n");
        sb.append("        xmlns:Container=\"http://ns.google.com/photos/1.0/container/\"\n");
        sb.append("        xmlns:Item=\"http://ns.google.com/photos/1.0/container/item/\"\n");
        sb.append("      GCamera:MotionPhoto=\"1\"\n");
        sb.append("      GCamera:MotionPhotoVersion=\"1\"\n");
        sb.append("      GCamera:MotionPhotoPresentationTimestampUs=\"").append(coverUs).append("\">\n");
        sb.append("      <Container:Directory>\n        <rdf:Seq>\n");
        sb.append("          <rdf:li rdf:parseType=\"Resource\">\n");
        sb.append("            <Container:Item\n              Item:Mime=\"image/jpeg\"\n              Item:Semantic=\"Primary\"/>\n");
        sb.append("          </rdf:li>\n");
        if (gainMap > 0) {
            sb.append("          <rdf:li rdf:parseType=\"Resource\">\n");
            sb.append("            <Container:Item\n              Item:Mime=\"image/jpeg\"\n              Item:Length=\"")
                    .append(gainMap).append("\"\n              Item:Semantic=\"GainMap\"/>\n");
            sb.append("          </rdf:li>\n");
        }
        sb.append("          <rdf:li rdf:parseType=\"Resource\">\n");
        sb.append("            <Container:Item\n              Item:Mime=\"video/mp4\"\n              Item:Semantic=\"MotionPhoto\"\n              Item:Length=\"")
                .append(mp4).append("\"\n              Item:Padding=\"0\"/>\n");
        sb.append("          </rdf:li>\n");
        sb.append("        </rdf:Seq>\n      </Container:Directory>\n    </rdf:Description>\n  </rdf:RDF>\n</x:xmpmeta>\n");
        return sb.toString();
    }

    // ---- MOV -> MP4 ----

    private static final class Mov {
        byte[] mp4;
        long coverUs = -1;
        boolean unmirrored;
        boolean mirrored;
        int[] matrix;
    }

    private static final class Box {
        final String type;
        final int off;
        final int hdr;
        final int size;

        Box(String type, int off, int hdr, int size) {
            this.type = type;
            this.off = off;
            this.hdr = hdr;
            this.size = size;
        }

        int body() {
            return off + hdr;
        }

        int end() {
            return off + size;
        }
    }

    private static List<Box> children(byte[] d, int from, int to) throws IOException {
        List<Box> out = new ArrayList<>();
        int o = from;
        while (o + 8 <= to) {
            long size = u32(d, o);
            int hdr = 8;
            if (size == 1) {
                size = u64(d, o + 8);
                hdr = 16;
            } else if (size == 0) {
                size = to - o;
            }
            if (size < hdr || o + size > to) throw new IOException("bad box at " + o);
            out.add(new Box(new String(d, o + 4, 4, StandardCharsets.ISO_8859_1), o, hdr, (int) size));
            o += (int) size;
        }
        return out;
    }

    private static Box child(byte[] d, Box parent, String type) throws IOException {
        if (parent == null) return null;
        for (Box b : children(d, parent.body(), parent.end())) if (b.type.equals(type)) return b;
        return null;
    }

    private static Box path(byte[] d, Box from, String... types) throws IOException {
        Box b = from;
        for (String t : types) b = child(d, b, t);
        return b;
    }

    private static String handler(byte[] d, Box trak) throws IOException {
        Box hdlr = path(d, trak, "mdia", "hdlr");
        return hdlr == null ? "" : new String(d, hdlr.body() + 8, 4, StandardCharsets.ISO_8859_1);
    }

    private static Mov remux(byte[] d, boolean unmirror) throws IOException {
        List<Box> top = children(d, 0, d.length);
        Box moov = null;
        for (Box b : top) if (b.type.equals("moov")) moov = b;
        if (moov == null) throw new IOException("no moov");
        Mov mov = new Mov();

        Box mvhd = child(d, moov, "mvhd");
        if (mvhd == null) throw new IOException("no mvhd");
        long movieScale = d[mvhd.body()] == 1 ? u32(d, mvhd.body() + 20) : u32(d, mvhd.body() + 12);

        ByteArrayOutputStream moovBody = new ByteArrayOutputStream(moov.size);
        List<int[]> patches = new ArrayList<>(); // [offset in moovBody of stco/co64 box, isCo64]
        boolean video = false;
        for (Box b : children(d, moov.body(), moov.end())) {
            if (b.type.equals("trak")) {
                String h = handler(d, b);
                if (h.equals("meta") && mov.coverUs < 0 && contains(d, b.off, b.end(), STILL_KEY)) {
                    mov.coverUs = stillImageUs(d, b, movieScale);
                }
                if (!h.equals("vide") && !h.equals("soun")) continue;
                if (h.equals("vide")) video = true;
                int base = moovBody.size();
                Box stbl = path(d, b, "mdia", "minf", "stbl");
                if (stbl != null) {
                    for (Box s : children(d, stbl.body(), stbl.end())) {
                        if (s.type.equals("stco") || s.type.equals("co64")) {
                            patches.add(new int[] {base + (s.off - b.off) + s.hdr, s.type.equals("co64") ? 1 : 0});
                        }
                    }
                }
                int trakAt = moovBody.size();
                moovBody.write(d, b.off, b.size);
                if (h.equals("vide")) {
                    Box tkhd = child(d, b, "tkhd");
                    if (tkhd != null) tkhdMatrixAt(d, tkhd, b.off, trakAt, mov, unmirror);
                }
            } else if (b.type.equals("meta")) {
                continue; // Apple keys (content identifier etc.)
            } else {
                moovBody.write(d, b.off, b.size);
            }
        }
        if (!video) throw new IOException("no video track");

        byte[] ftyp = {0, 0, 0, 24, 'f', 't', 'y', 'p', 'm', 'p', '4', '2', 0, 0, 0, 0, 'i', 's', 'o', 'm', 'm', 'p', '4', '2'};
        byte[] body = moovBody.toByteArray();
        for (int[] fx : MATRIX_FIX.get()) {
            put32(body, fx[0], fx[1]);
            put32(body, fx[0] + 12, fx[2]);
        }
        MATRIX_FIX.get().clear();
        int moovSize = body.length + 8;

        // new layout: ftyp, moov, then the remaining media boxes in their original order
        List<Box> media = new ArrayList<>();
        for (Box b : top) {
            String t = b.type;
            if (t.equals("ftyp") || t.equals("moov") || t.equals("wide") || t.equals("free") || t.equals("skip")) continue;
            media.add(b);
        }
        long[] newStart = new long[media.size()];
        long pos = ftyp.length + moovSize;
        for (int k = 0; k < media.size(); k++) {
            newStart[k] = pos;
            pos += media.get(k).size;
        }
        for (int[] p : patches) {
            int o = p[0];
            int n = (int) u32(body, o + 4);
            for (int e = 0; e < n; e++) {
                int at = o + 8 + e * (p[1] == 1 ? 8 : 4);
                long old = p[1] == 1 ? u64(body, at) : u32(body, at);
                long nu = -1;
                for (int k = 0; k < media.size(); k++) {
                    Box b = media.get(k);
                    if (old >= b.off && old < b.end()) {
                        nu = old - b.off + newStart[k];
                        break;
                    }
                }
                if (nu < 0) throw new IOException("chunk offset outside media: " + old);
                if (p[1] == 1) put64(body, at, nu);
                else if (nu > 0xffffffffL) throw new IOException("stco overflow");
                else put32(body, at, nu);
            }
        }
        ByteArrayOutputStream out = new ByteArrayOutputStream((int) pos);
        out.write(ftyp);
        byte[] hdr = new byte[8];
        put32(hdr, 0, moovSize);
        hdr[4] = 'm';
        hdr[5] = 'o';
        hdr[6] = 'o';
        hdr[7] = 'v';
        out.write(hdr);
        out.write(body);
        for (Box b : media) out.write(d, b.off, b.size);
        mov.mp4 = out.toByteArray();
        if (mov.coverUs < 0) mov.coverUs = 0;
        return mov;
    }

    /** Presentation time of the still-image-time sample: leading empty edits plus the sample's own time. */
    private static long stillImageUs(byte[] d, Box trak, long movieScale) throws IOException {
        Box mdhd = path(d, trak, "mdia", "mdhd");
        long mediaScale = mdhd == null ? 0 : (d[mdhd.body()] == 1 ? u32(d, mdhd.body() + 20) : u32(d, mdhd.body() + 12));
        long emptyMovie = 0;
        long mediaTime = 0;
        Box elst = path(d, trak, "edts", "elst");
        if (elst != null) {
            int v = d[elst.body()];
            int n = (int) u32(d, elst.body() + 4);
            int o = elst.body() + 8;
            for (int e = 0; e < n; e++) {
                long dur = v == 1 ? u64(d, o) : u32(d, o);
                long mt = v == 1 ? u64(d, o + 8) : (int) u32(d, o + 4);
                o += v == 1 ? 20 : 12;
                if (mt == -1) emptyMovie += dur;
                else {
                    mediaTime = mt;
                    break;
                }
            }
        }
        long us = movieScale > 0 ? emptyMovie * 1_000_000L / movieScale : 0;
        if (mediaScale > 0 && mediaTime > 0) us -= mediaTime * 1_000_000L / mediaScale;
        return Math.max(0, us);
    }


    private static final ThreadLocal<List<int[]>> MATRIX_FIX = ThreadLocal.withInitial(ArrayList::new);

    /**
     * Xiaomi Gallery plays a motion photo with the rotation of the video matrix but drops its mirror
     * (front-camera Live Photos carry a transpose matrix, EXIF orientation 5). Remove the mirror on both
     * sides instead: negate the matrix x column here (transpose -> rotate 90) and map the JPEG orientation
     * 2/4/5/7 -> 1/3/6/8, so cover and motion agree in every player. Records the fix for the copied bytes.
     */
    private static void tkhdMatrixAt(byte[] d, Box tkhd, int trakOff, int trakAt, Mov mov, boolean unmirror) {
        int v = d[tkhd.body()];
        int m = tkhd.body() + 4 + (v == 1 ? 32 : 20) + 16;
        if (m + 36 > tkhd.end()) return;
        long a = (int) u32(d, m), b = (int) u32(d, m + 4), c = (int) u32(d, m + 12), dd = (int) u32(d, m + 16);
        mov.matrix = new int[] {(int) Math.round(a / 65536.0), (int) Math.round(b / 65536.0),
                (int) Math.round(c / 65536.0), (int) Math.round(dd / 65536.0)};
        if (a * dd - b * c >= 0) return;
        mov.mirrored = true;
        if (!unmirror) return;
        int at = trakAt + (m - trakOff);
        MATRIX_FIX.get().add(new int[] {at, (int) -a, (int) -c});
        mov.unmirrored = true;
    }

    /** EXIF Orientation without the mirror: 2->1, 4->3, 5->6, 7->8 (in place, every Exif APP1 found). */
    private static int unmirrorExif(byte[] d) {
        int changed = 0;
        byte[] exif = {'E', 'x', 'i', 'f', 0, 0};
        int from = 0;
        while (true) {
            int at = indexOf(d, exif, from);
            if (at < 0) return changed;
            from = at + 6;
            int t = at + 6;
            if (t + 8 > d.length) return changed;
            boolean le = d[t] == 'I' && d[t + 1] == 'I';
            if (!le && !(d[t] == 'M' && d[t + 1] == 'M')) continue;
            long ifd = rd32(d, t + 4, le);
            int p = (int) (t + ifd);
            if (ifd <= 0 || p + 2 > d.length) continue;
            int n = rd16(d, p, le);
            for (int e = 0; e < n && p + 2 + e * 12 + 12 <= d.length; e++) {
                int en = p + 2 + e * 12;
                if (rd16(d, en, le) != 0x0112) continue;
                int vo = en + 8;
                int o = rd16(d, vo, le);
                int nu = o == 2 ? 1 : o == 4 ? 3 : o == 5 ? 6 : o == 7 ? 8 : o;
                if (nu != o) {
                    if (le) {
                        d[vo] = (byte) nu;
                        d[vo + 1] = 0;
                    } else {
                        d[vo] = 0;
                        d[vo + 1] = (byte) nu;
                    }
                    changed++;
                }
            }
        }
    }

    private static int rd16(byte[] d, int o, boolean le) {
        return le ? (d[o] & 0xff) | ((d[o + 1] & 0xff) << 8) : ((d[o] & 0xff) << 8) | (d[o + 1] & 0xff);
    }

    private static long rd32(byte[] d, int o, boolean le) {
        return le ? (rd16(d, o, true) | ((long) rd16(d, o + 2, true) << 16)) : (((long) rd16(d, o, false) << 16) | rd16(d, o + 2, false));
    }

    // ---- helpers ----

    private static String contentIdAfter(byte[] d, byte[] key) {
        int at = indexOf(d, key, 0);
        while (at >= 0) {
            for (int i = at; i + 36 <= d.length && i < at + 4096; i++) {
                if (isUuid(d, i)) return new String(d, i, 36, StandardCharsets.US_ASCII).toUpperCase();
            }
            at = indexOf(d, key, at + 1);
        }
        // the keys box names it; the value lives in mdat for a timed track, so fall back to any UUID
        int lim = Math.min(d.length, 64 << 10);
        for (int i = 0; i + 36 <= lim; i++) if (isUuid(d, i)) return new String(d, i, 36, StandardCharsets.US_ASCII).toUpperCase();
        return null;
    }

    private static boolean isUuid(byte[] d, int i) {
        for (int k = 0; k < 36; k++) {
            int c = d[i + k] & 0xff;
            if (k == 8 || k == 13 || k == 18 || k == 23) {
                if (c != '-') return false;
            } else if (!((c >= '0' && c <= '9') || (c >= 'A' && c <= 'F') || (c >= 'a' && c <= 'f'))) {
                return false;
            }
        }
        return true;
    }

    static byte[] read(File f) throws IOException {
        long n = f.length();
        if (n <= 0 || n > MAX_INPUT) throw new IOException("size " + n + " " + f);
        byte[] b = new byte[(int) n];
        try (RandomAccessFile r = new RandomAccessFile(f, "r")) {
            r.readFully(b);
        }
        return b;
    }

    private static boolean startsWith(byte[] d, int at, byte[] p) {
        if (at + p.length > d.length) return false;
        for (int i = 0; i < p.length; i++) if (d[at + i] != p[i]) return false;
        return true;
    }

    private static boolean contains(byte[] d, int from, int to, byte[] p) {
        int i = indexOf(d, p, from);
        return i >= 0 && i + p.length <= to;
    }

    private static int indexOf(byte[] d, byte[] p, int from) {
        outer:
        for (int i = Math.max(0, from); i + p.length <= d.length; i++) {
            for (int k = 0; k < p.length; k++) if (d[i + k] != p[k]) continue outer;
            return i;
        }
        return -1;
    }

    private static byte[] concat(byte[] a, byte[] b) {
        byte[] r = new byte[a.length + b.length];
        System.arraycopy(a, 0, r, 0, a.length);
        System.arraycopy(b, 0, r, a.length, b.length);
        return r;
    }

    private static long u32(byte[] d, int o) {
        return ((d[o] & 0xffL) << 24) | ((d[o + 1] & 0xffL) << 16) | ((d[o + 2] & 0xffL) << 8) | (d[o + 3] & 0xffL);
    }

    private static long u64(byte[] d, int o) {
        return (u32(d, o) << 32) | u32(d, o + 4);
    }

    private static void put32(byte[] d, int o, long v) {
        d[o] = (byte) (v >>> 24);
        d[o + 1] = (byte) (v >>> 16);
        d[o + 2] = (byte) (v >>> 8);
        d[o + 3] = (byte) v;
    }

    private static void put64(byte[] d, int o, long v) {
        put32(d, o, v >>> 32);
        put32(d, o + 4, v);
    }

    /** Desktop check: java MotionPhoto.java in.jpg in.mov out.jpg */
    public static void main(String[] a) throws IOException {
        System.out.println("jpeg id=" + jpegContentId(new File(a[0])) + " mov id=" + movContentId(new File(a[1])));
        System.out.println(merge(new File(a[0]), new File(a[1]), new File(a[2])));
    }
}
