package com.selfmusic.backend.domain.repository;

import com.selfmusic.backend.domain.entity.SyncSource;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.Optional;

public interface SyncSourceRepository extends JpaRepository<SyncSource, Long> {
    Optional<SyncSource> findByClientUuid(String clientUuid);
    Optional<SyncSource> findByKindAndAddress(String kind, String address);
}
