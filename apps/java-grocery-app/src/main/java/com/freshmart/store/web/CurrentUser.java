package com.freshmart.store.web;

import java.util.Collections;
import java.util.List;
import java.util.Map;

import org.springframework.security.authentication.AnonymousAuthenticationToken;
import org.springframework.security.core.Authentication;
import org.springframework.security.oauth2.core.oidc.user.OidcUser;
import org.springframework.security.oauth2.core.user.OAuth2User;
import org.springframework.security.oauth2.jwt.Jwt;

import com.freshmart.store.config.SecurityConfig;

/** Reads "who is this?" from whichever kind of badge Spring gave us (browser session or Bearer token). */
public final class CurrentUser {

    private CurrentUser() {
    }

    public static boolean isLoggedIn(Authentication auth) {
        return auth != null && auth.isAuthenticated() && !(auth instanceof AnonymousAuthenticationToken);
    }

    public static String username(Authentication auth) {
        if (!isLoggedIn(auth)) {
            return "anonymous";
        }
        Object principal = auth.getPrincipal();
        if (principal instanceof OidcUser) {
            String name = ((OidcUser) principal).getPreferredUsername();
            return name != null ? name : auth.getName();
        }
        if (principal instanceof Jwt) {
            String name = ((Jwt) principal).getClaimAsString("preferred_username");
            return name != null ? name : auth.getName();
        }
        return auth.getName();
    }

    public static String claim(Authentication auth, String claim) {
        if (!isLoggedIn(auth)) {
            return null;
        }
        Object principal = auth.getPrincipal();
        if (principal instanceof OidcUser) {
            Object v = ((OidcUser) principal).getClaims().get(claim);
            return v == null ? null : String.valueOf(v);
        }
        if (principal instanceof OAuth2User) {
            Object v = ((OAuth2User) principal).getAttributes().get(claim);
            return v == null ? null : String.valueOf(v);
        }
        if (principal instanceof Jwt) {
            return ((Jwt) principal).getClaimAsString(claim);
        }
        return null;
    }

    public static List<String> roles(Authentication auth) {
        if (!isLoggedIn(auth)) {
            return Collections.emptyList();
        }
        return SecurityConfig.roleNames(auth.getAuthorities());
    }

    public static Map<String, Object> allClaims(Authentication auth) {
        if (!isLoggedIn(auth)) {
            return Collections.emptyMap();
        }
        Object principal = auth.getPrincipal();
        if (principal instanceof OidcUser) {
            return ((OidcUser) principal).getClaims();
        }
        if (principal instanceof OAuth2User) {
            return ((OAuth2User) principal).getAttributes();
        }
        if (principal instanceof Jwt) {
            return ((Jwt) principal).getClaims();
        }
        return Collections.emptyMap();
    }
}
