package com.selfmusic.backend.playlist;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.selfmusic.backend.common.ApiResponse;
import com.selfmusic.backend.common.BizException;
import com.selfmusic.backend.domain.entity.Playlist;
import com.selfmusic.backend.domain.repository.PlaylistRepository;
import com.selfmusic.backend.sync.PushEvent;
import com.selfmusic.backend.sync.SyncController;
import com.selfmusic.backend.sync.SyncEventTypes;
import com.selfmusic.backend.sync.SyncService;
import lombok.RequiredArgsConstructor;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.*;

import java.time.LocalDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 阶段5 歌单 CRUD（DESIGN.md §4.4）。
 * 所有写操作都经 SyncService 事件管线（服务端生成 uuid、occurred=now），
 * 保证其它设备经 pull 可见；读返回与 pull 同形的快照。
 */
@RestController
@RequestMapping("/api/v1/playlists")
@RequiredArgsConstructor
@Transactional
public class PlaylistController {

    private final PlaylistRepository playlistRepository;
    private final SyncService syncService;
    private final ObjectMapper objectMapper;

    @GetMapping
    public ApiResponse<List<Map<String, Object>>> list() {
        List<Map<String, Object>> out = new ArrayList<>();
        for (Playlist p : playlistRepository.findAllByOrderByUpdatedAtDesc()) {
            if (!p.isDeleted()) out.add(syncService.playlistSnapshot(p));
        }
        return ApiResponse.ok(out);
    }

    @GetMapping("/{id}")
    public ApiResponse<Map<String, Object>> get(@PathVariable Long id) {
        Playlist p = playlistRepository.findById(id)
                .orElseThrow(() -> new BizException(40402, "playlist not found: " + id));
        if (p.isDeleted()) throw new BizException(40402, "playlist not found: " + id);
        return ApiResponse.ok(syncService.playlistSnapshot(p));
    }

    @PostMapping
    public ApiResponse<Map<String, Object>> create(@RequestBody Map<String, Object> body) {
        ObjectNode payload = objectMapper.createObjectNode();
        String uuid = str(body, "client_uuid");
        if (uuid == null || uuid.isBlank()) uuid = UUID.randomUUID().toString();
        payload.put("client_uuid", uuid);
        if (body.containsKey("name")) payload.put("name", str(body, "name"));
        if (body.containsKey("description")) {
            Object d = body.get("description");
            if (d == null) payload.putNull("description"); else payload.put("description", d.toString());
        }
        if (body.containsKey("mode")) payload.put("mode", str(body, "mode"));
        pushOne(SyncEventTypes.PLAYLIST_CREATE, payload);
        Playlist created = playlistRepository.findByClientUuid(uuid)
                .orElseThrow(() -> new BizException(50002, "playlist create failed"));
        return ApiResponse.ok(syncService.playlistSnapshot(created));
    }

    @PutMapping("/{id}")
    public ApiResponse<Map<String, Object>> update(@PathVariable Long id,
                                                   @RequestBody Map<String, Object> body) {
        Playlist p = playlistRepository.findById(id)
                .orElseThrow(() -> new BizException(40402, "playlist not found: " + id));
        if (p.getClientUuid() == null) throw new BizException(40001, "playlist not syncable (no client_uuid)");
        ObjectNode payload = objectMapper.createObjectNode();
        payload.put("client_uuid", p.getClientUuid());
        if (body.containsKey("name")) payload.put("name", str(body, "name"));
        if (body.containsKey("description")) {
            Object d = body.get("description");
            if (d == null) payload.putNull("description"); else payload.put("description", d.toString());
        }
        if (body.containsKey("mode")) payload.put("mode", str(body, "mode"));
        Map<String, Object> r = pushOne(SyncEventTypes.PLAYLIST_UPDATE, payload);
        @SuppressWarnings("unchecked")
        Map<String, Object> corrections = (Map<String, Object>) r.get("corrections");
        if (!corrections.isEmpty()) {
            return ApiResponse.ok((Map<String, Object>) corrections.values().iterator().next());
        }
        Playlist fresh = playlistRepository.findById(id).orElseThrow();
        return ApiResponse.ok(syncService.playlistSnapshot(fresh));
    }

    @DeleteMapping("/{id}")
    public ApiResponse<Void> delete(@PathVariable Long id) {
        Playlist p = playlistRepository.findById(id)
                .orElseThrow(() -> new BizException(40402, "playlist not found: " + id));
        if (p.getClientUuid() == null) throw new BizException(40001, "playlist not syncable (no client_uuid)");
        ObjectNode payload = objectMapper.createObjectNode();
        payload.put("client_uuid", p.getClientUuid());
        pushOne(SyncEventTypes.PLAYLIST_DELETE, payload);
        return ApiResponse.ok();
    }

    @PostMapping("/{id}/items")
    public ApiResponse<Map<String, Object>> addItem(@PathVariable Long id,
                                                    @RequestBody Map<String, Object> body) {
        Playlist p = playlistOf(id);
        ObjectNode payload = objectMapper.createObjectNode();
        payload.put("playlist_uuid", p.getClientUuid());
        payload.put("song_id", toLong(body.get("song_id")));
        if (body.containsKey("sort_order")) payload.put("sort_order", toInt(body.get("sort_order")));
        pushOne(SyncEventTypes.PLAYLIST_ITEM_ADD, payload);
        return ApiResponse.ok(syncService.playlistSnapshot(playlistRepository.findById(id).orElseThrow()));
    }

    @DeleteMapping("/{id}/items/{songId}")
    public ApiResponse<Map<String, Object>> removeItem(@PathVariable Long id,
                                                       @PathVariable Long songId) {
        Playlist p = playlistOf(id);
        ObjectNode payload = objectMapper.createObjectNode();
        payload.put("playlist_uuid", p.getClientUuid());
        payload.put("song_id", songId);
        pushOne(SyncEventTypes.PLAYLIST_ITEM_REMOVE, payload);
        return ApiResponse.ok(syncService.playlistSnapshot(playlistRepository.findById(id).orElseThrow()));
    }

    @PutMapping("/{id}/items/{songId}")
    public ApiResponse<Map<String, Object>> moveItem(@PathVariable Long id,
                                                     @PathVariable Long songId,
                                                     @RequestBody Map<String, Object> body) {
        Playlist p = playlistOf(id);
        ObjectNode payload = objectMapper.createObjectNode();
        payload.put("playlist_uuid", p.getClientUuid());
        payload.put("song_id", songId);
        payload.put("sort_order", toInt(body.get("sort_order")));
        pushOne(SyncEventTypes.PLAYLIST_ITEM_MOVE, payload);
        return ApiResponse.ok(syncService.playlistSnapshot(playlistRepository.findById(id).orElseThrow()));
    }

    private Playlist playlistOf(Long id) {
        Playlist p = playlistRepository.findById(id)
                .orElseThrow(() -> new BizException(40402, "playlist not found: " + id));
        if (p.isDeleted()) throw new BizException(40402, "playlist not found: " + id);
        if (p.getClientUuid() == null) throw new BizException(40001, "playlist not syncable (no client_uuid)");
        return p;
    }

    private Map<String, Object> pushOne(String type, ObjectNode payload) {
        String me = SyncController.clientId();
        PushEvent ev = new PushEvent(UUID.randomUUID().toString(), me, type,
                LocalDateTime.now(), payload);
        return syncService.push(me, List.of(ev));
    }

    private static String str(Map<String, Object> body, String key) {
        Object v = body.get(key);
        return v == null ? null : v.toString();
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
