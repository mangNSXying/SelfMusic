package com.selfmusic.backend.domain.service;

import com.selfmusic.backend.domain.entity.Setting;
import com.selfmusic.backend.domain.repository.SettingRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;

import java.util.Optional;

/** settings 表读写（客户端管理端点 / 配置下发共用）。 */
@Service
@RequiredArgsConstructor
public class SettingService {

    private final SettingRepository settingRepository;

    public Optional<String> get(String key) {
        return settingRepository.findById(key).map(Setting::getValue);
    }

    /** 缺省时返回 [defaultIfMissing]。 */
    public String get(String key, String defaultIfMissing) {
        return settingRepository.findById(key).map(Setting::getValue).orElse(defaultIfMissing);
    }

    public void set(String key, String value) {
        Setting s = settingRepository.findById(key).orElseGet(Setting::new);
        s.setKey(key);
        s.setValue(value);
        settingRepository.save(s);
    }
}