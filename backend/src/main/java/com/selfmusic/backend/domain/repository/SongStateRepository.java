package com.selfmusic.backend.domain.repository;

import com.selfmusic.backend.domain.entity.SongState;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.Optional;

public interface SongStateRepository extends JpaRepository<SongState, Long> {

    Optional<SongState> findBySourceIdAndSourceRef(String sourceId, String sourceRef);

    Optional<SongState> findFirstBySourceRef(String sourceRef);
}
