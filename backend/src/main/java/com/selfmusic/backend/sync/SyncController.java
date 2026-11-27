package com.selfmusic.backend.sync;

import com.selfmusic.backend.common.ApiResponse;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.http.MediaType;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.servlet.mvc.method.annotation.SseEmitter;

import java.util.List;
import java.util.Map;

/** 阶段5 同步端点（DEVELOPER.md「API 设计」；认证走全局 TokenFilter，调用设备=principal clientId）。 */
@RestController
@RequestMapping("/api/v1/sync")
public class SyncController {

    private final SyncService syncService;
    private final BreakpointPushHub pushHub;

    public SyncController(SyncService syncService, BreakpointPushHub pushHub) {
        this.syncService = syncService;
        this.pushHub = pushHub;
    }

    @GetMapping("/pull")
    public ApiResponse<Map<String, Object>> pull(
            @RequestParam(name = "since_cursor", defaultValue = "0") long sinceCursor) {
        return ApiResponse.ok(syncService.pull(clientId(), sinceCursor));
    }

    @PostMapping("/push")
    public ApiResponse<Map<String, Object>> push(@RequestBody PushRequest body) {
        List<PushEvent> events = body == null || body.events() == null ? List.of() : body.events();
        return ApiResponse.ok(syncService.push(clientId(), events));
    }

    /**
     * 断点变化 SSE 唤醒通道。只发“哪个歌单变了”的信号，不携带权威快照；
     * 客户端收到后仍走 /playstates/latest 或 /sync/pull，既有仲裁/守卫不变。
     */
    @GetMapping(value = "/stream", produces = MediaType.TEXT_EVENT_STREAM_VALUE)
    public SseEmitter stream(HttpServletResponse response) {
        response.setHeader("Cache-Control", "no-cache");
        response.setHeader("X-Accel-Buffering", "no");
        response.setHeader("Connection", "keep-alive");
        return pushHub.connect(clientId(), syncService.serverHello());
    }

    public record PushRequest(List<PushEvent> events) {}

    public static String clientId() {
        Authentication auth = SecurityContextHolder.getContext().getAuthentication();
        if (auth == null || auth.getPrincipal() == null) {
            throw new com.selfmusic.backend.common.BizException(40101, "unauthenticated");
        }
        return auth.getPrincipal().toString();
    }
}
