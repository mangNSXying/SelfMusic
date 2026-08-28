package com.selfmusic.backend.domain.entity;

import com.fasterxml.jackson.annotation.JsonIgnore;
import jakarta.persistence.*;
import java.time.LocalDateTime;

@Entity
@Table(name = "devices")
public class Device {
    @Id @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "client_id", unique = true, nullable = false, length = 36)
    private String clientId;

    @Column(nullable = false)
    private String name;

    @Column(length = 50)
    private String platform;

    @JsonIgnore
    @Column(name = "token_hash", nullable = false, length = 64)
    private String tokenHash;

    private boolean revoked = false;

    @Column(name = "paired_at")
    private LocalDateTime pairedAt;

    @Column(name = "last_seen_at")
    private LocalDateTime lastSeenAt;

    @JsonIgnore
    @Column(name = "token_expires_at")
    private LocalDateTime tokenExpiresAt;

    @JsonIgnore
    @Column(name = "refresh_token_hash")
    private String refreshTokenHash;

    @JsonIgnore
    @Column(name = "refresh_expires_at")
    private LocalDateTime refreshExpiresAt;

    @JsonIgnore
    @Column(name = "renewed_at")
    private LocalDateTime renewedAt;

    public Long getId() { return id; }
    public void setId(Long id) { this.id = id; }

    public String getClientId() { return clientId; }
    public void setClientId(String clientId) { this.clientId = clientId; }

    public String getName() { return name; }
    public void setName(String name) { this.name = name; }

    public String getPlatform() { return platform; }
    public void setPlatform(String platform) { this.platform = platform; }

    public String getTokenHash() { return tokenHash; }
    public void setTokenHash(String tokenHash) { this.tokenHash = tokenHash; }

    public boolean isRevoked() { return revoked; }
    public void setRevoked(boolean revoked) { this.revoked = revoked; }

    public LocalDateTime getPairedAt() { return pairedAt; }
    public void setPairedAt(LocalDateTime pairedAt) { this.pairedAt = pairedAt; }

    public LocalDateTime getLastSeenAt() { return lastSeenAt; }
    public void setLastSeenAt(LocalDateTime lastSeenAt) { this.lastSeenAt = lastSeenAt; }

    public LocalDateTime getTokenExpiresAt() { return tokenExpiresAt; }
    public void setTokenExpiresAt(LocalDateTime tokenExpiresAt) { this.tokenExpiresAt = tokenExpiresAt; }

    public String getRefreshTokenHash() { return refreshTokenHash; }
    public void setRefreshTokenHash(String refreshTokenHash) { this.refreshTokenHash = refreshTokenHash; }

    public LocalDateTime getRefreshExpiresAt() { return refreshExpiresAt; }
    public void setRefreshExpiresAt(LocalDateTime refreshExpiresAt) { this.refreshExpiresAt = refreshExpiresAt; }

    public LocalDateTime getRenewedAt() { return renewedAt; }
    public void setRenewedAt(LocalDateTime renewedAt) { this.renewedAt = renewedAt; }

    @Override
    public boolean equals(Object o) {
        if (this == o) return true;
        if (!(o instanceof Device)) return false;
        Device other = (Device) o;
        return id != null && id.equals(other.getId());
    }

    @Override
    public int hashCode() {
        return getClass().hashCode();
    }

    @Override
    public String toString() {
        // 不输出 token_hash，避免日志泄露凭据
        return "Device{id=" + id + ", clientId='" + clientId + "', name='" + name
                + "', platform='" + platform + "', revoked=" + revoked + "}";
    }
}
