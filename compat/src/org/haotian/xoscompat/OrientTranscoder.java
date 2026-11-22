package org.haotian.xoscompat;

import android.graphics.SurfaceTexture;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaExtractor;
import android.media.MediaFormat;
import android.media.MediaMuxer;
import android.opengl.EGL14;
import android.opengl.EGLConfig;
import android.opengl.EGLContext;
import android.opengl.EGLDisplay;
import android.opengl.EGLExt;
import android.opengl.EGLSurface;
import android.opengl.GLES20;
import android.os.Handler;
import android.os.HandlerThread;
import android.util.Log;
import android.view.Surface;
import java.io.File;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;

/**
 * Bakes a QuickTime display matrix (rotation and mirror) into the pixels, like Xiaomi's iOS MIShare does
 * for front-camera Live Photos: decode -> SurfaceTexture -> GL quad with the matrix applied -> H.264
 * encoder surface -> MP4 with an identity matrix. Audio is copied as is.
 */
final class OrientTranscoder implements MotionPhoto.VideoFixer {
    private static final String TAG = "HaotianXosCompat";
    private static final int EGL_RECORDABLE_ANDROID = 0x3142;
    private static final int GL_TEXTURE_EXTERNAL_OES = 0x8D65;
    private static final long TIMEOUT_US = 10_000;

    private static final String VS = "attribute vec4 aPos;\nattribute vec4 aTex;\nuniform mat4 uST;\nvarying vec2 vTex;\n"
            + "void main() {\n  gl_Position = aPos;\n  vTex = (uST * aTex).xy;\n}\n";
    private static final String FS = "#extension GL_OES_EGL_image_external : require\nprecision mediump float;\n"
            + "varying vec2 vTex;\nuniform samplerExternalOES sTex;\nvoid main() {\n  gl_FragColor = texture2D(sTex, vTex);\n}\n";

    @Override
    public File fix(File mov, int[] m, File outDir) throws Exception {
        File out = new File(outDir, "." + mov.getName() + ".baked.mp4");
        out.delete();
        long t0 = System.nanoTime();
        try {
            transcode(mov, out, m);
        } catch (Throwable t) {
            out.delete();
            throw t instanceof Exception ? (Exception) t : new Exception(t);
        }
        Log.i(TAG, "Live Photo video baked " + mov.getName() + " -> " + out.length() + " bytes in "
                + (System.nanoTime() - t0) / 1_000_000 + " ms");
        return out;
    }

    private static int findTrack(MediaExtractor ex, String prefix) {
        for (int i = 0; i < ex.getTrackCount(); i++) {
            String mime = ex.getTrackFormat(i).getString(MediaFormat.KEY_MIME);
            if (mime != null && mime.startsWith(prefix)) return i;
        }
        return -1;
    }

