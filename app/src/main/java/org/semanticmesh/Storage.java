package org.semanticmesh;

import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;

/** Small atomic JSON file helpers shared by the contact and group books. */
final class Storage {
    private Storage() {}
    static String read(File file) throws IOException { return new String(Files.readAllBytes(file.toPath()), StandardCharsets.UTF_8); }
    static void writeAtomic(File file, String text) throws IOException {
        File dir = file.getAbsoluteFile().getParentFile();
        if (dir != null && !dir.isDirectory() && !dir.mkdirs()) throw new IOException("Cannot create " + dir);
        File staging = new File(dir, "." + file.getName() + ".tmp");
        Files.write(staging.toPath(), text.getBytes(StandardCharsets.UTF_8));
        Files.move(staging.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
    }
}
