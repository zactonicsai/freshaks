package com.example.demo;

import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.core.oidc.user.OidcUser;
import org.springframework.security.web.csrf.CsrfToken;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;

/**
 * The small JSON API that the static page (index.html + app.js) talks to.
 */
@RestController
@RequestMapping("/api")
public class ApiController {

    private static final int MAX_NOTE_LENGTH = 280;

    private final String appName;
    private final String version;
    private final String podName;
    private final String otherAppName;
    private final String otherAppUrl;
    private final String allowedUrl;
    private final String blockedUrl;
    private final NoteStore notes;

    /** Plain JDK HTTP client for the egress demonstration; it never follows redirects. */
    private final HttpClient httpClient = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(4))
            .followRedirects(HttpClient.Redirect.NEVER)
            .build();

    public ApiController(
            @Value("${app.name}") String appName,
            @Value("${app.version}") String version,
            @Value("${app.pod}") String podName,
            @Value("${app.other-app.name}") String otherAppName,
            @Value("${app.other-app.url}") String otherAppUrl,
            @Value("${app.egress.allowed-url}") String allowedUrl,
            @Value("${app.egress.blocked-url}") String blockedUrl,
            NoteStore notes) {
        this.appName = appName;
        this.version = version;
        this.podName = podName;
        this.otherAppName = otherAppName;
        this.otherAppUrl = otherAppUrl;
        this.allowedUrl = allowedUrl;
        this.blockedUrl = blockedUrl;
        this.notes = notes;
    }

    /** Public: which application, which version and which pod answered this request. */
    @GetMapping("/info")
    public Map<String, Object> info() {
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("app", appName);
        result.put("version", version);
        result.put("pod", podName);
        result.put("otherAppName", otherAppName);
        result.put("otherAppUrl", otherAppUrl);
        return result;
    }

    /** Who is signed in, taken from the ID token that Keycloak issued. */
    @GetMapping("/me")
    public Map<String, Object> me(@AuthenticationPrincipal OidcUser user) {
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("username", user.getPreferredUsername());
        result.put("name", user.getFullName());
        result.put("email", user.getEmail());
        result.put("roles", visibleRoles(user));
        result.put("issuer", String.valueOf(user.getIssuer()));
        result.put("sessionPod", podName);
        return result;
    }

    /** Only for the realm role "admin" (enforced in SecurityConfig). */
    @GetMapping("/admin")
    public Map<String, Object> admin(@AuthenticationPrincipal OidcUser user) {
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("message", "Hello " + user.getPreferredUsername() + ", you have the admin role.");
        result.put("app", appName);
        result.put("pod", podName);
        return result;
    }

    /**
     * The anti-forgery token for the logout form. (For JSON calls the page reads the
     * XSRF-TOKEN cookie instead and sends it back as X-XSRF-TOKEN header.)
     */
    @GetMapping("/csrf")
    public Map<String, String> csrf(CsrfToken token) {
        Map<String, String> result = new LinkedHashMap<>();
        result.put("parameterName", token.getParameterName());
        result.put("token", token.getToken());
        return result;
    }

    /** The newest notes from the shared volume. */
    @GetMapping("/notes")
    public List<NoteStore.Note> listNotes() {
        return notes.list();
    }

    /** Body of POST /api/notes. */
    public record NoteRequest(String text) {
    }

    /** Writes a note to the shared volume. */
    @PostMapping("/notes")
    @ResponseStatus(HttpStatus.CREATED)
    public NoteStore.Note addNote(@RequestBody NoteRequest request, @AuthenticationPrincipal OidcUser user) {
        String text = request.text() == null ? "" : request.text().replace("\r", "").strip();
        if (text.isEmpty() || text.length() > MAX_NOTE_LENGTH) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST,
                    "A note needs 1 to " + MAX_NOTE_LENGTH + " characters.");
        }
        return notes.add(user.getPreferredUsername(), appName, podName, text);
    }

    /** Calls the one external host that the mesh allows (through the egress gateway). */
    @GetMapping("/egress")
    public Map<String, Object> egressAllowed() {
        return call(allowedUrl);
    }

    /** Calls a host that is NOT on the allow list; the sidecar must block it. */
    @GetMapping("/egress/blocked")
    public Map<String, Object> egressBlocked() {
        return call(blockedUrl);
    }

    private Map<String, Object> call(String url) {
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("url", url);
        try {
            HttpRequest request = HttpRequest.newBuilder(URI.create(url))
                    .timeout(Duration.ofSeconds(6))
                    .GET()
                    .build();
            HttpResponse<String> response = httpClient.send(request, HttpResponse.BodyHandlers.ofString());
            String body = response.body() == null ? "" : response.body();
            result.put("reachable", true);
            result.put("status", response.statusCode());
            result.put("body", body.length() > 200 ? body.substring(0, 200) : body);
        } catch (IOException e) {
            // A blocked host shows up here: the sidecar closes the connection.
            result.put("reachable", false);
            result.put("error", e.getClass().getSimpleName() + ": " + e.getMessage());
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            result.put("reachable", false);
            result.put("error", "interrupted");
        }
        return result;
    }

    /** The roles from the token without Keycloak's built-in technical roles. */
    private static List<String> visibleRoles(OidcUser user) {
        List<String> roles = user.getClaimAsStringList("roles");
        if (roles == null) {
            return List.of();
        }
        return roles.stream()
                .filter(role -> !role.startsWith("default-roles-"))
                .filter(role -> !role.equals("offline_access") && !role.equals("uma_authorization"))
                .sorted()
                .toList();
    }
}
