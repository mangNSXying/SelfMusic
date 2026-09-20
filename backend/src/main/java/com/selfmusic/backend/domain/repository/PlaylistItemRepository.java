package com.selfmusic.backend.domain.repository;

import com.selfmusic.backend.domain.entity.PlaylistItem;
import org.springframework.data.jpa.repository.JpaRepository;
import java.util.List;
import java.util.Optional;

public interface PlaylistItemRepository extends JpaRepository<PlaylistItem, Long> {
    List<PlaylistItem> findByPlaylistIdOrderBySortOrderAsc(Long playlistId);
    Optional<PlaylistItem> findByPlaylistIdAndSongId(Long playlistId, Long songId);
    void deleteByPlaylistIdAndSongId(Long playlistId, Long songId);
}
