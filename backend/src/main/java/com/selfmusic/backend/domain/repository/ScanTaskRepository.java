package com.selfmusic.backend.domain.repository;

import com.selfmusic.backend.domain.entity.ScanTask;
import org.springframework.data.jpa.repository.JpaRepository;
import java.util.List;

public interface ScanTaskRepository extends JpaRepository<ScanTask, Long> {
    List<ScanTask> findTop10ByOrderByStartedAtDesc();
}
