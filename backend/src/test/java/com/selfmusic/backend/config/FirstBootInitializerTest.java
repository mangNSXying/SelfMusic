package com.selfmusic.backend.config;

import com.selfmusic.backend.domain.entity.Setting;
import com.selfmusic.backend.domain.repository.SettingRepository;
import org.junit.jupiter.api.Test;
import org.springframework.boot.ApplicationArguments;

import java.util.HashMap;
import java.util.Map;
import java.util.Optional;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

/**
 * FirstBootInitializer：pairing_token / 缓存建议值（env → settings 镜像）单测。
 * 通过覆写 {@code env(String)} 注入环境变量，不触碰真实 System.env。
 */
class FirstBootInitializerTest {

    private final Map<String, String> env = new HashMap<>();
    private final SettingRepository repo = mock(SettingRepository.class);

    private FirstBootInitializer instance() {
        return new FirstBootInitializer(repo) {
            @Override
            String env(String key) {
                return env.get(key);
            }
        };
    }

    private static Optional<Setting> row(String key, String value) {
        Setting s = new Setting();
        s.setKey(key);
        s.setValue(value);
        return Optional.of(s);
    }

    /** 捕获保存,断言 save 调用的 key/value。 */
    private void assertSaved(String key, String value) {
        verify(repo, atLeastOnce()).save(argThat(s -> key.equals(s.getKey()) && value.equals(s.getValue())));
    }

    private void assertNotSaved(String key) {
        verify(repo, never()).save(argThat(s -> key.equals(s.getKey())));
    }

    @Test
    void defaultBytesSeededWhenBothEnvAndDbMissing() {
        when(repo.findById(any())).thenReturn(Optional.empty());
        instance().run(mock(ApplicationArguments.class));
        assertSaved("cache_max_bytes", "5368709120");
        assertSaved("cache_song_limit", "200");
    }

    @Test
    void validEnvOverwritesEveryBoot() {
        env.put("CACHE_MAX_MIB", "1024");
        env.put("CACHE_SONG_LIMIT", "50");
        when(repo.findById("cache_max_bytes")).thenReturn(row("cache_max_bytes", "111"));
        when(repo.findById("cache_song_limit")).thenReturn(row("cache_song_limit", "9"));
        when(repo.findById("pairing_token")).thenReturn(Optional.empty());
        // 未设 PAIRING_TOKEN 且库中也无 → 会随机生成 pairing_token，属预期
        instance().run(mock(ApplicationArguments.class));
        assertSaved("cache_max_bytes", "1073741824");
        assertSaved("cache_song_limit", "50");
    }

    @Test
    void absentEnvKeepsExistingDbValue() {
        when(repo.findById("cache_max_bytes")).thenReturn(row("cache_max_bytes", "5368709120"));
        when(repo.findById("cache_song_limit")).thenReturn(row("cache_song_limit", "200"));
        when(repo.findById("pairing_token")).thenReturn(row("pairing_token", "t"));
        instance().run(mock(ApplicationArguments.class));
        assertNotSaved("cache_max_bytes");
        assertNotSaved("cache_song_limit");
    }

    @Test
    void invalidEnvOnlyFallbackToDefaultWhenRowMissing() {
        env.put("CACHE_MAX_MIB", "abc");
        env.put("CACHE_SONG_LIMIT", "-3");
        // 表中有旧值：非法 env 不覆盖
        when(repo.findById("cache_max_bytes")).thenReturn(row("cache_max_bytes", "123"));
        when(repo.findById("cache_song_limit")).thenReturn(row("cache_song_limit", "7"));
        when(repo.findById("pairing_token")).thenReturn(row("pairing_token", "t"));
        instance().run(mock(ApplicationArguments.class));
        assertNotSaved("cache_max_bytes");
        assertNotSaved("cache_song_limit");

        // 表中无值：非法 env 落代码默认值
        reset(repo);
        when(repo.findById(any())).thenReturn(Optional.empty());
        instance().run(mock(ApplicationArguments.class));
        assertSaved("cache_max_bytes", "5368709120");
        assertSaved("cache_song_limit", "200");
    }

    // ---- 纯函数解析 ----

    @Test
    void parseMaxBytesConvertsMibToBytes() {
        assertEquals(Long.valueOf(5368709120L), FirstBootInitializer.parseMaxBytes("5120"));
        assertEquals(Long.valueOf(1024L * 1024L), FirstBootInitializer.parseMaxBytes("1"));
    }

    @Test
    void parseMaxBytesRejectsInvalid() {
        assertNull(FirstBootInitializer.parseMaxBytes("abc"));
        assertNull(FirstBootInitializer.parseMaxBytes("0"));
        assertNull(FirstBootInitializer.parseMaxBytes("-5"));
        assertNull(FirstBootInitializer.parseMaxBytes("1.5"));
        assertNull(FirstBootInitializer.parseMaxBytes(""));
    }

    @Test
    void parseSongLimitParsesAndRejects() {
        assertEquals(Integer.valueOf(200), FirstBootInitializer.parseSongLimit("200"));
        assertEquals(Integer.valueOf(0), FirstBootInitializer.parseSongLimit("0"));
        assertNull(FirstBootInitializer.parseSongLimit("-1"));
        assertNull(FirstBootInitializer.parseSongLimit("x"));
    }
}