package demo;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Reads the X-Forwarded-Client-Cert header that the Istio gateway adds after it has checked a
 * visitor's client certificate (mutual TLS). Format: elements split by "," and each element is
 * key=value pairs split by ";". Values may be in double quotes and then may contain , and ;.
 */
final class Xfcc {
    private Xfcc() { }

    static List<Map<String, String>> parse(String header) {
        List<Map<String, String>> out = new ArrayList<>();
        if (header == null || header.isBlank()) {
            return out;
        }
        for (String element : split(header, ',')) {
            Map<String, String> kv = new LinkedHashMap<>();
            for (String pair : split(element, ';')) {
                int eq = pair.indexOf('=');
                if (eq > 0) {
                    String v = pair.substring(eq + 1).trim();
                    if (v.length() >= 2 && v.startsWith("\"") && v.endsWith("\"")) {
                        v = v.substring(1, v.length() - 1).replace("\\\"", "\"");
                    }
                    kv.put(pair.substring(0, eq).trim().toLowerCase(), v);
                }
            }
            if (!kv.isEmpty()) {
                out.add(kv);
            }
        }
        return out;
    }

    /**
     * The visitor's certificate is the element with a real Subject. The hop between the gateway
     * and this pod uses mesh certificates, which have an empty Subject and a spiffe:// name.
     */
    static Map<String, String> externalClient(String header) {
        for (Map<String, String> e : parse(header)) {
            String subject = e.get("subject");
            if (subject != null && !subject.isBlank()) {
                return e;
            }
        }
        return null;
    }

    private static List<String> split(String s, char sep) {
        List<String> parts = new ArrayList<>();
        StringBuilder cur = new StringBuilder();
        boolean quoted = false;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c == '\\' && quoted && i + 1 < s.length()) {
                cur.append(c).append(s.charAt(++i));
            } else if (c == '"') {
                quoted = !quoted;
                cur.append(c);
            } else if (c == sep && !quoted) {
                parts.add(cur.toString());
                cur.setLength(0);
            } else {
                cur.append(c);
            }
        }
        parts.add(cur.toString());
        return parts;
    }
}
