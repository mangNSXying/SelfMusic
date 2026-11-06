package com.selfmusic.backend.domain.repository;

import com.selfmusic.backend.domain.entity.ClientSetting;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;

public interface ClientSettingRepository extends JpaRepository<ClientSetting, String> {
    List<ClientSetting> findAllByOrderBySettingKeyAsc();
}
