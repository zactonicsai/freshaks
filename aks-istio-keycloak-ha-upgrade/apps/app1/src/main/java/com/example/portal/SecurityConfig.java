package com.example.portal;

import java.util.Collection;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.HttpStatus;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.authority.mapping.GrantedAuthoritiesMapper;
import org.springframework.security.oauth2.client.oidc.web.logout.OidcClientInitiatedLogoutSuccessHandler;
import org.springframework.security.oauth2.client.registration.ClientRegistration;
import org.springframework.security.oauth2.client.registration.ClientRegistrationRepository;
import org.springframework.security.oauth2.client.registration.InMemoryClientRegistrationRepository;
import org.springframework.security.oauth2.core.AuthorizationGrantType;
import org.springframework.security.oauth2.core.ClientAuthenticationMethod;
import org.springframework.security.oauth2.core.oidc.user.OidcUserAuthority;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.security.web.authentication.HttpStatusEntryPoint;
import org.springframework.security.web.servlet.util.matcher.PathPatternRequestMatcher;

/**
 * Login with OpenID Connect (OIDC) through Keycloak.
 *
 * <p>The important detail for Kubernetes: Keycloak is reachable under TWO addresses.
 * <ul>
 *   <li>The PUBLIC address (https://keycloak.&lt;domain&gt;) is what the browser uses, and
 *       it is the "issuer" written into every token.</li>
 *   <li>The INTERNAL address (http://keycloak.keycloak.svc.cluster.local:8080) is what this
 *       pod uses to swap the login code for tokens and to fetch the signing keys. That
 *       call stays inside the service mesh (encrypted by Istio's mutual TLS).</li>
 * </ul>
 * Spring's automatic discovery ("issuer-uri") would insist that both are the same, so
 * the endpoints are listed here one by one instead.
 */
@Configuration
public class SecurityConfig {

    @Bean
    ClientRegistrationRepository clientRegistrationRepository(
            @Value("${app.oidc.client-id}") String clientId,
            @Value("${app.oidc.client-secret}") String clientSecret,
            @Value("${app.oidc.public-issuer}") String publicIssuer,
            @Value("${app.oidc.internal-issuer}") String internalIssuer) {

        String publicEndpoints = publicIssuer + "/protocol/openid-connect";
        String internalEndpoints = internalIssuer + "/protocol/openid-connect";

        ClientRegistration keycloak = ClientRegistration.withRegistrationId("keycloak")
                .clientName("Keycloak")
                .clientId(clientId)
                .clientSecret(clientSecret)
                .clientAuthenticationMethod(ClientAuthenticationMethod.CLIENT_SECRET_BASIC)
                .authorizationGrantType(AuthorizationGrantType.AUTHORIZATION_CODE)
                // {baseUrl} is taken from the request, so it is the public https address.
                .redirectUri("{baseUrl}/login/oauth2/code/{registrationId}")
                .scope("openid", "profile", "email")
                // Must match the "iss" claim of the ID token exactly.
                .issuerUri(publicIssuer)
                // The browser is sent here to log in (public address).
                .authorizationUri(publicEndpoints + "/auth")
                // This pod calls these two itself (internal address).
                .tokenUri(internalEndpoints + "/token")
                .jwkSetUri(internalEndpoints + "/certs")
                // The claim that becomes the user name.
                .userNameAttributeName("preferred_username")
                // Where the browser is sent at logout (public address).
                .providerConfigurationMetadata(Map.of("end_session_endpoint", publicEndpoints + "/logout"))
                .build();

        return new InMemoryClientRegistrationRepository(keycloak);
    }

    @Bean
    SecurityFilterChain securityFilterChain(HttpSecurity http, ClientRegistrationRepository registrations)
            throws Exception {

        // After the local logout, also end the single sign-on session in Keycloak,
        // then come back to this application's start page.
        OidcClientInitiatedLogoutSuccessHandler keycloakLogout =
                new OidcClientInitiatedLogoutSuccessHandler(registrations);
        keycloakLogout.setPostLogoutRedirectUri("{baseUrl}/");

        http
            .authorizeHttpRequests(requests -> requests
                // The static page, the version endpoint and the health probes are public.
                .requestMatchers("/", "/index.html", "/assets/**", "/favicon.ico", "/error",
                        "/api/info", "/actuator/health/**").permitAll()
                // Only users with the Keycloak realm role "admin".
                .requestMatchers("/api/admin/**").hasRole("admin")
                // Everything else needs a login.
                .anyRequest().authenticated())
            .oauth2Login(login -> login
                .userInfoEndpoint(userInfo -> userInfo.userAuthoritiesMapper(rolesFromIdToken())))
            .exceptionHandling(errors -> errors
                // API calls get a plain "401 Unauthorized" instead of a redirect to the
                // login page; the JavaScript in the page then shows the sign-in button.
                .defaultAuthenticationEntryPointFor(
                        new HttpStatusEntryPoint(HttpStatus.UNAUTHORIZED),
                        PathPatternRequestMatcher.pathPattern("/api/**")))
            .logout(logout -> logout.logoutSuccessHandler(keycloakLogout))
            // Protection against cross-site request forgery for single-page apps: the
            // token is sent as cookie XSRF-TOKEN and must come back in the header
            // X-XSRF-TOKEN (or as form field _csrf) on every POST.
            .csrf(csrf -> csrf.spa());

        return http.build();
    }

    /**
     * Turns the "roles" claim of the ID token (filled by a mapper in the Keycloak realm)
     * into Spring Security roles: "admin" becomes ROLE_admin.
     */
    private static GrantedAuthoritiesMapper rolesFromIdToken() {
        return (Collection<? extends GrantedAuthority> authorities) -> {
            Set<GrantedAuthority> mapped = new HashSet<>(authorities);
            for (GrantedAuthority authority : authorities) {
                if (authority instanceof OidcUserAuthority oidcAuthority) {
                    List<String> roles = oidcAuthority.getIdToken().getClaimAsStringList("roles");
                    if (roles != null) {
                        for (String role : roles) {
                            mapped.add(new SimpleGrantedAuthority("ROLE_" + role));
                        }
                    }
                }
            }
            return mapped;
        };
    }
}
