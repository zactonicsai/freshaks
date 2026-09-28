package com.freshmart.store.me;

import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.Map;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.security.core.Authentication;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import com.freshmart.store.web.CurrentUser;

/** "Who am I?" for the pages, plus a public store-info endpoint that needs no badge at all. */
@RestController
@RequestMapping("/api")
public class MeController {

    @Value("${freshmart.service-name:java-store}")
    private String serviceName;

    @GetMapping("/me")
    public Map<String, Object> me(Authentication auth) {
        Map<String, Object> me = new LinkedHashMap<String, Object>();
        me.put("username", CurrentUser.username(auth));
        me.put("name", CurrentUser.claim(auth, "name"));
        me.put("email", CurrentUser.claim(auth, "email"));
        me.put("roles", CurrentUser.roles(auth));
        me.put("service", serviceName);
        me.put("tokenType", auth != null && auth.getPrincipal() instanceof org.springframework.security.oauth2.jwt.Jwt
                ? "bearer" : "session");
        return me;
    }

    @GetMapping("/public/store-info")
    public Map<String, Object> storeInfo() {
        Map<String, Object> info = new LinkedHashMap<String, Object>();
        info.put("name", "Fresh Mart");
        info.put("slogan", "Good food, fair prices, friendly badges.");
        info.put("hours", "7:00 - 21:00 every day");
        info.put("service", serviceName);
        info.put("roles", Arrays.asList("shopper", "cashier", "manager"));
        return info;
    }
}
