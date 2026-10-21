package com.selfmusic.backend.domain.entity;

import jakarta.persistence.*;
import java.time.LocalDateTime;

/**
 * 断点续播状态（每歌单一行）：自持歌曲身份，不再依赖服务端曲库。
 *
 * <p>v2 协议把「当前播放头」与「深层历史」拆开：head_* 由 HLC 操作时钟仲裁，
 * history_rev 只随深层列表变化递增；last_event_at 仅保留给旧协议兼容/诊断。</p>
 */
@Entity
@Table(name = "play_states")
public class PlayState {
    @Id
    @Column(name = "playlist_id")
    private Long playlistId;

    /** 源实例身份：客户端 sources.client_uuid；旧数据为 legacy:<协议>。 */
    @Column(name = "source_id", length = 100)
    private String sourceId;

    /** 协议名（webdav/local/smb），仅展示/兜底匹配用。 */
    @Column(length = 20)
    private String source;

    @Column(name = "source_ref", length = 500)
    private String sourceRef;

    /** 上报设备 client_id（跨设备续播提示用，可空）。 */
    @Column(name = "device_client_id", length = 36)
    private String deviceClientId;

    @Column(name = "position_ms")
    private Integer positionMs = 0;

    /** 深层列表（播放历史，JSON 数组，元素为 {source, source_ref} 身份），跨设备续播重建队列用。大歌单可超过 TEXT 64 KiB，故用 MEDIUMTEXT。 */
    @Column(name = "deep_list_json", columnDefinition = "MEDIUMTEXT")
    private String deepListJson;

    // ------------------------------------------------------------------
    // 协议 v2：播放头（head）与历史版本（history_rev）
    // ------------------------------------------------------------------

    /** 当前播放头版本：仅在 head 被接受时 +1；客户端据此决定是否应用 head。 */
    @Column(name = "head_rev")
    private Long headRev = 0L;

    /** 最后一次被接受的 head 操作时钟（HLC：wall-counter-device）。 */
    @Column(name = "head_clock", length = 80)
    private String headClock;

    /** 最后一次被接受的 head 来源设备。 */
    @Column(name = "head_device", length = 64)
    private String headDevice;

    /** 最后一次被接受的 head 操作 id（幂等/自回声确认用）。 */
    @Column(name = "head_op_id", length = 64)
    private String headOpId;

    /** 播放会话 id：progress 只接受同一会话；新起播生成新会话。 */
    @Column(name = "head_session", length = 64)
    private String headSession;

    /** 服务端当前 head 是否处于播放态（客户端恢复仍按本地策略暂停装载）。 */
    @Column(name = "head_playing")
    private Boolean headPlaying = false;

    /** 服务端接受该 head 的时间：全局「最近歌单」排序用，不受客户端钟影响。 */
    @Column(name = "head_updated_at")
    private LocalDateTime headUpdatedAt;

    /** 深层历史版本：history 有变化才 +1；与 head 输赢无关。 */
    @Column(name = "history_rev")
    private Long historyRev = 0L;

    /** 旧协议 LWW 兼容字段（v2 新客户端不再用它做正确性比较）。 */
    @Column(name = "last_event_at")
    private LocalDateTime lastEventAt;

    @Column(name = "updated_at")
    private LocalDateTime updatedAt;

    @PrePersist
    @PreUpdate
    public void touch() { updatedAt = LocalDateTime.now(); }

    public Long getPlaylistId() { return playlistId; }
    public void setPlaylistId(Long playlistId) { this.playlistId = playlistId; }

    public String getSourceId() { return sourceId; }
    public void setSourceId(String sourceId) { this.sourceId = sourceId; }

    public String getSource() { return source; }
    public void setSource(String source) { this.source = source; }

    public String getSourceRef() { return sourceRef; }
    public void setSourceRef(String sourceRef) { this.sourceRef = sourceRef; }

    public String getDeviceClientId() { return deviceClientId; }
    public void setDeviceClientId(String deviceClientId) { this.deviceClientId = deviceClientId; }

    public Integer getPositionMs() { return positionMs; }
    public void setPositionMs(Integer positionMs) { this.positionMs = positionMs; }

    public String getDeepListJson() { return deepListJson; }
    public void setDeepListJson(String deepListJson) { this.deepListJson = deepListJson; }

    public Long getHeadRev() { return headRev == null ? 0L : headRev; }
    public void setHeadRev(Long headRev) { this.headRev = headRev; }

    public String getHeadClock() { return headClock; }
    public void setHeadClock(String headClock) { this.headClock = headClock; }

    public String getHeadDevice() { return headDevice; }
    public void setHeadDevice(String headDevice) { this.headDevice = headDevice; }

    public String getHeadOpId() { return headOpId; }
    public void setHeadOpId(String headOpId) { this.headOpId = headOpId; }

    public String getHeadSession() { return headSession; }
    public void setHeadSession(String headSession) { this.headSession = headSession; }

    public Boolean getHeadPlaying() { return headPlaying != null && headPlaying; }
    public void setHeadPlaying(Boolean headPlaying) { this.headPlaying = headPlaying; }

    public LocalDateTime getHeadUpdatedAt() { return headUpdatedAt; }
    public void setHeadUpdatedAt(LocalDateTime headUpdatedAt) { this.headUpdatedAt = headUpdatedAt; }

    public Long getHistoryRev() { return historyRev == null ? 0L : historyRev; }
    public void setHistoryRev(Long historyRev) { this.historyRev = historyRev; }

    public LocalDateTime getLastEventAt() { return lastEventAt; }
    public void setLastEventAt(LocalDateTime lastEventAt) { this.lastEventAt = lastEventAt; }

    public LocalDateTime getUpdatedAt() { return updatedAt; }
    public void setUpdatedAt(LocalDateTime updatedAt) { this.updatedAt = updatedAt; }

    @Override
    public boolean equals(Object o) {
        if (this == o) return true;
        if (!(o instanceof PlayState)) return false;
        PlayState other = (PlayState) o;
        return playlistId != null && playlistId.equals(other.getPlaylistId());
    }

    @Override
    public int hashCode() {
        return getClass().hashCode();
    }

    @Override
    public String toString() {
        return "PlayState{playlistId=" + playlistId
                + ", sourceId='" + sourceId + "', sourceRef='" + sourceRef
                + "', positionMs=" + positionMs + "}";
    }
}
