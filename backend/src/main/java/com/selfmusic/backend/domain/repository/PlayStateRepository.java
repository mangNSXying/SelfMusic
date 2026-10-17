package com.selfmusic.backend.domain.repository;

import com.selfmusic.backend.domain.entity.PlayState;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;

import java.util.Optional;

public interface PlayStateRepository extends JpaRepository<PlayState, Long> {

    /**
     * 全局最新一行断点（快路径 GET /playstates/latest 用）。
     * 排序基准与推送 LWW/客户端镜像比较一致：最后操作时间 last_event_at
     * （= 命中事件的 occurred_at；旧数据缺该字段时退化为 updated_at 上传时间）。
     * playlistId 兜底保证确定性。
     */
    @Query("select s from PlayState s order by coalesce(s.lastEventAt, s.updatedAt) desc, s.playlistId desc")
    Optional<PlayState> findLatest();
}
