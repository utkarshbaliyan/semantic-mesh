package org.semanticmesh;

import org.json.JSONObject;
import java.util.Arrays;
import java.util.List;
import java.util.Locale;

/** Describes an attachment; the file itself travels separately and is verified by size and SHA-256. */
final class MediaDescriptor {
    static final String INVALID = "Choose supported audio or video up to 20 MB.";
    static final List<String> AUDIO = Arrays.asList("m4a", "mp3", "aac", "wav", "caf");
    static final List<String> VIDEO = Arrays.asList("mp4", "mov", "m4v");
    final String id;
    final String kind;
    final String fileExtension;
    final long bytes;
    final String sha256;

    MediaDescriptor(String id, String kind, String fileExtension, long bytes, String sha256) throws Exception {
        this.id = Envelope.uuid(id).toLowerCase(Locale.ROOT);
        this.kind = kind;
        this.fileExtension = fileExtension == null ? "" : fileExtension.toLowerCase(Locale.ROOT);
        this.bytes = bytes;
        this.sha256 = sha256;
        List<String> allowed = "audio".equals(kind) ? AUDIO : "video".equals(kind) ? VIDEO : Arrays.<String>asList();
        if (!allowed.contains(this.fileExtension) || bytes < 1 || bytes > MediaVault.MAX_BYTES
                || sha256 == null || !sha256.matches("^[0-9a-f]{64}$")) throw new Exception(INVALID);
    }
    static MediaDescriptor fromJson(JSONObject j) throws Exception {
        return new MediaDescriptor(j.getString("id"), j.getString("kind"), j.getString("fileExtension"), j.getLong("bytes"), j.getString("sha256"));
    }
    JSONObject toJson() throws Exception {
        return new JSONObject().put("id", id).put("kind", kind).put("fileExtension", fileExtension).put("bytes", bytes).put("sha256", sha256);
    }
    static boolean supported(String kind, String extension) {
        return ("audio".equals(kind) ? AUDIO : VIDEO).contains(extension == null ? "" : extension.toLowerCase(Locale.ROOT));
    }
}
