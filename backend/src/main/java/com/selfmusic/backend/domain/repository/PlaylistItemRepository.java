package com.selfmusic.backend.domain.repository;

import com.selfmusic.backend.domain.entity.PlaylistItem;
import org.springframework.data.jpa.repository.JpaRepository;
import java.util.List;

public interface PlaylistItemRepository extends JpaRepository<PlaylistItem, Long> {
    List<PlaylistItem> findByPlaylistIdOrderBySortOrderAsc(Long playlistId);
    void deleteByPlaylistIdAndSongId(Long playlistId, Long songId);
}
