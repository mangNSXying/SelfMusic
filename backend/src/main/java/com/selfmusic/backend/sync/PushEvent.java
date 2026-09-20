package com.selfmusic.backend.sync;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.databind.JsonNode;

import java.time.LocalDateTime;

/**
 * push 上推的单个事件（body JSON 直接反序列化）。
 * occurred_at 为客户端发生时间（ISO-8601，如 2026-09-20T12:34:56.789）；
 * 缺失时 LWW 仲裁恒判输（P1 客户端恒传，见 SyncEngine）。
 */
@JsonIgnoreProperties(ignoreUnknown = true)
public record PushEvent(
        String event_uuid,
        String device_client_id,
        String type,
        LocalDateTime occurred_at,
        JsonNode payload
) {}
