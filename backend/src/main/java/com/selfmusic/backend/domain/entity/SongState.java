package com.selfmusic.backend.domain.entity;

import jakarta.persistence.*;
import java.math.BigDecimal;
import java.time.LocalDateTime;

/**
 * 直连歌曲权重/收藏状态（阶段5 同步，取代原曲库 Song 的状态承载职责）。
 *
 * 服务端不再持有曲库（无专辑/封面/文件字段），本表只按歌曲身份
 * {@code (source_id, source_ref)} 聚合多设备同步过来的权重与喜欢状态。
 * {@code source_id} 为客户端源实例 uuid；旧数据/旧客户端协议级身份记作
 * {@code legacy:<协议>}。标题仅作诊断/兜底展示用。
 */
@Entity
@Table(name = "song_states",
       uniqueConstraints = @UniqueConstraint(columnNames = {"source_id", "source_ref"}))
public class SongState {
    @Id @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "source_id", nullable = false, length = 100)
    private String sourceId;

    /** 协议名（webdav/local/smb），仅展示与旧数据匹配用。 */
    @Column(length = 20)
    private String source;

    @Column(name = "source_ref", nullable = false, length = 500)
    private String sourceRef;

    @Column(length = 200)
    private String title;

    // 加权播放状态（DEVELOPER.md「播放算法与同步协议」）
    @Column(name = "like_streak")
    private Integer likeStreak = 0;

    @Column(name = "dislike_streak")
    private Integer dislikeStreak = 0;

    @Column(precision = 6, scale = 4)
    private BigDecimal weight = BigDecimal.ONE;

    private boolean frozen = false;

    @Column(name = "is_favorite")
    private boolean favorite = false;

    /** 累计播放时长（秒）。随 song.state 绝对态同步（客户端按挂钟累计后成批上报）。 */
    @Column(name = "play_sec")
    private Integer playSec = 0;

    /**
     * 播放进度直方图（101 桶 JSON，0..100%）。只由 complete/skip/progress 样本事件
     * 累加，baseline 基线按桶 max；song.state 绝对态不携带，避免重复计数。
     */
    @Column(name = "progress_hist", columnDefinition = "TEXT")
    private String progressHist;

    @Column(name = "last_event_at")
    private LocalDateTime lastEventAt;

    @Column(name = "created_at")
    private LocalDateTime createdAt;

    @Column(name = "updated_at")
    private LocalDateTime updatedAt;

    @PrePersist
    @PreUpdate
    void touch() {
        updatedAt = LocalDateTime.now();
        if (createdAt == null) createdAt = LocalDateTime.now();
    }

    public Long getId() { return id; }
    public void setId(Long id) { this.id = id; }

    public String getSourceId() { return sourceId; }
    public void setSourceId(String sourceId) { this.sourceId = sourceId; }

    public String getSource() { return source; }
    public void setSource(String source) { this.source = source; }

    public String getSourceRef() { return sourceRef; }
    public void setSourceRef(String sourceRef) { this.sourceRef = sourceRef; }

    public String getTitle() { return title; }
    public void setTitle(String title) { this.title = title; }

    public Integer getLikeStreak() { return likeStreak; }
    public void setLikeStreak(Integer likeStreak) { this.likeStreak = likeStreak; }

    public Integer getDislikeStreak() { return dislikeStreak; }
    public void setDislikeStreak(Integer dislikeStreak) { this.dislikeStreak = dislikeStreak; }

    public BigDecimal getWeight() { return weight; }
    public void setWeight(BigDecimal weight) { this.weight = weight; }

    public boolean isFrozen() { return frozen; }
    public void setFrozen(boolean frozen) { this.frozen = frozen; }

    public boolean isFavorite() { return favorite; }
    public void setFavorite(boolean favorite) { this.favorite = favorite; }

    public Integer getPlaySec() { return playSec; }
    public void setPlaySec(Integer playSec) { this.playSec = playSec; }

    public String getProgressHist() { return progressHist; }
    public void setProgressHist(String progressHist) { this.progressHist = progressHist; }

    public LocalDateTime getLastEventAt() { return lastEventAt; }
    public void setLastEventAt(LocalDateTime lastEventAt) { this.lastEventAt = lastEventAt; }

    public LocalDateTime getCreatedAt() { return createdAt; }
    public void setCreatedAt(LocalDateTime createdAt) { this.createdAt = createdAt; }

    public LocalDateTime getUpdatedAt() { return updatedAt; }
    public void setUpdatedAt(LocalDateTime updatedAt) { this.updatedAt = updatedAt; }

    @Override
    public boolean equals(Object o) {
        if (this == o) return true;
        if (!(o instanceof SongState)) return false;
        SongState other = (SongState) o;
        return id != null && id.equals(other.getId());
    }

    @Override
    public int hashCode() {
        return getClass().hashCode();
    }

    @Override
    public String toString() {
        return "SongState{id=" + id + ", sourceId='" + sourceId
                + "', sourceRef='" + sourceRef + "'}";
    }
}
