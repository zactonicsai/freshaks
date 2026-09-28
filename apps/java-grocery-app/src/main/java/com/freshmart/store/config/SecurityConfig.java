package com.freshmart.store.config;

import java.io.IOException;
import java.util.Collection;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.authority.mapping.GrantedAuthoritiesMapper;
import org.springframework.security.oauth2.client.oidc.web.logout.OidcClientInitiatedLogoutSuccessHandler;
import org.springframework.security.oauth2.client.registration.ClientRegistrationRepository;
import org.springframework.security.oauth2.client.web.DefaultOAuth2AuthorizationRequestResolver;
import org.springframework.security.oauth2.client.web.OAuth2AuthorizationRequestCustomizers;
import org.springframework.security.oauth2.core.oidc.user.OidcUserAuthority;
import org.springframework.security.oauth2.core.user.OAuth2UserAuthority;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationConverter;
import org.springframework.security.oauth2.server.resource.authentication.JwtGrantedAuthoritiesConverter;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.security.web.access.AccessDeniedHandler;
import org.springframework.security.web.authentication.HttpStatusEntryPoint;
import org.springframework.security.web.csrf.CookieCsrfTokenRepository;
import org.springframework.security.web.csrf.CsrfException;
import org.springframework.security.web.csrf.CsrfTokenRequestAttributeHandler;
import org.springframework.security.web.util.matcher.RequestMatcher;

/**
 * The security guard for the whole store.
 *
 * <ul>
 *   <li>Browser visitors log in through Keycloak (OpenID Connect) — like getting a badge at the front office.</li>
 *   <li>API clients (Go / curl inspectors) send "Authorization: Bearer &lt;token&gt;" instead of logging in.</li>
 *   <li>The "roles" claim of the token becomes Spring roles: shopper -> ROLE_shopper, etc.</li>
 *   <li>Each door (URL) says which badge it needs.</li>
 * </ul>
 */
@Configuration
@EnableWebSecurity
@EnableMethodSecurity
public class SecurityConfig {

    public static final String ROLE_SHOPPER = "shopper";
    public static final String ROLE_CASHIER = "cashier";
    public static final String ROLE_MANAGER = "manager";

    @Value("${freshmart.roles-claim:roles}")
    private String rolesClaim;

    @Bean
    public SecurityFilterChain securityFilterChain(HttpSecurity http,
                                                   ClientRegistrationRepository clientRegistrations) throws Exception {

        // Requests carrying a Bearer token are API calls: no CSRF cookie needed for them.
        RequestMatcher bearerRequests = new RequestMatcher() {
            @Override
            public boolean matches(HttpServletRequest request) {
                String header = request.getHeader("Authorization");
                return header != null && header.startsWith("Bearer ");
            }
        };
        RequestMatcher apiRequests = new RequestMatcher() {
            @Override
            public boolean matches(HttpServletRequest request) {
                return request.getRequestURI().startsWith("/api/");
            }
        };

        // Load the CSRF token on every request so the XSRF-TOKEN cookie is always present for app.js.
        CsrfTokenRequestAttributeHandler csrfHandler = new CsrfTokenRequestAttributeHandler();
        csrfHandler.setCsrfRequestAttributeName(null);

        OidcClientInitiatedLogoutSuccessHandler logoutHandler =
                new OidcClientInitiatedLogoutSuccessHandler(clientRegistrations);
        logoutHandler.setPostLogoutRedirectUri("{baseUrl}/");

        // PKCE (a one-time secret per login) — the realm marks our client "pkce.code.challenge.method=S256".
        DefaultOAuth2AuthorizationRequestResolver authRequestResolver =
                new DefaultOAuth2AuthorizationRequestResolver(clientRegistrations, "/oauth2/authorization");
        authRequestResolver.setAuthorizationRequestCustomizer(OAuth2AuthorizationRequestCustomizers.withPkce());

        http
            .authorizeHttpRequests(auth -> auth
                // ---- doors that are open to everyone ----
                .requestMatchers("/", "/index.html", "/css/**", "/js/**", "/img/**", "/favicon.ico",
                        "/error", "/app/forbidden.html", "/api/public/**", "/actuator/health/**").permitAll()
                // ---- doors that need a specific badge ----
                .requestMatchers("/app/office.html").hasRole(ROLE_MANAGER)
                .requestMatchers("/app/register.html").hasAnyRole(ROLE_CASHIER, ROLE_MANAGER)
                // ---- everything else: any badge, but you must be logged in ----
                .anyRequest().authenticated()
            )
            .csrf(csrf -> csrf
                .csrfTokenRepository(CookieCsrfTokenRepository.withHttpOnlyFalse())
                .csrfTokenRequestHandler(csrfHandler)
                .ignoringRequestMatchers(bearerRequests)
            )
            .oauth2Login(login -> login
                .authorizationEndpoint(endpoint -> endpoint.authorizationRequestResolver(authRequestResolver))
                .userInfoEndpoint(userInfo -> userInfo.userAuthoritiesMapper(userAuthoritiesMapper()))
                .defaultSuccessUrl("/app/shop.html")
            )
            .oauth2ResourceServer(rs -> rs
                .jwt(jwt -> jwt.jwtAuthenticationConverter(jwtAuthenticationConverter()))
            )
            .exceptionHandling(ex -> ex
                // API calls without a badge get a plain 401 instead of a redirect to the login page
                .defaultAuthenticationEntryPointFor(new HttpStatusEntryPoint(HttpStatus.UNAUTHORIZED), apiRequests)
                .accessDeniedHandler(accessDeniedHandler())
            )
            .logout(logout -> logout
                .logoutUrl("/logout")
                .logoutSuccessHandler(logoutHandler)
                .invalidateHttpSession(true)
                .deleteCookies("JSESSIONID")
            );

        return http.build();
    }

