package com.freshmart.store.activity;

import org.springframework.context.event.EventListener;
import org.springframework.security.authentication.event.AuthenticationSuccessEvent;
import org.springframework.security.core.Authentication;
import org.springframework.security.oauth2.client.authentication.OAuth2LoginAuthenticationToken;
import org.springframework.stereotype.Component;

import com.freshmart.store.web.CurrentUser;

/** Every successful browser login (badge handed out by Keycloak) becomes a LOGIN line in the notebook. */
@Component
public class LoginEventListener {

    private final ActivityService activityService;

    public LoginEventListener(ActivityService activityService) {
        this.activityService = activityService;
    }

    @EventListener
    public void onLogin(AuthenticationSuccessEvent event) {
        Authentication auth = event.getAuthentication();
        if (auth instanceof OAuth2LoginAuthenticationToken) {
            activityService.log(CurrentUser.username(auth), "LOGIN",
                    "roles=" + CurrentUser.roles(auth) + " via=keycloak");
        }
    }
}
