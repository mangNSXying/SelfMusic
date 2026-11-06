package com.selfmusic.backend.domain.entity;

import jakarta.persistence.*;
import java.time.LocalDateTime;

/**
 * 客户端设置同步行（阶段5 设置同步 v1）：每个可同步设置键一条当前值。
 *
 * <p>只存播放偏好与媒体库规则白名单内的键（见 {@code SyncableSettings}）；
 * 缓存路径、音量、均衡器、网络凭据、快捷键等设备本地项永远不会进入本表。
 * 多设备按 {@code last_event_at} 做逐键 LWW。</p>
 */
@Entity
@Table(name = "client_settings")
public class ClientSetting {
    @Id
    @Column(name = "setting_key", length = 64)
    private String settingKey;

    @Column(name = "setting_value", nullable = false, columnDefinition = "MEDIUMTEXT")
    private String settingValue;

    @Column(name = "updated_at", nullable = false)
    private LocalDateTime updatedAt;

    @Column(name = "last_event_at", nullable = false)
    private LocalDateTime lastEventAt;

    @Column(name = "device_client_id", length = 64)
    private String deviceClientId;

    public String getSettingKey() { return settingKey; }
    public void setSettingKey(String settingKey) { this.settingKey = settingKey; }

    public String getSettingValue() { return settingValue; }
    public void setSettingValue(String settingValue) { this.settingValue = settingValue; }

    public LocalDateTime getUpdatedAt() { return updatedAt; }
    public void setUpdatedAt(LocalDateTime updatedAt) { this.updatedAt = updatedAt; }

    public LocalDateTime getLastEventAt() { return lastEventAt; }
    public void setLastEventAt(LocalDateTime lastEventAt) { this.lastEventAt = lastEventAt; }

    public String getDeviceClientId() { return deviceClientId; }
    public void setDeviceClientId(String deviceClientId) { this.deviceClientId = deviceClientId; }
}
