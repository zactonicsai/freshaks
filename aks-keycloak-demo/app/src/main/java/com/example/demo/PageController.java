package com.example.demo;

import java.util.List;

import org.springframework.http.MediaType;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.core.oidc.user.OidcUser;
import org.springframework.security.web.csrf.CsrfToken;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.util.HtmlUtils;

/**
 * The four pages of the app.
 *
 *   /         public  - anyone
 *   /private  private - any logged-in user
 *   /group    group   - only logged-in users in the "managers" group
 *   /denied   shown when you are logged in but not allowed
 */
@RestController
public class PageController {

    @GetMapping(value = "/", produces = MediaType.TEXT_HTML_VALUE)
    public String home(@AuthenticationPrincipal OidcUser user, CsrfToken csrf) {
        String who = (user == null)
                ? "<p>You are <b>not logged in</b>. <a href=\"/oauth2/authorization/keycloak\">Log in</a></p>"
                : "<p>Hello, <b>" + safe(user.getName()) + "</b>!</p>" + logoutButton(csrf);
        return page("Public page", "<p>Everyone can see this page. No login needed.</p>" + who);
    }

    @GetMapping(value = "/private", produces = MediaType.TEXT_HTML_VALUE)
    public String privatePage(@AuthenticationPrincipal OidcUser user, CsrfToken csrf) {
        return page("Private page",
                "<p>You can see this because you are logged in as <b>" + safe(user.getName()) + "</b>.</p>"
                + "<p>Email: " + safe(user.getEmail()) + "</p>"
                + "<p>Your groups: " + safe(String.valueOf(groupsOf(user))) + "</p>"
                + logoutButton(csrf));
    }

    @GetMapping(value = "/group", produces = MediaType.TEXT_HTML_VALUE)
    public String groupPage(@AuthenticationPrincipal OidcUser user, CsrfToken csrf) {
        return page("Group page",
                "<p>Welcome, <b>" + safe(user.getName()) + "</b>. Only members of the special group can see this.</p>"
                + "<p>Your groups: " + safe(String.valueOf(groupsOf(user))) + "</p>"
                + logoutButton(csrf));
    }

    @RequestMapping(value = "/denied", produces = MediaType.TEXT_HTML_VALUE)
    public String denied() {
        return page("Not allowed", "<p>You are logged in, but you are not in the group this page needs.</p>");
    }

    // ---------- small helpers ----------

    private static List<String> groupsOf(OidcUser user) {
        List<String> groups = user.getIdToken().getClaimAsStringList("groups");
        return groups == null ? List.of() : groups;
    }

    /** Makes text safe to show in a web page (stops sneaky HTML). */
    private static String safe(String text) {
        return text == null ? "" : HtmlUtils.htmlEscape(text);
    }

    /**
     * Logout must be a button (a POST), not a link. The hidden "csrf" value proves
     * the click really came from our page and not from some other website.
     */
    private static String logoutButton(CsrfToken csrf) {
        return "<form method=\"post\" action=\"/logout\">"
                + "<input type=\"hidden\" name=\"" + safe(csrf.getParameterName())
                + "\" value=\"" + safe(csrf.getToken()) + "\">"
                + "<button type=\"submit\">Log out</button></form>";
    }

    private static String page(String title, String body) {
        return "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
                + "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
                + "<title>" + title + "</title>"
                + "<style>body{font-family:sans-serif;max-width:40rem;margin:2rem auto;padding:0 1rem}"
                + "nav a{margin-right:1rem}</style></head><body>"
                + "<nav><a href=\"/\">Public</a><a href=\"/private\">Private</a><a href=\"/group\">Group</a></nav>"
                + "<h1>" + title + "</h1>" + body + "</body></html>";
    }
}
