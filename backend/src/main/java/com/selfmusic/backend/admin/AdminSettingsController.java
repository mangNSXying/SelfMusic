package com.selfmusic.backend.admin;

import com.selfmusic.backend.common.ApiResponse;
import com.selfmusic.backend.common.BizException;
import com.selfmusic.backend.config.FirstBootInitializer;
import com.selfmusic.backend.domain.service.SettingService;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * 管理端设置（settings.md §3.3 / §5）：
 * <ul>
 *   <li>GET /api/v1/admin/pairing-token —— 当前配对密钥明文（权威源 env 的 settings 镜像）。</li>
 *   <li>GET /api/v1/admin/config —— 服务端缓存建议值（客户端 follow_server 模式采纳来源）。</li>
 *   <li>PUT /api/v1/admin/settings —— 管理端改缓存建议值（阶段6）。
 *       仅允许 {@code cache_max_bytes}/{@code cache_song_limit}；
 *       {@code pairing_token} 为 env 只读镜像，拒绝写入。
 *       注意：env 在每次启动覆盖 DB，PUT 的值在下次带 env 重启后会被覆盖。</li>
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

    @PutMapping("/settings")
    public ApiResponse<Map<String, Object>> updateSettings(@RequestBody Map<String, Object> body) {
        if (body == null || body.isEmpty()) {
            throw new BizException(40001, "请求体为空");
        }
        for (String key : body.keySet()) {
            if (!"cache_max_bytes".equals(key) && !"cache_song_limit".equals(key)) {
                throw new BizException(40001, "不支持的设置项: " + key
                        + "（仅允许 cache_max_bytes / cache_song_limit；pairing_token 为 env 只读）");
            }
        }
        if (body.containsKey("cache_max_bytes")) {
            long bytes = parseMaxBytesBody(body.get("cache_max_bytes"));
            settingService.set("cache_max_bytes", Long.toString(bytes));
        }
        if (body.containsKey("cache_song_limit")) {
            int limit = parseSongLimitBody(body.get("cache_song_limit"));
            settingService.set("cache_song_limit", Integer.toString(limit));
        }
        Map<String, Object> data = new LinkedHashMap<>();
        data.put("cache_max_bytes", readMaxBytes());
        data.put("cache_song_limit", readSongLimit());
        return ApiResponse.ok(data);
    }

    private long parseMaxBytesBody(Object v) {
        if (v instanceof Number n) {
            long bytes = n.longValue();
            if (bytes >= 1) return bytes;
            throw new BizException(40001, "cache_max_bytes 须为 ≥1 的字节数");
        }
        String raw = v == null ? "" : v.toString().trim();
        // 兼容两种口径：纯字节数；或带 MiB 语义的历史值同样按字节接受（≥1 即可）
        try {
            long bytes = Long.parseLong(raw);
            if (bytes >= 1) return bytes;
        } catch (NumberFormatException ignored) {
        }
        throw new BizException(40001, "cache_max_bytes 须为 ≥1 的字节数");
    }

    private int parseSongLimitBody(Object v) {
        Integer parsed = null;
        if (v instanceof Number n) {
            parsed = n.intValue();
        } else {
            String raw = v == null ? "" : v.toString().trim();
            parsed = FirstBootInitializer.parseSongLimit(raw);
            if (parsed == null) {
                throw new BizException(40001, "cache_song_limit 须为 ≥0 的整数");
            }
            return parsed;
        }
        if (parsed != null && parsed >= 0) return parsed;
        throw new BizException(40001, "cache_song_limit 须为 ≥0 的整数");
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