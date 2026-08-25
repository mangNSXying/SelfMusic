package com.selfmusic.backend.domain.entity;

import jakarta.persistence.*;
import java.time.LocalDateTime;

@Entity
@Table(name = "play_states")
public class PlayState {
    @Id
    @Column(name = "playlist_id")
    private Long playlistId;

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "song_id")
    private Song song;

    @Column(name = "position_ms")
    private Integer positionMs = 0;

    @Column(name = "updated_at")
    private LocalDateTime updatedAt;

    @PrePersist
    @PreUpdate
    void touch() { updatedAt = LocalDateTime.now(); }

    public Long getPlaylistId() { return playlistId; }
    public void setPlaylistId(Long playlistId) { this.playlistId = playlistId; }

    public Song getSong() { return song; }
    public void setSong(Song song) { this.song = song; }

    public Integer getPositionMs() { return positionMs; }
    public void setPositionMs(Integer positionMs) { this.positionMs = positionMs; }

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
                + ", songId=" + (song != null ? song.getId() : null)
                + ", positionMs=" + positionMs + "}";
    }
}
