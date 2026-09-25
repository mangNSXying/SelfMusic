package com.selfmusic.backend.domain.entity;

import jakarta.persistence.*;
import java.time.LocalDateTime;

/**
 * 断点续播状态（每歌单一行）：自持歌曲身份，不再依赖服务端曲库。
 * LWW 基准为 last_event_at（最后一次应用的断点事件 occurred_at）。
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

    /** 深层列表（播放历史，JSON 数组，元素为 {source, source_ref} 身份），跨设备续播重建队列用。 */
    @Column(name = "deep_list_json", columnDefinition = "TEXT")
    private String deepListJson;

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
