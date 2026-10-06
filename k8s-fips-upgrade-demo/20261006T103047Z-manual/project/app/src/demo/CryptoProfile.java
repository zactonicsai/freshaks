package demo;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.security.Provider;
import java.security.Security;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.List;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLEngine;

/**
 * The "crypto profile" is the one switch that separates the old pod from the new pod.
 *   legacy = how a typical non-FIPS app is set up (SHA-1 era choices still allowed)
 *   fips   = only FIPS-approved, SHA-2 based choices
 */
final class CryptoProfile {
    final boolean fips;
    final String name;
    final String macAlgorithm;
    private String selfTest = "not-run";

    // Copied from the RHEL 9 "FIPS" system crypto policy (/usr/share/crypto-policies/FIPS/java.txt).
    // On Red Hat's OpenJDK the operating system already applies these; setting them here too
    // makes the app behave the same on any Java.
    private static final String FIPS_CERTPATH_DISABLED =
        "MD2, MD5withDSA, MD5withECDSA, RIPEMD160withRSA, RIPEMD160withECDSA, RIPEMD160withRSAandMGF1, "
        + "MD5withRSA, SHA1withRSA, SHA1withDSA, SHA1withECDSA, SHA224withDSA, SHA256withDSA, SHA384withDSA, "
        + "SHA512withDSA, Ed25519, Ed448, SHA1withRSAandMGF1, RSA keySize < 2048, DSA keySize < 2048, "
        + "DH keySize < 2048, EC keySize < 256, SHA1, MD5";
    private static final String FIPS_TLS_DISABLED =
        "MD2, MD5withDSA, MD5withECDSA, RIPEMD160withRSA, RIPEMD160withECDSA, RIPEMD160withRSAandMGF1, "
        + "MD5withRSA, SHA1withRSA, SHA1withDSA, SHA1withECDSA, SHA224withDSA, SHA256withDSA, SHA384withDSA, "
        + "SHA512withDSA, Ed25519, Ed448, SHA1withRSAandMGF1, RSA keySize < 2048, DSA keySize < 2048, "
        + "DH keySize < 2048, EC keySize < 256, TLSv1.1, TLSv1, SSLv3, SSLv2, DTLSv1.0, RSAPSK, "
        + "TLS_RSA_WITH_AES_256_CBC_SHA256, TLS_RSA_WITH_AES_256_CBC_SHA, TLS_RSA_WITH_AES_128_CBC_SHA256, "
        + "TLS_RSA_WITH_AES_128_CBC_SHA, TLS_RSA_WITH_AES_256_GCM_SHA384, TLS_RSA_WITH_AES_128_GCM_SHA256, "
        + "DHE_DSS, RSA_EXPORT, DHE_DSS_EXPORT, DHE_RSA_EXPORT, DH_DSS_EXPORT, DH_RSA_EXPORT, DH_anon, "
        + "ECDH_anon, DH_RSA, DH_DSS, ECDH, ChaCha20-Poly1305, AES_256_CBC, AES_128_CBC, 3DES_EDE_CBC, "
        + "DES_CBC, RC4_40, RC4_128, DES40_CBC, RC2, anon, NULL, HmacSHA1, HmacMD5";
    private static final String FIPS_NAMED_GROUPS = "secp256r1, secp384r1, secp521r1, ffdhe2048, ffdhe3072";

    private CryptoProfile(boolean fips) {
        this.fips = fips;
        this.name = fips ? "fips" : "legacy";
        // Session cookies are signed with an HMAC. SHA-1 is the old choice, SHA-256 is the SHA-2 choice.
        this.macAlgorithm = fips ? "HmacSHA256" : "HmacSHA1";
    }

    /** Must run first thing in main(), before any TLS or Kerberos class is used. */
    static CryptoProfile init(Config cfg) {
        CryptoProfile p = new CryptoProfile("fips".equals(cfg.profile));
        if (p.fips) {
            Security.setProperty("jdk.certpath.disabledAlgorithms", FIPS_CERTPATH_DISABLED);
            Security.setProperty("jdk.tls.disabledAlgorithms", FIPS_TLS_DISABLED);
            System.setProperty("jdk.tls.namedGroups", FIPS_NAMED_GROUPS);
            System.setProperty("jdk.tls.ephemeralDHKeySize", "2048");
        }
        p.selfTest = p.runSelfTest();
        return p;
    }

    String selfTest() {
        return selfTest;
    }

    /**
     * FIPS modules run "known answer tests" when they start: do a calculation whose right
     * answer is already known and refuse to work if the result is different. We copy that idea.
     */
    private String runSelfTest() {
        try {
            byte[] key = new byte[20];
            java.util.Arrays.fill(key, (byte) 0x0b);
            byte[] msg = "Hi There".getBytes(StandardCharsets.US_ASCII);
            expect("SHA-256", HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                    .digest("abc".getBytes(StandardCharsets.US_ASCII))),
                    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
            expect("HmacSHA256", hmacHex("HmacSHA256", key, msg),
                    "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7");
            if (!fips) {
                expect("HmacSHA1", hmacHex("HmacSHA1", key, msg), "b617318655057264e28bc0b6fb378c8ef146be00");
            } else {
                SSLEngine engine = SSLContext.getDefault().createSSLEngine();
                for (String proto : engine.getEnabledProtocols()) {
                    if (proto.equals("TLSv1") || proto.equals("TLSv1.1") || proto.startsWith("SSL")) {
                        return "FAILED: old protocol still enabled: " + proto;
                    }
                }
                for (String suite : engine.getEnabledCipherSuites()) {
                    if (suite.contains("CHACHA20") || suite.contains("_CBC_") || suite.startsWith("TLS_RSA_")
                            || suite.endsWith("_SHA")) {
                        return "FAILED: non-FIPS cipher suite still enabled: " + suite;
                    }
                }
            }
            return "passed";
        } catch (Exception e) {
            return "FAILED: " + e;
        }
    }

    private static void expect(String what, String got, String want) {
        if (!want.equals(got)) {
            throw new IllegalStateException(what + " known-answer test gave " + got);
        }
    }

    private static String hmacHex(String alg, byte[] key, byte[] msg) throws Exception {
        Mac mac = Mac.getInstance(alg);
        mac.init(new SecretKeySpec(key, alg));
        return HexFormat.of().formatHex(mac.doFinal(msg));
    }

    /** "1" when the Linux kernel was booted in FIPS mode. A container sees its HOST's value. */
    static String kernelFipsFlag() {
        try {
            return Files.readString(Path.of("/proc/sys/crypto/fips_enabled")).trim();
        } catch (Exception e) {
            return "unavailable";
        }
    }

    /** The system-wide crypto policy of a RHEL-family image: DEFAULT, FIPS, ... */
    static String osCryptoPolicy() {
        try {
            for (String line : Files.readAllLines(Path.of("/etc/crypto-policies/config"))) {
                String t = line.trim();
                if (!t.isEmpty() && !t.startsWith("#")) {
                    return t;
                }
            }
        } catch (Exception e) {
            // not a RHEL-family system
        }
        return "unavailable";
    }

    static String osName() {
        try {
            for (String line : Files.readAllLines(Path.of("/etc/os-release"))) {
                if (line.startsWith("PRETTY_NAME=")) {
                    return line.substring("PRETTY_NAME=".length()).replace("\"", "");
                }
            }
        } catch (Exception e) {
            // ignore
        }
        return System.getProperty("os.name", "unknown");
    }

    static List<String> providerNames() {
        List<String> names = new ArrayList<>();
        for (Provider p : Security.getProviders()) {
            names.add(p.getName());
        }
        return names;
    }
}
