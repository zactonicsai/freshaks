package demo;

/** All settings come from environment variables, so the same code runs in both pods. */
final class Config {
    final int port;
    final String profile;        // "legacy" (non-FIPS) or "fips"
    final String version;
    final String realm;
    final String servicePrincipal;
    final String keytab;
    final boolean validateTgt;
    final String sessionKeyFile;
    final long sessionTtlSeconds;
    final boolean cookieSecure;
    final String webDir;
    final String pod;
    final String node;

    private Config() {
        port = Integer.parseInt(env("APP_PORT", "8080"));
        profile = env("APP_CRYPTO_PROFILE", "legacy").toLowerCase();
        version = env("APP_VERSION", "dev");
        realm = env("KRB_REALM", "FIPSDEMO.TEST");
        servicePrincipal = env("KRB_SERVICE_PRINCIPAL", "HTTP/app.fipsdemo.test@" + realm);
        keytab = env("KRB_KEYTAB", "/etc/fipsdemo/keytab/app.keytab");
        validateTgt = Boolean.parseBoolean(env("KRB_VALIDATE_TGT", "true"));
        sessionKeyFile = env("SESSION_KEY_FILE", "/etc/fipsdemo/session/session.key");
        sessionTtlSeconds = Long.parseLong(env("SESSION_TTL_SECONDS", "1800"));
        cookieSecure = Boolean.parseBoolean(env("COOKIE_SECURE", "true"));
        webDir = env("APP_WEB_DIR", "/opt/app/web");
        pod = env("POD_NAME", env("HOSTNAME", "unknown"));
        node = env("NODE_NAME", "unknown");
    }

    static Config fromEnv() {
        return new Config();
    }

    static String env(String key, String fallback) {
        String v = System.getenv(key);
        return (v == null || v.isBlank()) ? fallback : v.trim();
    }
}
