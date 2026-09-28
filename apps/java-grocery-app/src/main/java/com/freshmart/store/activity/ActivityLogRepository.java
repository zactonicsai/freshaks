package com.freshmart.store.activity;

import java.util.List;

import org.springframework.data.jpa.repository.JpaRepository;

public interface ActivityLogRepository extends JpaRepository<ActivityLog, Long> {

    /** The newest 200 lines of the notebook (both services). */
    List<ActivityLog> findTop200ByOrderByOccurredAtDesc();

    List<ActivityLog> findTop200ByActorOrderByOccurredAtDesc(String actor);
}
