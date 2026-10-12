package com.selfmusic.backend.sync;

import com.selfmusic.backend.common.ApiResponse;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.web.bind.annotation.*;

import java.util.List;
import java.util.Map;

/** 阶段5 同步端点（DEVELOPER.md「API 设计」；认证走全局 TokenFilter，调用设备=principal clientId）。 */
@RestController
@RequestMapping("/api/v1/sync")
public class SyncController {

    private final SyncService syncService;

    public SyncController(SyncService syncService) {
        this.syncService = syncService;
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

    public record PushRequest(List<PushEvent> events) {}

    public static String clientId() {
        Authentication auth = SecurityContextHolder.getContext().getAuthentication();
        if (auth == null || auth.getPrincipal() == null) {
            throw new com.selfmusic.backend.common.BizException(40101, "unauthenticated");
        }
        return auth.getPrincipal().toString();
    }
}
