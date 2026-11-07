package com.selfmusic.backend.sync;

import java.util.Set;

/**
 * 设置同步白名单（v1：播放偏好 + 媒体库规则；v2：界面偏好 + 主题外观）。
 *
 * <p>与客户端 {@code SyncableSettings} 保持同一键集合。服务端只接受这些键，
 * 缓存/网络/音频设备/快捷键等设备本地项一律拒绝，避免凭据或本机路径上行。</p>
 */
public final class SyncableSettings {
    private SyncableSettings() {}

    public static final Set<String> KEYS = Set.of(
            // 播放偏好
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
            // 媒体库规则
            "scan_ignore_min_duration_sec",
            "scan_ignore_min_size_bytes",
            "online_meta_lyric_source",
            "online_meta_cover_source",
            "online_meta_save_mode",
            "artist_resolve_auto",
            "fallback_auto_repair",
            // 界面偏好（v2）
            "song_title_format",
            "zh_variant",
            "player_transition",
            "player_show_weight",
            "player_auto_hide_idle_sec",
            "long_press_collapse_groups",
            // 主题外观（v2，客户端经 ThemeProvider 桥接）
            "theme_mode",
            "theme_accent",
            "theme_background"
    );

    public static boolean isSyncable(String key) {
        return key != null && KEYS.contains(key);
    }
}
