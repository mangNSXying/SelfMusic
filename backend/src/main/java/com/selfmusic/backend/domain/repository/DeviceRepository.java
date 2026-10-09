package com.selfmusic.backend.domain.repository;

import com.selfmusic.backend.domain.entity.Device;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;

import java.util.Optional;

public interface DeviceRepository extends JpaRepository<Device, Long> {
    Optional<Device> findByClientId(String clientId);
    Optional<Device> findByTokenHashAndRevokedFalse(String tokenHash);
    Optional<Device> findByRefreshTokenHashAndRevokedFalse(String refreshTokenHash);

    /**
     * 事件日志压缩水位：所有未吊销设备都消费到的最小 pull cursor（null=尚无
     * 设备 pull 过，不做任何压缩）。
     */
    @Query("select min(d.lastPullCursor) from Device d "
            + "where d.revoked = false and d.lastPullCursor is not null")
    Long minActivePullCursor();
}
