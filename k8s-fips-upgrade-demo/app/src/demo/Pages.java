package demo;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Map;

/** Tiny HTML template helper: replaces {{name}} in files from the web folder. Values are escaped. */
final class Pages {
    private final Path webDir;

    Pages(Config cfg) {
        this.webDir = Path.of(cfg.webDir);
    }

    String render(String file, Map<String, String> values) throws Exception {
        String html = Files.readString(webDir.resolve(file), StandardCharsets.UTF_8);
        for (Map.Entry<String, String> e : values.entrySet()) {
            html = html.replace("{{" + e.getKey() + "}}", escape(e.getValue()));
        }
        return html;
    }

    byte[] raw(String file) throws Exception {
        return Files.readAllBytes(webDir.resolve(file));
    }

    static String escape(String s) {
        if (s == null) {
            return "";
        }
        StringBuilder b = new StringBuilder(s.length() + 16);
        for (char c : s.toCharArray()) {
            switch (c) {
                case '&' -> b.append("&amp;");
                case '<' -> b.append("&lt;");
                case '>' -> b.append("&gt;");
                case '"' -> b.append("&quot;");
                case '\'' -> b.append("&#39;");
                default -> b.append(c);
            }
        }
        return b.toString();
    }

    static String json(String s) {
        if (s == null) {
            return "null";
        }
        StringBuilder b = new StringBuilder("\"");
        for (char c : s.toCharArray()) {
            switch (c) {
                case '"' -> b.append("\\\"");
                case '\\' -> b.append("\\\\");
                case '\n' -> b.append("\\n");
                case '\r' -> b.append("\\r");
                case '\t' -> b.append("\\t");
                default -> {
                    if (c < 0x20) {
                        b.append(String.format("\\u%04x", (int) c));
                    } else {
                        b.append(c);
                    }
                }
            }
        }
        return b.append('"').toString();
    }
}
