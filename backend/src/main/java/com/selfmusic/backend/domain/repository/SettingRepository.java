package com.selfmusic.backend.domain.repository;

import com.selfmusic.backend.domain.entity.Setting;
import org.springframework.data.jpa.repository.JpaRepository;

public interface SettingRepository extends JpaRepository<Setting, String> {
}
