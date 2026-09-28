package com.freshmart.store.activity;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

/**
 * Writes one line into activity_log. Never throws: a broken notebook must not stop the store.
 */
@Service
public class ActivityService {

    private static final Logger LOG = LoggerFactory.getLogger(ActivityService.class);

    private final ActivityLogRepository repository;
    private final String serviceName;

    public ActivityService(ActivityLogRepository repository,
                           @Value("${freshmart.service-name:java-store}") String serviceName) {
        this.repository = repository;
        this.serviceName = serviceName;
    }

    public void log(String actor, String action, String method, String path, Integer status, String details) {
        try {
            ActivityLog entry = new ActivityLog();
            entry.setService(serviceName);
            entry.setActor(actor == null || actor.isEmpty() ? "anonymous" : actor);
            entry.setAction(action);
            entry.setMethod(method);
            entry.setPath(path);
            entry.setStatus(status);
            entry.setDetails(details);
            repository.save(entry);
        } catch (RuntimeException e) {
            LOG.warn("could not write activity log: {}", e.getMessage());
        }
    }

    public void log(String actor, String action, String details) {
        log(actor, action, null, null, null, details);
    }
}
