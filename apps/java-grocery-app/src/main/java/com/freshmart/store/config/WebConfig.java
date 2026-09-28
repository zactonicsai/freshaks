package com.freshmart.store.config;

import org.springframework.context.annotation.Configuration;
import org.springframework.web.servlet.config.annotation.InterceptorRegistry;
import org.springframework.web.servlet.config.annotation.WebMvcConfigurer;

import com.freshmart.store.activity.ActivityLogInterceptor;

/** Plugs the activity logger into every page (/app/**) and API (/api/**) request. */
@Configuration
public class WebConfig implements WebMvcConfigurer {

    private final ActivityLogInterceptor activityLogInterceptor;

    public WebConfig(ActivityLogInterceptor activityLogInterceptor) {
        this.activityLogInterceptor = activityLogInterceptor;
    }

    @Override
    public void addInterceptors(InterceptorRegistry registry) {
        registry.addInterceptor(activityLogInterceptor).addPathPatterns("/api/**", "/app/**");
    }
}
