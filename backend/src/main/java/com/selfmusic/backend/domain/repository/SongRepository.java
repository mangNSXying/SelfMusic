package com.selfmusic.backend.domain.repository;

import com.selfmusic.backend.common.MusicSource;
import com.selfmusic.backend.domain.entity.Song;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.Optional;

public interface SongRepository extends JpaRepository<Song, Long> {

    Optional<Song> findBySourceAndSourceRef(MusicSource source, String sourceRef);

    Page<Song> findByHiddenFalse(Pageable pageable);

    @Query("SELECT s FROM Song s WHERE s.hidden=false AND "
         + "(LOWER(s.title) LIKE LOWER(CONCAT('%',:q,'%')) OR "
         +  "LOWER(s.artist) LIKE LOWER(CONCAT('%',:q,'%')))")
    Page<Song> search(@Param("q") String q, Pageable pageable);

    Page<Song> findByArtistAndHiddenFalse(String artist, Pageable pageable);

    long countBySourceAndHiddenFalse(MusicSource source);

    List<Song> findByFavoriteTrueAndHiddenFalse();
}
