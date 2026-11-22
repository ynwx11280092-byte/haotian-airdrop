package org.haotian.xoscompat;

import android.graphics.Bitmap;
import android.media.MediaMetadataRetriever;
import java.io.File;
import java.io.FileOutputStream;
import java.io.RandomAccessFile;

/**
 * On-device check, run as root:
 *   CLASSPATH=Haotian-XOS-Compat.apk app_process /system/bin org.haotian.xoscompat.TranscodeTest in.jpg in.mov out.jpg frame.png
 * Merges like the MIShare hook, then grabs the embedded video frame at the cover time as a PNG.
 */
public final class TranscodeTest {
    public static void main(String[] a) throws Exception {
        File out = new File(a[2]);
        MotionPhoto.Result r = MotionPhoto.merge(new File(a[0]), new File(a[1]), out, new OrientTranscoder());
        System.out.println("merge " + r);
        File mp4 = new File(out.getPath() + ".video.mp4");
        try (RandomAccessFile in = new RandomAccessFile(out, "r"); FileOutputStream os = new FileOutputStream(mp4)) {
            byte[] buf = new byte[(int) r.mp4Length];
            in.seek(out.length() - r.mp4Length);
            in.readFully(buf);
            os.write(buf);
        }
        MediaMetadataRetriever mr = new MediaMetadataRetriever();
        mr.setDataSource(mp4.getPath());
        System.out.println("video " + mr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH) + "x"
                + mr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT) + " rotation="
                + mr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION) + " duration="
                + mr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION));
        Bitmap bm = mr.getFrameAtTime(r.coverUs, MediaMetadataRetriever.OPTION_CLOSEST);
        mr.release();
        Bitmap small = Bitmap.createScaledBitmap(bm, bm.getWidth() / 4, bm.getHeight() / 4, true);
        try (FileOutputStream os = new FileOutputStream(a[3])) {
            small.compress(Bitmap.CompressFormat.PNG, 100, os);
        }
        System.out.println("frame " + bm.getWidth() + "x" + bm.getHeight() + " -> " + a[3]);
    }
}
