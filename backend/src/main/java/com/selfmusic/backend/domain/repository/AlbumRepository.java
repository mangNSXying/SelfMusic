package com.selfmusic.backend.domain.repository;

import com.selfmusic.backend.domain.entity.Album;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;
import java.util.Optional;

public interface AlbumRepository extends JpaRepository<Album, Long> {
    Page<Album> findByArtistContainingIgnoreCase(String artist, Pageable pageable);
    Optional<Album> findByArtistAndAlbum(String artist, String album);
}