    static void transcode(File src, File dst, int[] m) throws Exception {
        MediaExtractor vex = new MediaExtractor();
        MediaCodec decoder = null, encoder = null;
        MediaMuxer muxer = null;
        EGLDisplay dpy = EGL14.EGL_NO_DISPLAY;
        EGLContext ctx = EGL14.EGL_NO_CONTEXT;
        EGLSurface surf = EGL14.EGL_NO_SURFACE;
        SurfaceTexture st = null;
        Surface decSurface = null, encSurface = null;
        HandlerThread cbThread = new HandlerThread("haotian-bake");
        boolean muxStarted = false;
        try {
            vex.setDataSource(src.getPath());
            int vIdx = findTrack(vex, "video/");
            if (vIdx < 0) throw new IOException("no video track");
            MediaFormat vfmt = vex.getTrackFormat(vIdx);
            vfmt.setInteger("rotation-degrees", 0);
            int ws = vfmt.getInteger(MediaFormat.KEY_WIDTH);
            int hs = vfmt.getInteger(MediaFormat.KEY_HEIGHT);
            int a = m[0], b = m[1], c = m[2], d = m[3];
            int wd = (Math.abs(a) * ws + Math.abs(c) * hs) & ~1;
            int hd = (Math.abs(b) * ws + Math.abs(d) * hs) & ~1;
            if (wd <= 0 || hd <= 0) throw new IOException("bad matrix");
            long durUs = vfmt.containsKey(MediaFormat.KEY_DURATION) ? vfmt.getLong(MediaFormat.KEY_DURATION) : 3_000_000L;
            int fps = vfmt.containsKey(MediaFormat.KEY_FRAME_RATE) ? Math.max(1, vfmt.getInteger(MediaFormat.KEY_FRAME_RATE)) : 30;
            long bps = durUs > 0 ? src.length() * 8L * 1_000_000L / durUs : 12_000_000L;
            int bitrate = (int) Math.max(8_000_000L, Math.min(20_000_000L, bps));

            // encoder + EGL window surface on its input
            MediaFormat efmt = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, wd, hd);
            efmt.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface);
            efmt.setInteger(MediaFormat.KEY_BIT_RATE, bitrate);
            efmt.setInteger(MediaFormat.KEY_FRAME_RATE, fps);
            efmt.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1);
            encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC);
            encoder.configure(efmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
            encSurface = encoder.createInputSurface();
            encoder.start();

            dpy = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY);
            int[] ver = new int[2];
            if (!EGL14.eglInitialize(dpy, ver, 0, ver, 1)) throw new IOException("eglInitialize");
            int[] attrs = {EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8,
                    EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT, EGL_RECORDABLE_ANDROID, 1, EGL14.EGL_NONE};
            EGLConfig[] cfg = new EGLConfig[1];
            int[] ncfg = new int[1];
            if (!EGL14.eglChooseConfig(dpy, attrs, 0, cfg, 0, 1, ncfg, 0) || ncfg[0] < 1) throw new IOException("eglChooseConfig");
            ctx = EGL14.eglCreateContext(dpy, cfg[0], EGL14.EGL_NO_CONTEXT,
                    new int[] {EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE}, 0);
            surf = EGL14.eglCreateWindowSurface(dpy, cfg[0], encSurface, new int[] {EGL14.EGL_NONE}, 0);
            if (!EGL14.eglMakeCurrent(dpy, surf, surf, ctx)) throw new IOException("eglMakeCurrent");

            int prog = program();
            int[] tex = new int[1];
            GLES20.glGenTextures(1, tex, 0);
            GLES20.glBindTexture(GL_TEXTURE_EXTERNAL_OES, tex[0]);
            GLES20.glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR);
            GLES20.glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR);
            GLES20.glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE);
            GLES20.glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE);

            cbThread.start();
            final Object frameLock = new Object();
            final boolean[] frameReady = {false};
            st = new SurfaceTexture(tex[0]);
            st.setOnFrameAvailableListener(t -> {
                synchronized (frameLock) {
                    frameReady[0] = true;
                    frameLock.notifyAll();
                }
            }, new Handler(cbThread.getLooper()));
            decSurface = new Surface(st);

            FloatBuffer pos = floats(-1, -1, 1, -1, -1, 1, 1, 1);
            FloatBuffer uv = floats(texCoords(m, ws, hs, wd, hd));
            int aPos = GLES20.glGetAttribLocation(prog, "aPos");
            int aTex = GLES20.glGetAttribLocation(prog, "aTex");
            int uST = GLES20.glGetUniformLocation(prog, "uST");
            float[] stm = new float[16];

            String vmime = vfmt.getString(MediaFormat.KEY_MIME);
            decoder = MediaCodec.createDecoderByType(vmime);
            decoder.configure(vfmt, decSurface, null, 0);
            decoder.start();
            vex.selectTrack(vIdx);

            MediaExtractor aex = new MediaExtractor();
            aex.setDataSource(src.getPath());
            int aIdx = findTrack(aex, "audio/");
            MediaFormat afmt = aIdx >= 0 ? aex.getTrackFormat(aIdx) : null;

            muxer = new MediaMuxer(dst.getPath(), MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4);
            int vTrack = -1, aTrack = -1;
            MediaCodec.BufferInfo di = new MediaCodec.BufferInfo(), ei = new MediaCodec.BufferInfo();
            boolean inDone = false, decDone = false, encDone = false;
            int frames = 0;
            long deadline = System.nanoTime() + 60_000_000_000L;
            while (!encDone) {
                if (System.nanoTime() > deadline) throw new IOException("transcode timeout");
                if (!inDone) {
                    int ii = decoder.dequeueInputBuffer(TIMEOUT_US);
                    if (ii >= 0) {
                        ByteBuffer ib = decoder.getInputBuffer(ii);
                        int n = vex.readSampleData(ib, 0);
                        if (n < 0) {
                            decoder.queueInputBuffer(ii, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM);
                            inDone = true;
                        } else {
                            decoder.queueInputBuffer(ii, 0, n, vex.getSampleTime(), 0);
                            vex.advance();
                        }
                    }
                }
                if (!decDone) {
                    int oi = decoder.dequeueOutputBuffer(di, TIMEOUT_US);
                    if (oi >= 0) {
                        boolean render = di.size > 0;
                        decoder.releaseOutputBuffer(oi, render);
                        if (render) {
                            synchronized (frameLock) {
                                long until = System.currentTimeMillis() + 2500;
                                while (!frameReady[0]) {
                                    long left = until - System.currentTimeMillis();
                                    if (left <= 0) throw new IOException("frame wait timeout");
                                    frameLock.wait(left);
                                }
                                frameReady[0] = false;
                            }
                            st.updateTexImage();
                            st.getTransformMatrix(stm);
                            GLES20.glViewport(0, 0, wd, hd);
                            GLES20.glUseProgram(prog);
                            GLES20.glActiveTexture(GLES20.GL_TEXTURE0);
                            GLES20.glBindTexture(GL_TEXTURE_EXTERNAL_OES, tex[0]);
                            GLES20.glUniformMatrix4fv(uST, 1, false, stm, 0);
                            GLES20.glEnableVertexAttribArray(aPos);
                            GLES20.glVertexAttribPointer(aPos, 2, GLES20.GL_FLOAT, false, 0, pos);
                            GLES20.glEnableVertexAttribArray(aTex);
                            GLES20.glVertexAttribPointer(aTex, 2, GLES20.GL_FLOAT, false, 0, uv);
                            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4);
                            EGLExt.eglPresentationTimeANDROID(dpy, surf, di.presentationTimeUs * 1000L);
                            EGL14.eglSwapBuffers(dpy, surf);
                            frames++;
                        }
                        if ((di.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                            encoder.signalEndOfInputStream();
                            decDone = true;
                        }
                    }
                }
                while (true) {
                    int eo = encoder.dequeueOutputBuffer(ei, decDone ? TIMEOUT_US : 0);
                    if (eo == MediaCodec.INFO_TRY_AGAIN_LATER) break;
                    if (eo == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        if (muxStarted) throw new IOException("encoder format changed twice");
                        vTrack = muxer.addTrack(encoder.getOutputFormat());
                        if (afmt != null) aTrack = muxer.addTrack(afmt);
                        muxer.start();
                        muxStarted = true;
                        continue;
                    }
                    if (eo < 0) continue;
                    ByteBuffer ob = encoder.getOutputBuffer(eo);
                    if ((ei.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) ei.size = 0;
                    if (ei.size > 0) {
                        if (!muxStarted) throw new IOException("encoder output before format");
                        ob.position(ei.offset);
                        ob.limit(ei.offset + ei.size);
                        muxer.writeSampleData(vTrack, ob, ei);
                    }
                    encoder.releaseOutputBuffer(eo, false);
                    if ((ei.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                        encDone = true;
                        break;
                    }
                }
            }
            if (frames == 0) throw new IOException("no frames decoded");
            if (aTrack >= 0) {
                aex.selectTrack(aIdx);
                ByteBuffer ab = ByteBuffer.allocateDirect(1 << 20);
                MediaCodec.BufferInfo ai = new MediaCodec.BufferInfo();
                while (true) {
                    int n = aex.readSampleData(ab, 0);
                    if (n < 0) break;
                    ai.set(0, n, aex.getSampleTime(),
                            (aex.getSampleFlags() & MediaExtractor.SAMPLE_FLAG_SYNC) != 0 ? MediaCodec.BUFFER_FLAG_KEY_FRAME : 0);
                    muxer.writeSampleData(aTrack, ab, ai);
                    aex.advance();
                }
            }
            aex.release();
            muxer.stop();
            muxStarted = false;
        } finally {
            if (decoder != null) try { decoder.stop(); } catch (Throwable ignored) { } finally { decoder.release(); }
            if (encoder != null) try { encoder.stop(); } catch (Throwable ignored) { } finally { encoder.release(); }
            if (muxer != null) try { if (muxStarted) muxer.stop(); } catch (Throwable ignored) { } finally { try { muxer.release(); } catch (Throwable ignored) { } }
            if (dpy != EGL14.EGL_NO_DISPLAY) {
                EGL14.eglMakeCurrent(dpy, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT);
                if (surf != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(dpy, surf);
                if (ctx != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(dpy, ctx);
                EGL14.eglReleaseThread();
                EGL14.eglTerminate(dpy);
            }
            if (decSurface != null) decSurface.release();
            if (encSurface != null) encSurface.release();
            if (st != null) st.release();
            cbThread.quitSafely();
            vex.release();
        }
    }

    /**
     * Texture coordinates for the output quad corners (-1,-1),(1,-1),(-1,1),(1,1). Display coordinates
     * follow QuickTime (row vector, y down): display = source * [[a b][c d]] about the centre, so each
     * output corner maps back through the inverse matrix to a source point. Texture t grows upwards.
     */
    static float[] texCoords(int[] m, int ws, int hs, int wd, int hd) {
        double a = m[0], b = m[1], c = m[2], d = m[3];
        double det = a * d - b * c;
        double i00 = d / det, i01 = -b / det, i10 = -c / det, i11 = a / det;
        float[] out = new float[8];
        double[][] corners = {{0, 0}, {1, 0}, {0, 1}, {1, 1}}; // (u, v-up) of the strip vertices
        for (int k = 0; k < 4; k++) {
            double x = corners[k][0] * wd, y = (1 - corners[k][1]) * hd;
            double dx = x - wd / 2.0, dy = y - hd / 2.0;
            double sx = dx * i00 + dy * i10 + ws / 2.0;
            double sy = dx * i01 + dy * i11 + hs / 2.0;
            out[2 * k] = (float) (sx / ws);
            out[2 * k + 1] = (float) (1 - sy / hs);
        }
        return out;
    }

    private static FloatBuffer floats(float... v) {
        FloatBuffer fb = ByteBuffer.allocateDirect(v.length * 4).order(ByteOrder.nativeOrder()).asFloatBuffer();
        fb.put(v).position(0);
        return fb;
    }

    private static int program() throws IOException {
        int vs = shader(GLES20.GL_VERTEX_SHADER, VS);
        int fs = shader(GLES20.GL_FRAGMENT_SHADER, FS);
        int p = GLES20.glCreateProgram();
        GLES20.glAttachShader(p, vs);
        GLES20.glAttachShader(p, fs);
        GLES20.glLinkProgram(p);
        int[] ok = new int[1];
        GLES20.glGetProgramiv(p, GLES20.GL_LINK_STATUS, ok, 0);
        if (ok[0] == 0) throw new IOException("link: " + GLES20.glGetProgramInfoLog(p));
        return p;
    }

    private static int shader(int type, String src) throws IOException {
        int s = GLES20.glCreateShader(type);
        GLES20.glShaderSource(s, src);
        GLES20.glCompileShader(s);
        int[] ok = new int[1];
        GLES20.glGetShaderiv(s, GLES20.GL_COMPILE_STATUS, ok, 0);
        if (ok[0] == 0) throw new IOException("shader: " + GLES20.glGetShaderInfoLog(s));
        return s;
    }
}
