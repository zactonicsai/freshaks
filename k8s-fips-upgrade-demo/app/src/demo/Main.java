package demo;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import java.io.InputStream;
import java.net.InetSocketAddress;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.Executors;
import java.util.stream.Collectors;

/**
 * A very small web app with four pages:
 *   /        public page   (anyone)
 *   /login   login form    (user name + password, checked by FreeIPA Kerberos)
 *   /secure  secure page   (only after login)
 *   /mtls    machine page  (only with a client certificate issued by FreeIPA = mutual TLS)
 * plus /status (facts about the crypto settings, as JSON) and /healthz (for Kubernetes probes).
 */
public final class Main {
    private final Config cfg;
    private final CryptoProfile profile;
    private final KerberosAuth kerberos;
    private final Sessions sessions;
    private final Pages pages;

    private Main(Config cfg, CryptoProfile profile) throws Exception {
        this.cfg = cfg;
        this.profile = profile;
        this.kerberos = new KerberosAuth(cfg);
        this.sessions = new Sessions(cfg, profile);
        this.pages = new Pages(cfg);
    }

    public static void main(String[] args) throws Exception {
        Config cfg = Config.fromEnv();
        CryptoProfile profile = CryptoProfile.init(cfg);   // first, before any crypto is used
        log("start", "version=" + cfg.version + " profile=" + profile.name + " selfTest=" + profile.selfTest()
                + " kernelFips=" + CryptoProfile.kernelFipsFlag() + " osPolicy=" + CryptoProfile.osCryptoPolicy());
        if (!"passed".equals(profile.selfTest())) {
            log("fatal", "crypto self-test did not pass, refusing to start");
            System.exit(2);
        }
        Main app = new Main(cfg, profile);
        HttpServer server = HttpServer.create(new InetSocketAddress(cfg.port), 64);
        server.createContext("/", app::handle);
        server.setExecutor(Executors.newFixedThreadPool(16));
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            log("stop", "shutting down");
            server.stop(2);
        }));
        server.start();
        log("ready", "listening on port " + cfg.port);
    }

    private void handle(HttpExchange ex) {
        long t0 = System.nanoTime();
        String path = ex.getRequestURI().getPath();
        String method = ex.getRequestMethod();
        int status = 500;
        String who = "-";
        try {
            Sessions.Session session = sessions.verify(cookie(ex, Sessions.COOKIE));
            if (session != null) {
                who = session.principal();
            }
            switch (path) {
                case "/healthz" -> status = send(ex, 200, "text/plain; charset=utf-8", "ok\n");
                case "/status" -> status = send(ex, 200, "application/json", statusJson());
                case "/style.css" -> status = send(ex, 200, "text/css; charset=utf-8",
                        new String(pages.raw("style.css"), StandardCharsets.UTF_8));
                case "/", "/index.html" -> status = send(ex, 200, "text/html; charset=utf-8",
                        pages.render("public.html", common(session)));
                case "/login" -> status = "POST".equals(method) ? doLogin(ex) : loginForm(ex, 200, "");
                case "/logout" -> {
                    ex.getResponseHeaders().add("Set-Cookie", cookieHeader("", 0));
                    status = redirect(ex, "/");
                }
                case "/secure" -> {
                    if (session == null) {
                        status = redirect(ex, "/login");
                    } else {
                        Map<String, String> v = common(session);
                        v.put("ticketEnctype", session.ticketEnctype());
                        v.put("ticketFamily", KerberosAuth.isSha2Enctype(session.ticketEnctype())
                                ? "SHA-2 (FIPS approved)" : "SHA-1 (old style, not allowed on FIPS)");
                        v.put("loginTime", Instant.ofEpochSecond(session.loginEpoch()).toString());
                        v.put("expires", Instant.ofEpochSecond(session.expiresEpoch()).toString());
                        ex.getResponseHeaders().add("Cache-Control", "no-store");
                        status = send(ex, 200, "text/html; charset=utf-8", pages.render("secure.html", v));
                    }
                }
                case "/mtls" -> {
                    Map<String, String> cert = Xfcc.externalClient(
                            ex.getRequestHeaders().getFirst("X-Forwarded-Client-Cert"));
                    Map<String, String> v = common(session);
                    if (cert == null) {
                        v.put("message", "No client certificate was shown to the gateway. "
                                + "This page needs mutual TLS: come back with a certificate issued by FreeIPA.");
                        status = send(ex, 403, "text/html; charset=utf-8", pages.render("error.html", v));
                    } else {
                        who = "cert:" + cert.get("subject");
                        v.put("certSubject", cert.get("subject"));
                        v.put("certDns", cert.getOrDefault("dns", "(none)"));
                        v.put("certHash", cert.getOrDefault("hash", "(none)"));
                        status = send(ex, 200, "text/html; charset=utf-8", pages.render("mtls.html", v));
                    }
                }
                default -> {
                    Map<String, String> v = common(session);
                    v.put("message", "That page does not exist.");
                    status = send(ex, 404, "text/html; charset=utf-8", pages.render("error.html", v));
                }
            }
        } catch (Exception e) {
            log("error", path + " " + e);
            try {
                status = send(ex, 500, "text/plain; charset=utf-8", "internal error\n");
            } catch (Exception ignored) {
                // the client went away
            }
        } finally {
            ex.close();
            if (!"/healthz".equals(path)) {
                log("access", method + " " + path + " status=" + status + " user=" + who + " client=" + clientIp(ex)
                        + " ms=" + (System.nanoTime() - t0) / 1_000_000);
            }
        }
    }

    private int loginForm(HttpExchange ex, int code, String message) throws Exception {
        Map<String, String> v = common(null);
        v.put("message", message);
        return send(ex, code, "text/html; charset=utf-8", pages.render("login.html", v));
    }

    private int doLogin(HttpExchange ex) throws Exception {
        Map<String, String> form = readForm(ex);
        String user = form.getOrDefault("username", "").trim();
        String password = form.getOrDefault("password", "");
        if (user.isEmpty() || password.isEmpty()) {
            return loginForm(ex, 400, "Please type a user name and a password.");
        }
        KerberosAuth.Result r = kerberos.login(user, password.toCharArray());
        if (!r.ok()) {
            log("login", "FAILED user=" + user + " client=" + clientIp(ex) + " reason=" + r.error());
            Thread.sleep(400);   // slow down password guessing a little
            return loginForm(ex, 401, "Login failed. Check the user name and password.");
        }
        log("login", "OK principal=" + r.principal() + " ticketEnctype=" + r.ticketEnctype()
                + " client=" + clientIp(ex));
        ex.getResponseHeaders().add("Set-Cookie",
                cookieHeader(sessions.create(r.principal(), r.ticketEnctype()), cfg.sessionTtlSeconds));
        return redirect(ex, "/secure");
    }

    private Map<String, String> common(Sessions.Session session) {
        Map<String, String> v = new HashMap<>();
        String kernel = CryptoProfile.kernelFipsFlag();
        v.put("profile", profile.name);
        v.put("profileTitle", profile.fips ? "FIPS mode (green)" : "NON-FIPS mode (blue)");
        v.put("bannerClass", profile.fips ? "fips" : "legacy");
        v.put("version", cfg.version);
        v.put("pod", cfg.pod);
        v.put("node", cfg.node);
        v.put("os", CryptoProfile.osName());
        v.put("osPolicy", CryptoProfile.osCryptoPolicy());
        v.put("kernelFips", "1".equals(kernel) ? "ON (real FIPS kernel)"
                : "OFF (value: " + kernel + ") - practice mode, not real FIPS");
        v.put("mac", profile.macAlgorithm);
        v.put("user", session == null ? "nobody (not logged in)" : session.principal());
        v.put("message", "");
        return v;
    }

    private String statusJson() {
        StringBuilder b = new StringBuilder(512);
        b.append('{');
        b.append("\"app\":\"fipsdemo-app\"");
        b.append(",\"version\":").append(Pages.json(cfg.version));
        b.append(",\"cryptoProfile\":").append(Pages.json(profile.name));
        b.append(",\"selfTest\":").append(Pages.json(profile.selfTest()));
        b.append(",\"sessionMac\":").append(Pages.json(profile.macAlgorithm));
        b.append(",\"kernelFipsEnabled\":").append(Pages.json(CryptoProfile.kernelFipsFlag()));
        b.append(",\"osCryptoPolicy\":").append(Pages.json(CryptoProfile.osCryptoPolicy()));
        b.append(",\"os\":").append(Pages.json(CryptoProfile.osName()));
        b.append(",\"java\":").append(Pages.json(System.getProperty("java.version")));
        b.append(",\"javaVendor\":").append(Pages.json(System.getProperty("java.vendor")));
        b.append(",\"securityProviders\":").append(jsonList(CryptoProfile.providerNames()));
        b.append(",\"pod\":").append(Pages.json(cfg.pod));
        b.append(",\"node\":").append(Pages.json(cfg.node));
        b.append(",\"kerberosRealm\":").append(Pages.json(cfg.realm));
        b.append(",\"kerberosValidateTgt\":").append(cfg.validateTgt);
        b.append(",\"keytabEnctypes\":").append(jsonList(kerberos.keytabEnctypes()));
        b.append('}');
        return b.append('\n').toString();
    }

    private static String jsonList(List<String> items) {
        return items.stream().map(Pages::json).collect(Collectors.joining(",", "[", "]"));
    }

    private String cookieHeader(String value, long maxAge) {
        return Sessions.COOKIE + "=" + value + "; Path=/; HttpOnly; SameSite=Strict; Max-Age=" + maxAge
                + (cfg.cookieSecure ? "; Secure" : "");
    }

    private static String cookie(HttpExchange ex, String name) {
        List<String> headers = ex.getRequestHeaders().get("Cookie");
        if (headers == null) {
            return null;
        }
        for (String h : headers) {
            for (String part : h.split(";")) {
                String p = part.trim();
                if (p.startsWith(name + "=")) {
                    return p.substring(name.length() + 1);
                }
            }
        }
        return null;
    }

    private static Map<String, String> readForm(HttpExchange ex) throws Exception {
        Map<String, String> out = new HashMap<>();
        try (InputStream in = ex.getRequestBody()) {
            byte[] body = in.readNBytes(8192);   // a login form is tiny; ignore anything bigger
            for (String pair : new String(body, StandardCharsets.UTF_8).split("&")) {
                int eq = pair.indexOf('=');
                if (eq > 0) {
                    out.put(URLDecoder.decode(pair.substring(0, eq), StandardCharsets.UTF_8),
                            URLDecoder.decode(pair.substring(eq + 1), StandardCharsets.UTF_8));
                }
            }
        }
        return out;
    }

    private static String clientIp(HttpExchange ex) {
        String xff = ex.getRequestHeaders().getFirst("X-Forwarded-For");
        if (xff != null && !xff.isBlank()) {
            return xff.split(",")[0].trim();
        }
        return ex.getRemoteAddress().getAddress().getHostAddress();
    }

    private static int redirect(HttpExchange ex, String to) throws Exception {
        ex.getResponseHeaders().add("Location", to);
        ex.sendResponseHeaders(303, -1);
        return 303;
    }

    private static int send(HttpExchange ex, int code, String type, String body) throws Exception {
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        ex.getResponseHeaders().add("Content-Type", type);
        ex.getResponseHeaders().add("X-Content-Type-Options", "nosniff");
        ex.getResponseHeaders().add("Content-Security-Policy", "default-src 'self'");
        ex.sendResponseHeaders(code, bytes.length);
        ex.getResponseBody().write(bytes);
        return code;
    }

    static void log(String event, String message) {
        System.out.println(Instant.now() + " [" + event + "] " + message);
    }
}
