package com.selfmusic.backend.domain.entity;

import com.fasterxml.jackson.annotation.JsonIgnore;
import jakarta.persistence.*;
import java.time.LocalDateTime;

/**
 * 歌单条目：自持歌曲身份（source_id/source_ref）与展示快照，
 * 不再依赖服务端曲库 Song 外键。快照字段来自客户端事件载荷，
 * 用于无本地源的设备展示歌单内容。
 */
@Entity
@Table(name = "playlist_items",
       uniqueConstraints = @UniqueConstraint(columnNames = {"playlist_id", "source_id", "source_ref"}))
public class PlaylistItem {
    @Id @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @JsonIgnore
    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "playlist_id", nullable = false)
    private Playlist playlist;

    /** 源实例身份：客户端 sources.client_uuid；旧数据为 legacy:<协议>。 */
    @Column(name = "source_id", nullable = false, length = 100)
    private String sourceId;

    /** 协议名（webdav/local/smb），仅展示/兜底匹配用。 */
    @Column(length = 20)
    private String source;

    @Column(name = "source_ref", nullable = false, length = 500)
    private String sourceRef;

    @Column(length = 200)
    private String title;

    @Column(length = 200)
    private String artist;

    @Column(length = 200)
    private String album;

    @Column
    private Integer duration;

    @Column(name = "sort_order")
    private Integer sortOrder = 0;

    @Column(name = "added_at")
    private LocalDateTime addedAt;

    @PrePersist
    void init() { addedAt = LocalDateTime.now(); }

    public Long getId() { return id; }
    public void setId(Long id) { this.id = id; }

    public Playlist getPlaylist() { return playlist; }
    public void setPlaylist(Playlist playlist) { this.playlist = playlist; }

    public String getSourceId() { return sourceId; }
    public void setSourceId(String sourceId) { this.sourceId = sourceId; }

    public String getSource() { return source; }
    public void setSource(String source) { this.source = source; }

    public String getSourceRef() { return sourceRef; }
    public void setSourceRef(String sourceRef) { this.sourceRef = sourceRef; }

    public String getTitle() { return title; }
    public void setTitle(String title) { this.title = title; }

    public String getArtist() { return artist; }
    public void setArtist(String artist) { this.artist = artist; }

    public String getAlbum() { return album; }
    public void setAlbum(String album) { this.album = album; }

    public Integer getDuration() { return duration; }
    public void setDuration(Integer duration) { this.duration = duration; }

    public Integer getSortOrder() { return sortOrder; }
    public void setSortOrder(Integer sortOrder) { this.sortOrder = sortOrder; }

    public LocalDateTime getAddedAt() { return addedAt; }
    public void setAddedAt(LocalDateTime addedAt) { this.addedAt = addedAt; }

    @Override
    public boolean equals(Object o) {
        if (this == o) return true;
        if (!(o instanceof PlaylistItem)) return false;
        PlaylistItem other = (PlaylistItem) o;
        return id != null && id.equals(other.getId());
    }

    @Override
    public int hashCode() {
        return getClass().hashCode();
    }

    @Override
    public String toString() {
        return "PlaylistItem{id=" + id + ", playlistId="
                + (playlist != null ? playlist.getId() : null) + ", sourceId='"
                + sourceId + "', sourceRef='" + sourceRef + "', sortOrder=" + sortOrder + "}";
    }
}
