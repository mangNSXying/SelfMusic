package com.selfmusic.backend.config;

import java.util.UUID;

import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;
import org.springframework.stereotype.Component;

import com.selfmusic.backend.domain.entity.Setting;
import com.selfmusic.backend.domain.repository.SettingRepository;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;

/**
 * 首次启动初始化：若无 pairing_token 则自动生成。
 */
@Slf4j
@Component
@RequiredArgsConstructor
public class FirstBootInitializer implements ApplicationRunner {

    private final SettingRepository settingRepository;

    @Override
    public void run(ApplicationArguments args) {
        if (!settingRepository.existsById("pairing_token")) {
            String token = UUID.randomUUID().toString();
            Setting setting = new Setting();
            setting.setKey("pairing_token");
            setting.setValue(token);
            settingRepository.save(setting);
            log.info("=".repeat(60));
            log.info("SelfMusic initialized — pairing token (save it!): {}", token);
            log.info("=".repeat(60));
        }
    }
}
