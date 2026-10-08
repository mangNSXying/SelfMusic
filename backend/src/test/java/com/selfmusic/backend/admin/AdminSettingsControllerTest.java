package com.selfmusic.backend.admin;

import com.selfmusic.backend.common.ApiResponse;
import com.selfmusic.backend.domain.service.SettingService;
import org.junit.jupiter.api.Test;

import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

/**
 * GET /api/v1/admin/config：返回 settings 表中的缓存建议值（字节/首），
 * 缺行或值非法时回退代码默认值（5 GiB / 200）。
 */
class AdminSettingsControllerTest {

    private final SettingService settings = mock(SettingService.class);

    private AdminSettingsController controller() {
        return new AdminSettingsController(settings);
    }

    @SuppressWarnings("unchecked")
    private Map<String, Object> config() {
        return (Map<String, Object>) controller().config().getData();
    }

    @Test
    void returnsMirroredValuesFromSettingsTable() {
        when(settings.get("cache_max_bytes", null)).thenReturn("5368709120");
        when(settings.get("cache_song_limit", null)).thenReturn("200");
        Map<String, Object> data = config();
        assertEquals(5368709120L, data.get("cache_max_bytes"));
        assertEquals(200, data.get("cache_song_limit"));
    }

    @Test
    void fallsBackToDefaultsWhenRowsMissing() {
        when(settings.get("cache_max_bytes", null)).thenReturn(null);
        when(settings.get("cache_song_limit", null)).thenReturn(null);
        Map<String, Object> data = config();
        assertEquals(5368709120L, data.get("cache_max_bytes"));
        assertEquals(200, data.get("cache_song_limit"));
    }

    @Test
    void fallsBackToDefaultsWhenValuesInvalid() {
        when(settings.get("cache_max_bytes", null)).thenReturn("not-a-number");
        when(settings.get("cache_song_limit", null)).thenReturn("-9");
        Map<String, Object> data = config();
        assertEquals(5368709120L, data.get("cache_max_bytes"));
        assertEquals(200, data.get("cache_song_limit"));
    }

    @Test
    void parsesStoredMibDecimalAsBytes() {
        // 表内历史值（MiB 语义已废除）仍按「字节」数值被接受——文档以字节口径，仅校验 ≥1
        when(settings.get("cache_max_bytes", null)).thenReturn("1073741824");
        when(settings.get("cache_song_limit", null)).thenReturn("0");
        Map<String, Object> data = config();
        assertEquals(1073741824L, data.get("cache_max_bytes"));
        assertEquals(0, data.get("cache_song_limit"));
    }
}