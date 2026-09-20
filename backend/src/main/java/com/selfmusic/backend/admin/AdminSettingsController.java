package com.selfmusic.backend.admin;

import com.selfmusic.backend.common.ApiResponse;
import com.selfmusic.backend.domain.service.SettingService;
import lombok.RequiredArgsConstructor;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * 管理端设置/配置下发（settings.md §3.3 / §3.5 暂缓项）：
 * <ul>
 *   <li>GET /api/v1/admin/config —— 缓存建议值等（客户端 follow_server 双来源）；</li>
 *   <li>GET /api/v1/admin/pairing-token —— 当前配对密钥明文（权威源 env 的 settings 镜像）。</li>
 * </ul>
 */
@RestController
@RequestMapping("/api/v1/admin")
@RequiredArgsConstructor
public class AdminSettingsController {

    private final SettingService settingService;

    @GetMapping("/config")
    public ApiResponse<Map<String, Object>> config() {
        Map<String, Object> data = new LinkedHashMap<>();
        data.put("cache_max_bytes",
                Long.parseLong(settingService.get("cache_max_bytes", "1073741824")));
        data.put("cache_song_limit",
                Integer.parseInt(settingService.get("cache_song_limit", "500")));
        return ApiResponse.ok(data);
    }

    @GetMapping("/pairing-token")
    public ApiResponse<Map<String, String>> pairingToken() {
        String token = settingService.get("pairing_token", "");
        Map<String, String> data = new LinkedHashMap<>();
        data.put("pairing_token", token);
        return ApiResponse.ok(data);
    }
}