package com.example.reports;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.Comparator;
import java.util.List;
import java.util.Objects;
import java.util.UUID;
import java.util.stream.Stream;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

/**
 * Stores short notes as small text files on the SHARED volume (NFS).
 *
 * <p>All pods of both applications mount the same folder, so a note written by one pod
 * is visible to every other pod at once. That is what "ReadWriteMany" storage is for.
 * One file per note, written under a temporary name and then renamed, so no reader
 * ever sees a half-written file - a pattern that is safe on NFS.
 */
@Component
public class NoteStore {

    /** How many notes the list shows. */
    private static final int MAX_NOTES = 20;

    private final Path folder;

    public NoteStore(@Value("${app.shared-dir}") String sharedDir) {
        this.folder = Path.of(sharedDir, "notes");
    }

    /** One note, returned to the browser as JSON. */
    public record Note(String id, String author, String app, String pod, String createdAt, String text) {
    }

    public Note add(String author, String app, String pod, String text) {
        try {
            Files.createDirectories(folder);
            String createdAt = Instant.now().truncatedTo(ChronoUnit.SECONDS).toString();
            // The time in milliseconds comes first, so sorting by file name sorts by age.
            String id = System.currentTimeMillis() + "-" + UUID.randomUUID().toString().substring(0, 8);
            // Four header lines, then the text.
            String content = String.join("\n", oneLine(author), oneLine(app), oneLine(pod), createdAt, text);
            Path temporary = folder.resolve(id + ".tmp");
            Path target = folder.resolve(id + ".note");
            Files.writeString(temporary, content, StandardCharsets.UTF_8);
            Files.move(temporary, target, StandardCopyOption.ATOMIC_MOVE);
            return new Note(id, author, app, pod, createdAt, text);
        } catch (IOException e) {
            throw new UncheckedIOException("Could not write to the shared volume " + folder, e);
        }
    }

    public List<Note> list() {
        if (!Files.isDirectory(folder)) {
            return List.of();
        }
        try (Stream<Path> files = Files.list(folder)) {
            return files
                    .filter(file -> file.getFileName().toString().endsWith(".note"))
                    .sorted(Comparator.comparing((Path file) -> file.getFileName().toString()).reversed())
                    .limit(MAX_NOTES)
                    .map(NoteStore::read)
                    .filter(Objects::nonNull)
                    .toList();
        } catch (IOException e) {
            throw new UncheckedIOException("Could not read the shared volume " + folder, e);
        }
    }

    private static Note read(Path file) {
        try {
            List<String> lines = Files.readAllLines(file, StandardCharsets.UTF_8);
            if (lines.size() < 5) {
                return null;
            }
            String name = file.getFileName().toString();
            String id = name.substring(0, name.length() - ".note".length());
            String text = String.join("\n", lines.subList(4, lines.size()));
            return new Note(id, lines.get(0), lines.get(1), lines.get(2), lines.get(3), text);
        } catch (IOException e) {
            // A file that vanished or cannot be read is simply left out of the list.
            return null;
        }
    }

    /** Header values must stay on one line. */
    private static String oneLine(String value) {
        return value == null ? "" : value.replace('\n', ' ').replace('\r', ' ');
    }
}
