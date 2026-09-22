package com.selfmusic.backend.domain.entity;

import jakarta.persistence.*;
import java.time.LocalDateTime;

/**
 * 播放源同步行（阶段5，服务端无曲库）。
 *
 * 远端类型源（webdav/smb/onedrive…；本地文件夹源不参与同步）的多设备配置收敛：
 * 身份 {@code client_uuid}，去重键 {@code (kind, address)}（名称不参与去重）。
 * {@code config_json} 存非敏感配置（不含密码），密码仅各设备本地 SecretStore 保存。
 */
@Entity
@Table(name = "sync_sources",
       uniqueConstraints = {
           @UniqueConstraint(name = "uk_sync_source_uuid", columnNames = {"client_uuid"}),
           @UniqueConstraint(name = "uk_sync_source_identity", columnNames = {"kind", "address"})
       })
public class SyncSource {
    @Id @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "client_uuid", nullable = false, length = 36)
    private String clientUuid;

    @Column(nullable = false, length = 20)
    private String kind;

    @Column(length = 100)
    private String name;

    /** 去重地址：WebDAV=baseUrl；SMB=host/share；未来源按协议取稳定定位。 */
    @Column(nullable = false, length = 500)
    private String address;

    /** 非敏感配置 JSON（不含密码）。 */
    @Column(name = "config_json", columnDefinition = "TEXT")
    private String configJson;

    private boolean enabled = true;

    private boolean deleted = false;

    @Column(name = "last_event_at")
    private LocalDateTime lastEventAt;

    @Column(name = "sync_ver")
    private Long syncVer = 0L;

    @Column(name = "created_at")
    private LocalDateTime createdAt;

    @Column(name = "updated_at")
    private LocalDateTime updatedAt;

    @PrePersist
    @PreUpdate
    void touch() {
        updatedAt = LocalDateTime.now();
        if (createdAt == null) createdAt = LocalDateTime.now();
    }

    public Long getId() { return id; }
    public void setId(Long id) { this.id = id; }

    public String getClientUuid() { return clientUuid; }
    public void setClientUuid(String clientUuid) { this.clientUuid = clientUuid; }

    public String getKind() { return kind; }
    public void setKind(String kind) { this.kind = kind; }

    public String getName() { return name; }
    public void setName(String name) { this.name = name; }

    public String getAddress() { return address; }
    public void setAddress(String address) { this.address = address; }

    public String getConfigJson() { return configJson; }
    public void setConfigJson(String configJson) { this.configJson = configJson; }

    public boolean isEnabled() { return enabled; }
    public void setEnabled(boolean enabled) { this.enabled = enabled; }

    public boolean isDeleted() { return deleted; }
    public void setDeleted(boolean deleted) { this.deleted = deleted; }

    public LocalDateTime getLastEventAt() { return lastEventAt; }
    public void setLastEventAt(LocalDateTime lastEventAt) { this.lastEventAt = lastEventAt; }

    public Long getSyncVer() { return syncVer; }
    public void setSyncVer(Long syncVer) { this.syncVer = syncVer; }

    public LocalDateTime getCreatedAt() { return createdAt; }
    public void setCreatedAt(LocalDateTime createdAt) { this.createdAt = createdAt; }

    public LocalDateTime getUpdatedAt() { return updatedAt; }
    public void setUpdatedAt(LocalDateTime updatedAt) { this.updatedAt = updatedAt; }

    @Override
    public boolean equals(Object o) {
        if (this == o) return true;
        if (!(o instanceof SyncSource)) return false;
        SyncSource other = (SyncSource) o;
        return id != null && id.equals(other.getId());
    }

    @Override
    public int hashCode() {
        return getClass().hashCode();
    }

    @Override
    public String toString() {
        return "SyncSource{id=" + id + ", uuid='" + clientUuid + "', kind='" + kind
                + "', address='" + address + "'}";
    }
}