    /** Browser login: copy the "roles" claim from the ID token / userinfo into ROLE_* authorities. */
    @Bean
    public GrantedAuthoritiesMapper userAuthoritiesMapper() {
        return new GrantedAuthoritiesMapper() {
            @Override
            public Collection<? extends GrantedAuthority> mapAuthorities(Collection<? extends GrantedAuthority> authorities) {
                Set<GrantedAuthority> mapped = new HashSet<GrantedAuthority>();
                for (GrantedAuthority authority : authorities) {
                    mapped.add(authority);
                    if (authority instanceof OidcUserAuthority) {
                        OidcUserAuthority oidc = (OidcUserAuthority) authority;
                        addRoles(mapped, oidc.getIdToken().getClaims());
                        if (oidc.getUserInfo() != null) {
                            addRoles(mapped, oidc.getUserInfo().getClaims());
                        }
                    } else if (authority instanceof OAuth2UserAuthority) {
                        addRoles(mapped, ((OAuth2UserAuthority) authority).getAttributes());
                    }
                }
                return mapped;
            }
        };
    }

    /** Bearer-token calls: same idea, but the roles come straight from the access token (JWT). */
    @Bean
    public JwtAuthenticationConverter jwtAuthenticationConverter() {
        JwtGrantedAuthoritiesConverter roles = new JwtGrantedAuthoritiesConverter();
        roles.setAuthoritiesClaimName(rolesClaim);
        roles.setAuthorityPrefix("ROLE_");
        JwtAuthenticationConverter converter = new JwtAuthenticationConverter();
        converter.setJwtGrantedAuthoritiesConverter(roles);
        converter.setPrincipalClaimName("preferred_username");
        return converter;
    }

    /** Wrong badge: JSON 403 for the API, a friendly page for the browser. */
    @Bean
    public AccessDeniedHandler accessDeniedHandler() {
        return new AccessDeniedHandler() {
            @Override
            public void handle(HttpServletRequest request, HttpServletResponse response,
                               AccessDeniedException exception) throws IOException {
                if (request.getRequestURI().startsWith("/api/")) {
                    response.setStatus(HttpStatus.FORBIDDEN.value());
                    response.setContentType(MediaType.APPLICATION_JSON_VALUE);
                    String reason = (exception instanceof CsrfException)
                            ? "Missing or invalid CSRF token (send the X-XSRF-TOKEN header)"
                            : "Your badge does not open this door";
                    response.getWriter().write("{\"status\":403,\"message\":\"" + reason + "\"}");
                } else {
                    response.sendRedirect("/app/forbidden.html");
                }
            }
        };
    }

    @SuppressWarnings("unchecked")
    private void addRoles(Set<GrantedAuthority> target, Map<String, Object> claims) {
        if (claims == null) {
            return;
        }
        Object value = claims.get(rolesClaim);
        if (value instanceof Collection) {
            for (Object role : (Collection<Object>) value) {
                target.add(new SimpleGrantedAuthority("ROLE_" + String.valueOf(role)));
            }
        } else if (value instanceof String) {
            for (String role : ((String) value).split("[ ,]+")) {
                if (!role.isEmpty()) {
                    target.add(new SimpleGrantedAuthority("ROLE_" + role));
                }
            }
        }
    }

    /** Helper used by other classes: "ROLE_manager" -> "manager". */
    public static List<String> roleNames(Collection<? extends GrantedAuthority> authorities) {
        List<String> names = new java.util.ArrayList<String>();
        for (GrantedAuthority a : authorities) {
            if (a.getAuthority().startsWith("ROLE_")) {
                names.add(a.getAuthority().substring("ROLE_".length()));
            }
        }
        java.util.Collections.sort(names);
        return names;
    }
}
