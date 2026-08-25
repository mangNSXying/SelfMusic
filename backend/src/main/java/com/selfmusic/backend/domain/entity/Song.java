package com.selfmusic.backend.domain.entity;

import jakarta.persistence.*;
import java.math.BigDecimal;
import java.time.LocalDateTime;

@Entity
@Table(name = "songs")
public class Song {
    @Id @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "album_id")
    private Album album;

    @Column(nullable = false)
    private String title;

    private String artist;

    @Column(name = "track_no")
    private Short trackNo;

    private Short year;
    private String genre;
    private Integer duration;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 10)
    private com.selfmusic.backend.common.MusicSource source;

    @Column(name = "source_ref", nullable = false)
    private String sourceRef;

    @Column(name = "file_size", nullable = false)
    private Long fileSize;

    @Column(name = "file_mtime")
    private LocalDateTime fileMtime;

    private String checksum;
    private String format;

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "cover_id")
    private Cover cover;

    @Column(name = "like_streak")
    private Integer likeStreak = 0;

    @Column(name = "dislike_streak")
    private Integer dislikeStreak = 0;

    @Column(precision = 6, scale = 4)
    private BigDecimal weight = BigDecimal.ONE;

    private boolean frozen = false;

    @Column(name = "is_favorite")
    private boolean favorite = false;

    @Column(name = "is_hidden")
    private boolean hidden = false;

    @Column(name = "missing_since")
    private LocalDateTime missingSince;

    @Column(name = "play_count")
    private Integer playCount = 0;

    @Column(name = "last_played_at")
    private LocalDateTime lastPlayedAt;

    public Long getId() { return id; }
    public void setId(Long id) { this.id = id; }

    public Album getAlbum() { return album; }
    public void setAlbum(Album album) { this.album = album; }

    public String getTitle() { return title; }
    public void setTitle(String title) { this.title = title; }

    public String getArtist() { return artist; }
    public void setArtist(String artist) { this.artist = artist; }

    public Short getTrackNo() { return trackNo; }
    public void setTrackNo(Short trackNo) { this.trackNo = trackNo; }

    public Short getYear() { return year; }
    public void setYear(Short year) { this.year = year; }

    public String getGenre() { return genre; }
    public void setGenre(String genre) { this.genre = genre; }

    public Integer getDuration() { return duration; }
    public void setDuration(Integer duration) { this.duration = duration; }

    public com.selfmusic.backend.common.MusicSource getSource() { return source; }
    public void setSource(com.selfmusic.backend.common.MusicSource source) { this.source = source; }

    public String getSourceRef() { return sourceRef; }
    public void setSourceRef(String sourceRef) { this.sourceRef = sourceRef; }

    public Long getFileSize() { return fileSize; }
    public void setFileSize(Long fileSize) { this.fileSize = fileSize; }

    public LocalDateTime getFileMtime() { return fileMtime; }
    public void setFileMtime(LocalDateTime fileMtime) { this.fileMtime = fileMtime; }

    public String getChecksum() { return checksum; }
    public void setChecksum(String checksum) { this.checksum = checksum; }

    public String getFormat() { return format; }
    public void setFormat(String format) { this.format = format; }

    public Cover getCover() { return cover; }
    public void setCover(Cover cover) { this.cover = cover; }

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

    public boolean isHidden() { return hidden; }
    public void setHidden(boolean hidden) { this.hidden = hidden; }

    public LocalDateTime getMissingSince() { return missingSince; }
    public void setMissingSince(LocalDateTime missingSince) { this.missingSince = missingSince; }

    public Integer getPlayCount() { return playCount; }
    public void setPlayCount(Integer playCount) { this.playCount = playCount; }

    public LocalDateTime getLastPlayedAt() { return lastPlayedAt; }
    public void setLastPlayedAt(LocalDateTime lastPlayedAt) { this.lastPlayedAt = lastPlayedAt; }

    @Override
    public boolean equals(Object o) {
        if (this == o) return true;
        if (!(o instanceof Song)) return false;
        Song other = (Song) o;
        return id != null && id.equals(other.getId());
    }

    @Override
    public int hashCode() {
        return getClass().hashCode();
    }

    @Override
    public String toString() {
        return "Song{id=" + id + ", title='" + title + "', artist='" + artist
                + "', source=" + source + ", sourceRef='" + sourceRef + "'}";
    }
}
