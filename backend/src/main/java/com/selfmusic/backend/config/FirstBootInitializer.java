package com.selfmusic.backend.config;

import com.selfmusic.backend.domain.entity.Setting;
import com.selfmusic.backend.domain.repository.SettingRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;
import org.springframework.stereotype.Component;

import java.util.UUID;

/**
 * 启动初始化：以环境变量作为 settings 表的权威来源（DB 仅为镜像）。
 * - 每次启动都把相关 env 写入 settings（覆盖式，改 .env 重启即生效）；
 * - 配对密钥 PAIRING_TOKEN：未提供时沿用库中已有值；若库中也无（首次初始化）则随机生成；
 *   仅当本轮真正完成首次初始化（新建库中记录）时，以 WARN 醒目打印一次密钥；
 * - 缓存建议值 CACHE_MAX_MIB（单位 MiB）与 CACHE_SONG_LIMIT（首数）：覆盖式镜像到
 *   cache_max_bytes（字节）/ cache_song_limit；未提供或非法时沿用库中旧值，
 *   库中也无则落代码默认值（5 GiB / 200，与 init.sql 预置一致）。
 */
@Component
public class FirstBootInitializer implements ApplicationRunner {

    private static final Logger log = LoggerFactory.getLogger(FirstBootInitializer.class);

    /** 每字节数常量：MiB → byte。 */
    public static final long BYTES_PER_MIB = 1024L * 1024L;

    /** 服务端默认缓存建议值（与 init.sql 预置一致）：5 GiB / 200 首。 */
    public static final long DEFAULT_CACHE_MAX_MIB = 5120L;
    public static final int DEFAULT_CACHE_SONG_LIMIT = 200;

    private final SettingRepository settingRepository;

    public FirstBootInitializer(SettingRepository settingRepository) {
        this.settingRepository = settingRepository;
    }

    @Override
    public void run(ApplicationArguments args) {
        seedPairingToken();
        seedCacheDefaults();
    }

    private void seedPairingToken() {
        String env = envOrNull(env("PAIRING_TOKEN"));
        Setting existing = settingRepository.findById("pairing_token").orElse(null);

        if (env != null) {
            // 每次启动以 env 覆盖：改 .env 重启即生效
            upsert("pairing_token", env);
            if (existing == null) {
                logWarnSeed(env);
            }
        } else if (existing == null) {
            // 无 env 且库中无记录：首次初始化，随机生成并 warn 一次
            String token = UUID.randomUUID().toString();
            upsert("pairing_token", token);
            logWarnSeed(token);
        }
        // 无 env 且库中已有记录：沿用旧值，静默
    }

    private void seedCacheDefaults() {
        seedCacheMaxBytes();
        seedCacheSongLimit();
    }

    private void seedCacheMaxBytes() {
        String key = "cache_max_bytes";
        String env = envOrNull(env("CACHE_MAX_MIB"));
        Long bytes = env == null ? null : parseMaxBytes(env);
        if (env != null && bytes == null) {
            // env 存在但非法：保留库中旧值；库中无则落默认值
            log.warn("env CACHE_MAX_MIB='{}' 解析失败（须为正整数 MiB），沿用 settings.cache_max_bytes 现值；"
                    + "表内无记录则以默认 5 GiB 兜底写入。", env);
        }
        if (bytes != null) {
            upsert(key, Long.toString(bytes));
        } else if (settingRepository.findById(key).isEmpty()) {
            upsert(key, Long.toString(DEFAULT_CACHE_MAX_MIB * BYTES_PER_MIB));
            log.warn("settings.cache_max_bytes 无记录，写入默认值 {} 字节（5 GiB）。",
                    DEFAULT_CACHE_MAX_MIB * BYTES_PER_MIB);
        }
    }

    private void seedCacheSongLimit() {
        String key = "cache_song_limit";
        String env = envOrNull(env("CACHE_SONG_LIMIT"));
        Integer limit = env == null ? null : parseSongLimit(env);
        if (env != null && limit == null) {
            log.warn("env CACHE_SONG_LIMIT='{}' 解析失败（须为不小于 0 的整数），沿用 settings.cache_song_limit 现值；"
                    + "表内无记录则以默认 200 兜底写入。", env);
        }
        if (limit != null) {
            upsert(key, Integer.toString(limit));
        } else if (settingRepository.findById(key).isEmpty()) {
            upsert(key, Integer.toString(DEFAULT_CACHE_SONG_LIMIT));
            log.warn("settings.cache_song_limit 无记录，写入默认值 {} 首。", DEFAULT_CACHE_SONG_LIMIT);
        }
    }

    /** 把 MiB 解析为字节数；非法（非整数/小于 1/越界）返回 null。 */
    public static Long parseMaxBytes(String mib) {
        long value;
        try {
            value = Long.parseLong(mib.trim());
        } catch (NumberFormatException e) {
            return null;
        }
        if (value < 1 || value > Long.MAX_VALUE / BYTES_PER_MIB) {
            return null;
        }
        return value * BYTES_PER_MIB;
    }

    /** 解析歌数；非法（非整数/负数）返回 null。 */
    public static Integer parseSongLimit(String v) {
        int value;
        try {
            value = Integer.parseInt(v.trim());
        } catch (NumberFormatException e) {
            return null;
        }
        return value >= 0 ? value : null;
    }

    private String envOrNull(String v) {
        if (v == null) return null;
        String t = v.trim();
        return t.isEmpty() ? null : t;
    }

    /** 环境变量读取口（测试可覆写注入）。 */
    String env(String key) {
        return System.getenv(key);
    }

    private void upsert(String key, String value) {
        Setting setting = settingRepository.findById(key).orElseGet(Setting::new);
        if (setting.getKey() == null) setting.setKey(key);
        setting.setValue(value);
        settingRepository.save(setting);
    }

    private void logWarnSeed(String token) {
        log.warn("=".repeat(60));
        log.warn("SelfMusic 初始化完成——配对密钥（请妥善保存，用于客户端配对）: {}", token);
        log.warn("密钥也可在已配对设备的 设置→常规 中查看；修改 .env 的 PAIRING_TOKEN 并重启后对新设备生效。");
        log.warn("=".repeat(60));
    }
}
