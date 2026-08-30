package com.selfmusic.backend.config;

import com.selfmusic.backend.domain.entity.Setting;
import com.selfmusic.backend.domain.repository.SettingRepository;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;
import org.springframework.stereotype.Component;

import java.util.UUID;

/**
 * 启动初始化：以环境变量 PAIRING_TOKEN 作为配对密钥的权威来源（DB 仅为镜像）。
 * - 每次启动都把 PAIRING_TOKEN 写入 settings（覆盖式，改 .env 重启即生效）；
 * - 未提供 PAIRING_TOKEN 时沿用库中已有值；若库中也无（首次初始化）则随机生成；
 * - 仅当本轮真正完成首次初始化（新建库中记录）时，以 WARN 醒目打印一次密钥。
 */
@Slf4j
@Component
@RequiredArgsConstructor
public class FirstBootInitializer implements ApplicationRunner {

    private final SettingRepository settingRepository;

    @Override
    public void run(ApplicationArguments args) {
        String env = envOrNull(System.getenv("PAIRING_TOKEN"));
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

    private String envOrNull(String v) {
        if (v == null) return null;
        String t = v.trim();
        return t.isEmpty() ? null : t;
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
