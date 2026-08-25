package com.selfmusic.backend.domain.repository;

import com.selfmusic.backend.domain.entity.Cover;
import org.springframework.data.jpa.repository.JpaRepository;
import java.util.Optional;

public interface CoverRepository extends JpaRepository<Cover, Long> {
    Optional<Cover> findByContentHash(String contentHash);
}
