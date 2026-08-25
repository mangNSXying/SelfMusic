package com.selfmusic.backend.domain.repository;

import com.selfmusic.backend.domain.entity.Playlist;
import org.springframework.data.jpa.repository.JpaRepository;
import java.util.List;

public interface PlaylistRepository extends JpaRepository<Playlist, Long> {
    List<Playlist> findAllByOrderByUpdatedAtDesc();
}
