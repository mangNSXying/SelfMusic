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
import lombok.RequiredArgsConstructor;
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
@RequiredArgsConstructor
@Transactional
public class PlayStateController {

    private final PlaylistRepository playlistRepository;
    private final PlayStateRepository playStateRepository;
    private final SyncService syncService;
    private final ObjectMapper objectMapper;

    @PutMapping("/{playlistId}")
    public ApiResponse<Map<String, Object>> put(@PathVariable Long playlistId,
                                                @RequestBody Map<String, Object> body) {
        Playlist p = playlistRepository.findById(playlistId)
                .orElseThrow(() -> new BizException(40402, "playlist not found: " + playlistId));
        if (p.isDeleted()) throw new BizException(40402, "playlist not found: " + playlistId);
        if (p.getClientUuid() == null) throw new BizException(40001, "playlist not syncable (no client_uuid)");
        Object songId = body.get("song_id");
        if (songId == null) throw new BizException(40001, "song_id required");
        ObjectNode payload = objectMapper.createObjectNode();
        payload.put("playlist_uuid", p.getClientUuid());
        payload.put("song_id", toLong(songId));
        Object pos = body.get("position_ms");
        payload.put("position_ms", pos == null ? 0 : toInt(pos));

        String me = SyncController.clientId();
        PushEvent ev = new PushEvent(UUID.randomUUID().toString(), me,
                SyncEventTypes.BREAKPOINT_SET, LocalDateTime.now(), payload);
        Map<String, Object> r = syncService.push(me, List.of(ev));
        @SuppressWarnings("unchecked")
        Map<String, Object> corrections = (Map<String, Object>) r.get("corrections");
        if (!corrections.isEmpty()) {
            return ApiResponse.ok((Map<String, Object>) corrections.values().iterator().next());
        }
        PlayState st = playStateRepository.findById(playlistId).orElseThrow();
        return ApiResponse.ok(SyncService.playstateSnapshot(st, p.getClientUuid()));
    }

    private static long toLong(Object v) {
        if (v instanceof Number n) return n.longValue();
        return Long.parseLong(String.valueOf(v));
    }

    private static int toInt(Object v) {
        if (v instanceof Number n) return n.intValue();
        return Integer.parseInt(String.valueOf(v));
    }
}
