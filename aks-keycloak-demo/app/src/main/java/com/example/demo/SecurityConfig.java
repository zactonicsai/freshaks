package com.example.demo;

import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
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

/**
 * The rules for who may see which page, and how login works.
 */
@Configuration
@EnableWebSecurity
public class SecurityConfig {

    /** Every Keycloak group "x" becomes the permission "GROUP_x" inside the app. */
    static final String GROUP_PREFIX = "GROUP_";

    /**
     * Tells the app where Keycloak is.
     *
     * There are TWO addresses for the same Keycloak:
     *  - publicUrl   : what the visitor's BROWSER uses (https, through the gateway).
     *  - internalUrl : what THIS APP uses to talk to Keycloak directly inside the
     *                  cluster. The Istio sidecars encrypt that hop for us (mTLS).
     *
     * We write the addresses out by hand (instead of "auto-discovery") so the app
     * does not have to call the public https address, which uses a self-signed
     * certificate in this demo.
     */
    @Bean
    ClientRegistrationRepository clientRegistrationRepository(
            @Value("${demo.keycloak.public-url}") String publicUrl,
            @Value("${demo.keycloak.internal-url}") String internalUrl,
            @Value("${demo.keycloak.realm}") String realm,
            @Value("${demo.keycloak.client-id}") String clientId,
            @Value("${demo.keycloak.client-secret}") String clientSecret) {

        // The "issuer" is Keycloak's official name. It is stamped inside every
        // login token, and the app checks that the stamp matches.
        String issuer = publicUrl + "/realms/" + realm;
        String browserSide = issuer + "/protocol/openid-connect";
        String serverSide = internalUrl + "/realms/" + realm + "/protocol/openid-connect";

        ClientRegistration keycloak = ClientRegistration.withRegistrationId("keycloak")
                .clientName("Keycloak")
                .clientId(clientId)
                .clientSecret(clientSecret)
                .clientAuthenticationMethod(ClientAuthenticationMethod.CLIENT_SECRET_BASIC)
                .authorizationGrantType(AuthorizationGrantType.AUTHORIZATION_CODE)
                .redirectUri("{baseUrl}/login/oauth2/code/{registrationId}")
                .scope("openid", "profile", "email")
                .issuerUri(issuer)
                .authorizationUri(browserSide + "/auth")   // browser goes here to log in
                .tokenUri(serverSide + "/token")           // app swaps the code for tokens here
                .jwkSetUri(serverSide + "/certs")          // app gets Keycloak's public keys here
                .userNameAttributeName("preferred_username")
                // Where to send the browser on logout, so Keycloak logs out too.
                .providerConfigurationMetadata(Map.of("end_session_endpoint", browserSide + "/logout"))
                // PKCE = an extra one-time secret per login. Keycloak is set to demand it.
                .clientSettings(ClientRegistration.ClientSettings.builder().requireProofKey(true).build())
                .build();

        return new InMemoryClientRegistrationRepository(keycloak);
    }

    @Bean
    SecurityFilterChain securityFilterChain(
            HttpSecurity http,
            ClientRegistrationRepository clients,
            @Value("${demo.required-group}") String requiredGroup) throws Exception {

        // On logout: also end the Keycloak session, then come back to the home page.
        OidcClientInitiatedLogoutSuccessHandler logoutHandler =
                new OidcClientInitiatedLogoutSuccessHandler(clients);
        logoutHandler.setPostLogoutRedirectUri("{baseUrl}/");

        http
            .authorizeHttpRequests(auth -> auth
                // PUBLIC: anyone may see these, no login.
                .requestMatchers("/", "/denied", "/error", "/actuator/health/**").permitAll()
                // GROUP: must be logged in AND be in the right Keycloak group.
                .requestMatchers("/group/**").hasAuthority(GROUP_PREFIX + requiredGroup)
                // PRIVATE: everything else needs a login.
                .anyRequest().authenticated())
            .oauth2Login(login -> login
                .userInfoEndpoint(userInfo -> userInfo.userAuthoritiesMapper(groupsToAuthorities())))
            .logout(logout -> logout.logoutSuccessHandler(logoutHandler))
            // Logged in but not allowed? Show our friendly "denied" page.
            .exceptionHandling(errors -> errors.accessDeniedPage("/denied"));

        return http.build();
    }

    /**
     * Keycloak puts a list called "groups" in the login token, like ["managers"].
     * This turns each group name into a permission the rules above can check.
     */
    private GrantedAuthoritiesMapper groupsToAuthorities() {
        return authorities -> {
            Set<GrantedAuthority> result = new HashSet<>(authorities);
            for (GrantedAuthority authority : authorities) {
                if (authority instanceof OidcUserAuthority oidc) {
                    List<String> groups = oidc.getIdToken().getClaimAsStringList("groups");
                    if (groups != null) {
                        for (String group : groups) {
                            result.add(new SimpleGrantedAuthority(GROUP_PREFIX + group));
                        }
                    }
                }
            }
            return result;
        };
    }
}
