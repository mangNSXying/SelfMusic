package com.selfmusic.backend.library;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.selfmusic.backend.common.ApiResponse;
import com.selfmusic.backend.common.BizException;
import com.selfmusic.backend.sync.SyncController;
import com.selfmusic.backend.sync.SyncService;
import lombok.RequiredArgsConstructor;
import org.springframework.web.bind.annotation.*;

import java.util.Map;

/**
 * 阶段5 歌曲调权直调端点（DESIGN.md §4.4）。
 * event 接受短名（liked）或全名（song.liked）；经 SyncService 事件管线应用，
 * 保证其它设备经 pull 可见。payload 透传（如 disliked 的 enabled 开关）。
 */
@RestController
@RequestMapping("/api/v1/songs")
@RequiredArgsConstructor
public class SongController {

    private final SyncService syncService;
    private final ObjectMapper objectMapper;

    @PostMapping("/{id}/weight")
    public ApiResponse<Map<String, Object>> weight(@PathVariable Long id,
                                                   @RequestBody Map<String, Object> body) {
        Object e = body.get("event");
        if (e == null || e.toString().isBlank()) throw new BizException(40001, "event required");
        String type = e.toString().startsWith("song.") ? e.toString() : "song." + e;
        ObjectNode payload = objectMapper.createObjectNode();
        for (Map.Entry<String, Object> en : body.entrySet()) {
            if ("event".equals(en.getKey()) || en.getValue() == null) continue;
            Object v = en.getValue();
            if (v instanceof Number n) payload.put(en.getKey(), n.longValue());
            else if (v instanceof Boolean b) payload.put(en.getKey(), b);
            else payload.put(en.getKey(), v.toString());
        }
        return ApiResponse.ok(syncService.applyDirectWeight(id, type, payload, SyncController.clientId()));
    }
}
