package com.selfmusic.backend.playlist;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.selfmusic.backend.common.ApiResponse;
import com.selfmusic.backend.common.BizException;
import com.selfmusic.backend.domain.entity.PlayState;
import com.selfmusic.backend.domain.entity.Playlist;
import com.selfmusic.backend.domain.repository.PlayStateRepository;
import com.selfmusic.backend.domain.repository.PlaylistRepository;
import com.selfmusic.backend.sync.PushEvent;
import com.selfmusic.backend.sync.SyncController;
import com.selfmusic.backend.sync.SyncEventTypes;
import com.selfmusic.backend.sync.SyncService;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.*;

import java.time.LocalDateTime;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 阶段5 断点续播 PUT（DESIGN.md §4.4）。
 * 经 SyncService 事件管线写 breakpoint.set，保证其它设备经 pull 可见；
 * LWW 判输时返回服务端快照（correction）而非本地值。
 */
@RestController
@RequestMapping("/api/v1/playstates")
@Transactional
public class PlayStateController {

    private final PlaylistRepository playlistRepository;
    private final PlayStateRepository playStateRepository;
    private final SyncService syncService;
    private final ObjectMapper objectMapper;

    public PlayStateController(PlaylistRepository playlistRepository,
                               PlayStateRepository playStateRepository,
                               SyncService syncService,
                               ObjectMapper objectMapper) {
        this.playlistRepository = playlistRepository;
        this.playStateRepository = playStateRepository;
        this.syncService = syncService;
        this.objectMapper = objectMapper;
    }

    @PutMapping("/{playlistId}")
    public ApiResponse<Map<String, Object>> put(@PathVariable Long playlistId,
                                                @RequestBody Map<String, Object> body) {
        Playlist p = playlistRepository.findById(playlistId)
                .orElseThrow(() -> new BizException(40402, "playlist not found: " + playlistId));
        if (p.isDeleted()) throw new BizException(40402, "playlist not found: " + playlistId);
        if (p.getClientUuid() == null) throw new BizException(40001, "playlist not syncable (no client_uuid)");
        Object sourceId = body.get("source_id");
        Object source = body.get("source");
        Object sourceRef = body.get("source_ref");
        if (sourceRef == null || sourceRef.toString().isBlank()) {
            throw new BizException(40001, "source_ref required");
        }
        String sid = sourceId == null ? null : sourceId.toString();
        if (sid == null || sid.isBlank()) {
            if (source == null || source.toString().isBlank()) {
                throw new BizException(40001, "source_id required");
            }
            sid = "legacy:" + source;
        }
        ObjectNode payload = objectMapper.createObjectNode();
        payload.put("playlist_uuid", p.getClientUuid());
        payload.put("source_id", sid);
        if (source != null && !source.toString().isBlank()) {
            payload.put("source", source.toString());
        }
        payload.put("source_ref", sourceRef.toString());
        Object pos = body.get("position_ms");
        payload.put("position_ms", pos == null ? 0 : toInt(pos));

        String me = SyncController.clientId();
        PushEvent ev = new PushEvent(UUID.randomUUID().toString(), me,
                SyncEventTypes.BREAKPOINT_SET, LocalDateTime.now(), payload);
        Map<String, Object> r = syncService.push(me, List.of(ev));
        @SuppressWarnings("unchecked")
        Map<String, Object> corrections = (Map<String, Object>) r.get("corrections");
        if (!corrections.isEmpty()) {
            @SuppressWarnings("unchecked")
            Map<String, Object> first =
                    (Map<String, Object>) corrections.values().iterator().next();
            return ApiResponse.ok(first);
        }
        PlayState st = playStateRepository.findById(playlistId).orElseThrow();
        return ApiResponse.ok(SyncService.playstateSnapshot(st, p.getClientUuid()));
    }

    private static int toInt(Object v) {
        if (v instanceof Number n) return n.intValue();
        return Integer.parseInt(String.valueOf(v));
    }
}
