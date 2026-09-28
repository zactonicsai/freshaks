package com.freshmart.store.activity;

import java.util.List;

import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/** Managers can read the notebook. */
@RestController
@RequestMapping("/api/activity")
public class ActivityController {

    private final ActivityLogRepository repository;

    public ActivityController(ActivityLogRepository repository) {
        this.repository = repository;
    }

    @GetMapping
    @PreAuthorize("hasRole('manager')")
    public List<ActivityLog> latest(@RequestParam(name = "actor", required = false) String actor) {
        if (actor != null && !actor.isEmpty()) {
            return repository.findTop200ByActorOrderByOccurredAtDesc(actor);
        }
        return repository.findTop200ByOrderByOccurredAtDesc();
    }
}
