package com.selfmusic.backend.sync;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.selfmusic.backend.domain.entity.ClientSetting;
import org.junit.jupiter.api.Test;

import java.time.LocalDateTime;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

class SyncableSettingsTest {

    private final ObjectMapper mapper = new ObjectMapper();

    @Test
    void whitelistOnlyPlaybackAndLibraryRules() {
        assertTrue(SyncableSettings.isSyncable("fade_enabled"));
        assertTrue(SyncableSettings.isSyncable("fade_duration_ms"));
        assertTrue(SyncableSettings.isSyncable("scan_ignore_min_duration_sec"));
        assertTrue(SyncableSettings.isSyncable("fallback_auto_repair"));
        assertTrue(SyncableSettings.isSyncable("song_title_format"));
        assertTrue(SyncableSettings.isSyncable("lyrics_show_cover"));
        assertTrue(SyncableSettings.isSyncable("theme_mode"));
        assertTrue(SyncableSettings.isSyncable("theme_accent"));

        assertFalse(SyncableSettings.isSyncable("app_volume"));
        assertFalse(SyncableSettings.isSyncable("lyric_max_lines"));
        assertFalse(SyncableSettings.isSyncable("shortcut_window_bindings"));
        assertFalse(SyncableSettings.isSyncable("allow_insecure_http"));
        assertFalse(SyncableSettings.isSyncable(null));

        assertEquals(java.util.Set.of(
                "play_mode_default",
                "resume_on_startup",
                "preload_next",
                "sleep_play_through_default",
                "sleep_default_duration_minutes",
                "sleep_default_count",
                "lyric_focus_idle_sec",
                "weighted_random_enabled",
                "weighted_draw_cooldown",
                "weighted_count_cooldown_ratio",
                "curve_weight_enabled",
                "curve_weight_segments",
                "fade_enabled",
                "fade_duration_ms",
                "scan_ignore_min_duration_sec",
                "scan_ignore_min_size_bytes",
                "online_meta_lyric_source",
                "online_meta_cover_source",
                "online_meta_save_mode",
                "artist_resolve_auto",
                "fallback_auto_repair",
                "song_title_format",
                "zh_variant",
                "player_transition",
                "player_show_weight",
                "lyrics_show_cover",
                "player_auto_hide_idle_sec",
                "long_press_collapse_groups",
                "theme_mode",
                "theme_accent",
                "theme_background"
        ), SyncableSettings.KEYS);
    }

    @Test
    void entityKeyUsesSettingPrefix() {
        ObjectNode p = mapper.createObjectNode().put("key", "fade_enabled");
        assertEquals("setting|fade_enabled",
                SyncService.entityKeyOf(SyncEventTypes.SETTING_SET, p));
        assertNull(SyncService.entityKeyOf(SyncEventTypes.SETTING_SET,
                mapper.createObjectNode()));
        assertNull(SyncService.entityKeyOf(SyncEventTypes.SETTING_SET, null));
    }

    @Test
    void snapshotCarriesKeyValueAndDevice() {
        ClientSetting s = new ClientSetting();
        s.setSettingKey("fade_enabled");
        s.setSettingValue("0");
        s.setUpdatedAt(LocalDateTime.of(2026, 1, 1, 0, 0));
        s.setDeviceClientId("dev-a");

        Map<String, Object> m = SyncService.settingSnapshot(s);
        assertEquals("fade_enabled", m.get("setting_key"));
        assertEquals("0", m.get("setting_value"));
        assertEquals("2026-01-01T00:00", m.get("updated_at"));
        assertEquals("dev-a", m.get("device_client_id"));
    }
}
