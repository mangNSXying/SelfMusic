package com.selfmusic.backend.domain.repository;

import com.selfmusic.backend.domain.entity.PlayState;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.Optional;

public interface PlayStateRepository extends JpaRepository<PlayState, Long> {

    /**
     * 全局最新一行断点（快路径 GET /playstates/latest 用）。
     * 排序基准与客户端镜像比较一致（updated_at），playlistId 兜底保证确定性。
     */
    Optional<PlayState> findTopByOrderByUpdatedAtDescPlaylistIdDesc();
}
