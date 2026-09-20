package com.selfmusic.backend.domain.entity;

import jakarta.persistence.*;
import java.time.LocalDateTime;

/**
 * 阶段5 同步事件流水（DESIGN.md §7.2）。
 * seq 全局单调递增 = pull 的 since_cursor 比较基准；
 * event_uuid 幂等键（重复 push 直接跳过）；
 * arrived_at 为服务端仲裁时钟（客户端 occurred_at 缺失或打平时用）。
 */
@Entity
@Table(name = "sync_events")
public class SyncEvent {
    @Id @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long seq;

    @Column(name = "event_uuid", nullable = false, length = 36)
    private String eventUuid;

    @Column(name = "device_client_id", nullable = false, length = 36)
    private String deviceClientId;

    @Column(nullable = false, length = 30)
    private String type;

    @Column(columnDefinition = "TEXT")
    private String payload;

    @Column(name = "occurred_at")
    private LocalDateTime occurredAt;

    @Column(name = "arrived_at")
    private LocalDateTime arrivedAt;

    @PrePersist
    void touch() { if (arrivedAt == null) arrivedAt = LocalDateTime.now(); }

    public Long getSeq() { return seq; }
    public void setSeq(Long seq) { this.seq = seq; }

    public String getEventUuid() { return eventUuid; }
    public void setEventUuid(String eventUuid) { this.eventUuid = eventUuid; }

    public String getDeviceClientId() { return deviceClientId; }
    public void setDeviceClientId(String deviceClientId) { this.deviceClientId = deviceClientId; }

    public String getType() { return type; }
    public void setType(String type) { this.type = type; }

    public String getPayload() { return payload; }
    public void setPayload(String payload) { this.payload = payload; }

    public LocalDateTime getOccurredAt() { return occurredAt; }
    public void setOccurredAt(LocalDateTime occurredAt) { this.occurredAt = occurredAt; }

    public LocalDateTime getArrivedAt() { return arrivedAt; }
    public void setArrivedAt(LocalDateTime arrivedAt) { this.arrivedAt = arrivedAt; }
}
