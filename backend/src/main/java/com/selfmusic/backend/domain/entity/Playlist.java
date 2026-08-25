package com.selfmusic.backend.domain.entity;

import jakarta.persistence.*;
import java.time.LocalDateTime;

@Entity
@Table(name = "playlists")
public class Playlist {
    @Id @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(nullable = false)
    private String name;

    private String description;

    @Column(name = "cover_id")
    private Long coverId;

    @Enumerated(EnumType.STRING)
    @Column(length = 20)
    private PlaylistMode mode = PlaylistMode.shuffle_weighted;

    @Column(name = "sync_ver")
    private Long syncVer = 0L;

    @Column(name = "created_at")
    private LocalDateTime createdAt;

    @Column(name = "updated_at")
    private LocalDateTime updatedAt;

    @PrePersist
    @PreUpdate
    public void touch() {
        this.updatedAt = LocalDateTime.now();
        if (createdAt == null) createdAt = LocalDateTime.now();
    }

    public Long getId() { return id; }
    public void setId(Long id) { this.id = id; }

    public String getName() { return name; }
    public void setName(String name) { this.name = name; }

    public String getDescription() { return description; }
    public void setDescription(String description) { this.description = description; }

    public Long getCoverId() { return coverId; }
    public void setCoverId(Long coverId) { this.coverId = coverId; }

    public PlaylistMode getMode() { return mode; }
    public void setMode(PlaylistMode mode) {
        this.mode = mode != null ? mode : PlaylistMode.shuffle_weighted;
    }

    public Long getSyncVer() { return syncVer; }
    public void setSyncVer(Long syncVer) { this.syncVer = syncVer; }

    public LocalDateTime getCreatedAt() { return createdAt; }
    public void setCreatedAt(LocalDateTime createdAt) { this.createdAt = createdAt; }

    public LocalDateTime getUpdatedAt() { return updatedAt; }
    public void setUpdatedAt(LocalDateTime updatedAt) { this.updatedAt = updatedAt; }

    @Override
    public boolean equals(Object o) {
        if (this == o) return true;
        if (!(o instanceof Playlist)) return false;
        Playlist other = (Playlist) o;
        return id != null && id.equals(other.getId());
    }

    @Override
    public int hashCode() {
        return getClass().hashCode();
    }

    @Override
    public String toString() {
        return "Playlist{id=" + id + ", name='" + name + "', mode=" + mode + "}";
    }

    public enum PlaylistMode { normal, shuffle_weighted }
}
