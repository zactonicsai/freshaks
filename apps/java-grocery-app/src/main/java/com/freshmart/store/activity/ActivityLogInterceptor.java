package com.freshmart.store.activity;

import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Component;
import org.springframework.web.servlet.HandlerInterceptor;

import com.freshmart.store.web.CurrentUser;

/**
 * After every /api/** or /app/** request finishes, write "who did what" to the notebook.
 * (The notebook itself, /api/activity, is skipped so reading the log does not fill the log.)
 */
@Component
public class ActivityLogInterceptor implements HandlerInterceptor {

    private final ActivityService activityService;

    public ActivityLogInterceptor(ActivityService activityService) {
        this.activityService = activityService;
    }

    @Override
    public void afterCompletion(HttpServletRequest request, HttpServletResponse response,
                                Object handler, Exception ex) {
        String path = request.getRequestURI();
        if ("OPTIONS".equals(request.getMethod()) || path.startsWith("/api/activity")) {
            return;
        }
        Authentication auth = SecurityContextHolder.getContext().getAuthentication();
        String actor = CurrentUser.username(auth);
        String action = path.startsWith("/api/") ? "API_CALL" : "PAGE_VIEW";
        String details = request.getQueryString() == null ? null : "query=" + request.getQueryString();
        if (ex != null) {
            details = (details == null ? "" : details + " ") + "error=" + ex.getClass().getSimpleName();
        }
        activityService.log(actor, action, request.getMethod(), path, response.getStatus(), details);
    }
}
