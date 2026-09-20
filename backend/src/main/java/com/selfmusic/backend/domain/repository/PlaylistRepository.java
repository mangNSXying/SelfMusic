package com.selfmusic.backend.domain.repository;

import com.selfmusic.backend.domain.entity.Playlist;
import org.springframework.data.jpa.repository.JpaRepository;
import java.util.List;
import java.util.Optional;

public interface PlaylistRepository extends JpaRepository<Playlist, Long> {
    List<Playlist> findAllByOrderByUpdatedAtDesc();

    Optional<Playlist> findByClientUuid(String clientUuid);
}
