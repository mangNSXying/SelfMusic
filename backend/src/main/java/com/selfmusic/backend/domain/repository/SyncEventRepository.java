package com.selfmusic.backend.domain.repository;

import com.selfmusic.backend.domain.entity.SyncEvent;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;

import java.util.List;
import java.util.Optional;

public interface SyncEventRepository extends JpaRepository<SyncEvent, Long> {
    Optional<SyncEvent> findByEventUuid(String eventUuid);

    List<SyncEvent> findTop2000BySeqGreaterThanOrderBySeqAsc(Long seq);

    List<SyncEvent> findByTypeStartingWithAndSeqGreaterThanOrderBySeqAsc(String typePrefix, Long seq);

    @Query("select coalesce(max(e.seq), 0) from SyncEvent e")
    long maxSeq();
}
