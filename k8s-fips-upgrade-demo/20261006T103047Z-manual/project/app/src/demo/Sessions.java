package demo;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.time.Instant;
import java.util.Base64;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/**
 * Login sessions live in a signed cookie, so any pod can check them (no shared memory needed).
 * cookie = base64url(payload) + "." + base64url(HMAC(payload))
 */
final class Sessions {
    static final String COOKIE = "FIPSDEMO_SESSION";

    record Session(String principal, String ticketEnctype, long loginEpoch, long expiresEpoch) { }

    private final byte[] key;
    private final String macAlgorithm;
    private final long ttlSeconds;

    Sessions(Config cfg, CryptoProfile profile) throws Exception {
        byte[] k = Files.readAllBytes(Path.of(cfg.sessionKeyFile));
        if (k.length < 32) {
            throw new IllegalStateException("session key must be at least 32 bytes, got " + k.length);
        }
        this.key = k;
        this.macAlgorithm = profile.macAlgorithm;
        this.ttlSeconds = cfg.sessionTtlSeconds;
    }

    String create(String principal, String ticketEnctype) throws Exception {
        long now = Instant.now().getEpochSecond();
        String payload = String.join("|", "v1", macAlgorithm, principal, ticketEnctype,
                Long.toString(now), Long.toString(now + ttlSeconds));
        byte[] raw = payload.getBytes(StandardCharsets.UTF_8);
        Base64.Encoder enc = Base64.getUrlEncoder().withoutPadding();
        return enc.encodeToString(raw) + "." + enc.encodeToString(sign(raw));
    }

    /** Returns null when the cookie is missing, changed by someone, signed the old way, or too old. */
    Session verify(String cookieValue) {
        try {
            if (cookieValue == null) {
                return null;
            }
            int dot = cookieValue.indexOf('.');
            if (dot < 1) {
                return null;
            }
            Base64.Decoder dec = Base64.getUrlDecoder();
            byte[] raw = dec.decode(cookieValue.substring(0, dot));
            byte[] mac = dec.decode(cookieValue.substring(dot + 1));
            if (!MessageDigest.isEqual(sign(raw), mac)) {   // constant-time compare
                return null;
            }
            String[] f = new String(raw, StandardCharsets.UTF_8).split("\\|");
            if (f.length != 6 || !"v1".equals(f[0]) || !macAlgorithm.equals(f[1])) {
                return null;
            }
            long expires = Long.parseLong(f[5]);
            if (Instant.now().getEpochSecond() >= expires) {
                return null;
            }
            return new Session(f[2], f[3], Long.parseLong(f[4]), expires);
        } catch (Exception e) {
            return null;
        }
    }

    private byte[] sign(byte[] data) throws Exception {
        Mac mac = Mac.getInstance(macAlgorithm);
        mac.init(new SecretKeySpec(key, macAlgorithm));
        return mac.doFinal(data);
    }
}
