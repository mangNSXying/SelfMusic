package com.selfmusic.backend.domain.repository;

import com.selfmusic.backend.domain.entity.SyncEvent;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.Optional;

public interface SyncEventRepository extends JpaRepository<SyncEvent, Long> {
    Optional<SyncEvent> findByEventUuid(String eventUuid);

    List<SyncEvent> findTop2000BySeqGreaterThanOrderBySeqAsc(Long seq);

    List<SyncEvent> findByTypeStartingWithAndSeqGreaterThanOrderBySeqAsc(String typePrefix, Long seq);

    @Query("select coalesce(max(e.seq), 0) from SyncEvent e")
    long maxSeq();

    /**
     * 事件日志压缩：删除水位以下的**非每实体最新**事件（每实体保留最新一条，
     * 供 cursor=0 新设备回放收敛到现状）。entity_key 为 null 的旧行不删。
     * 派生表包一层规避 MySQL「不能边删边查同表」限制。
     *
     * REQUIRES_NEW：压缩与 pull 在同一请求内触发，独立事务执行，删除失败
     * 不会把 pull 的读事务标记回滚。
     */
    @Modifying
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    @Query(value = "DELETE FROM sync_events WHERE seq < :watermark AND entity_key IS NOT NULL "
            + "AND seq NOT IN (SELECT keep FROM (SELECT MAX(seq) AS keep FROM sync_events "
            + "WHERE seq < :watermark AND entity_key IS NOT NULL GROUP BY entity_key) t)",
            nativeQuery = true)
    int compactBelow(@Param("watermark") long watermark);
}
