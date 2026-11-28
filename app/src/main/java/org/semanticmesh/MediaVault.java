package org.semanticmesh;

import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.util.Set;
import java.util.UUID;

/** Verified attachment files, named id_sha256.ext. 20 MB per file, 200 MB in total. Thread-safe. */
final class MediaVault {
    static final long MAX_BYTES = 20L * 1024 * 1024;
    static final long QUOTA = 200L * 1024 * 1024;
    private final File directory;

    MediaVault(File directory) throws IOException {
        this.directory = directory;
        if (!directory.isDirectory() && !directory.mkdirs()) throw new IOException("Cannot create media folder");
    }
    File file(MediaDescriptor m) { return new File(directory, m.id + "_" + m.sha256 + "." + m.fileExtension); }
    synchronized boolean available(MediaDescriptor m) { File f = file(m); return f.isFile() && f.length() == m.bytes; }

    static String digest(File file) throws Exception {
        MessageDigest sha = MessageDigest.getInstance("SHA-256");
        try (InputStream in = new FileInputStream(file)) {
            byte[] buffer = new byte[65536];
            for (int n; (n = in.read(buffer)) > 0; ) sha.update(buffer, 0, n);
        }
        StringBuilder hex = new StringBuilder();
        for (byte b : sha.digest()) hex.append(String.format(java.util.Locale.ROOT, "%02x", b));
        return hex.toString();
    }
    synchronized MediaDescriptor importFile(File source, String kind, String extension) throws Exception {
        long bytes = source.length();
        if (bytes <= 0 || bytes > MAX_BYTES) throw new Exception(MediaDescriptor.INVALID);
        MediaDescriptor m = new MediaDescriptor(UUID.randomUUID().toString(), kind, extension, bytes, digest(source));
        install(source, m);
        return m;
    }
    synchronized void install(File source, MediaDescriptor m) throws Exception {
        if (source.length() != m.bytes || !digest(source).equals(m.sha256)) throw new Exception(MediaDescriptor.INVALID);
        if (available(m)) return;
        long used = 0;
        File[] files = directory.listFiles();
        if (files != null) for (File f : files) used += f.length();
        if (used + m.bytes > QUOTA) throw new Exception("Media storage limit reached (200 MB).");
        // A crash must not leave a partial file at a path that looks delivered.
        File staging = new File(directory, ".incoming-" + UUID.randomUUID());
        try {
            Files.copy(source.toPath(), staging.toPath(), StandardCopyOption.REPLACE_EXISTING);
            if (staging.length() != m.bytes || !digest(staging).equals(m.sha256)) throw new Exception(MediaDescriptor.INVALID);
            Files.move(staging.toPath(), file(m).toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
        } finally { if (staging.exists()) staging.delete(); }
    }
    /** Removes files whose message has expired. */
    synchronized void prune(Set<String> keepIDs) {
        File[] files = directory.listFiles();
        if (files == null) return;
        for (File f : files) {
            String name = f.getName();
            if (name.startsWith(".incoming-")) continue;
            if (name.length() < 36 || !keepIDs.contains(name.substring(0, 36))) f.delete();
        }
    }
}
