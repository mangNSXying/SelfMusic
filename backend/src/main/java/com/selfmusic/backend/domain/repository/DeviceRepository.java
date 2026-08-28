package com.selfmusic.backend.domain.repository;

import com.selfmusic.backend.domain.entity.Device;
import org.springframework.data.jpa.repository.JpaRepository;
import java.util.Optional;

public interface DeviceRepository extends JpaRepository<Device, Long> {
    Optional<Device> findByClientId(String clientId);
    Optional<Device> findByTokenHashAndRevokedFalse(String tokenHash);
    Optional<Device> findByRefreshTokenHashAndRevokedFalse(String refreshTokenHash);
}
