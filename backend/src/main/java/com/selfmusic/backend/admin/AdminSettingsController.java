package com.selfmusic.backend.admin;

import com.selfmusic.backend.common.ApiResponse;
import com.selfmusic.backend.config.FirstBootInitializer;
import com.selfmusic.backend.domain.service.SettingService;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * 管理端设置（settings.md §3.3 / §5）：
 * <ul>
 *   <li>GET /api/v1/admin/pairing-token —— 当前配对密钥明文（权威源 env 的 settings 镜像）。</li>
 *   <li>GET /api/v1/admin/config —— 服务端缓存建议值（客户端 follow_server 模式采纳来源）。</li>
 * </ul>
 */
@RestController
@RequestMapping("/api/v1/admin")
public class AdminSettingsController {

    private final SettingService settingService;

    public AdminSettingsController(SettingService settingService) {
        this.settingService = settingService;
    }

    @GetMapping("/pairing-token")
    public ApiResponse<Map<String, String>> pairingToken() {
        String token = settingService.get("pairing_token", "");
        Map<String, String> data = new LinkedHashMap<>();
        data.put("pairing_token", token);
        return ApiResponse.ok(data);
    }

    @GetMapping("/config")
    public ApiResponse<Map<String, Object>> config() {
        Map<String, Object> data = new LinkedHashMap<>();
        data.put("cache_max_bytes", readMaxBytes());
        data.put("cache_song_limit", readSongLimit());
        return ApiResponse.ok(data);
    }

    private long readMaxBytes() {
        String raw = settingService.get("cache_max_bytes", null);
        if (raw == null) {
            return defaultMaxBytes();
        }
        long bytes;
        try {
            bytes = Long.parseLong(raw.trim());
        } catch (NumberFormatException e) {
            return defaultMaxBytes();
        }
        return bytes >= 1 ? bytes : defaultMaxBytes();
    }

    private int readSongLimit() {
        String raw = settingService.get("cache_song_limit", null);
        if (raw == null) {
            return FirstBootInitializer.DEFAULT_CACHE_SONG_LIMIT;
        }
        Integer v = FirstBootInitializer.parseSongLimit(raw);
        return v != null ? v : FirstBootInitializer.DEFAULT_CACHE_SONG_LIMIT;
    }

    private static long defaultMaxBytes() {
        return FirstBootInitializer.DEFAULT_CACHE_MAX_MIB * FirstBootInitializer.BYTES_PER_MIB;
    }
}