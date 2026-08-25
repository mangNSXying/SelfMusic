package com.selfmusic.backend.domain.repository;

import com.selfmusic.backend.domain.entity.PlayState;
import org.springframework.data.jpa.repository.JpaRepository;

public interface PlayStateRepository extends JpaRepository<PlayState, Long> {
}
