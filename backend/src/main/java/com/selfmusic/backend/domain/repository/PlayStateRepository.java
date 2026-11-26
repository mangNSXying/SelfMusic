package com.selfmusic.backend.domain.repository;

import com.selfmusic.backend.domain.entity.PlayState;
import org.springframework.data.domain.PageRequest;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;

import java.util.List;

public interface PlayStateRepository extends JpaRepository<PlayState, Long> {

    /**
     * 全局最新一行断点（快路径 GET /playstates/latest 用）。
     *
     * <p>v2 以服务端接受 head 的时间 {@code headUpdatedAt} 排序，不受客户端钟
     * 影响；旧数据/旧客户端没有 headUpdatedAt 时回退 last_event_at/updated_at。</p>
     *
     * <p>签名用 {@code List + Pageable}：JPQL 没有 LIMIT，声明成 Optional 会在
     * play_states 有多行时抛 NonUniqueResultException（快路径整条 500）。</p>
     */
    @Query("select s from PlayState s order by coalesce(s.headUpdatedAt, s.lastEventAt, s.updatedAt) desc, s.playlistId desc")
    List<PlayState> findLatest(Pageable pageable);

    /** 全局最新一行断点；表为空时返回 null。 */
    default PlayState findLatestOne() {
        List<PlayState> rows = findLatest(PageRequest.of(0, 1));
        return rows.isEmpty() ? null : rows.get(0);
    }
}
