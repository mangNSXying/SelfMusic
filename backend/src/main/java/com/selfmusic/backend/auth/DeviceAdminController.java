package com.selfmusic.backend.auth;

import com.selfmusic.backend.common.ApiResponse;
import com.selfmusic.backend.common.BizException;
import com.selfmusic.backend.domain.entity.Device;
import com.selfmusic.backend.domain.entity.Setting;
import com.selfmusic.backend.domain.repository.DeviceRepository;
import com.selfmusic.backend.domain.repository.SettingRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.web.bind.annotation.*;

import java.util.List;
import java.util.Map;
import java.util.UUID;

@RestController
@RequestMapping("/api/v1/admin/devices")
@RequiredArgsConstructor
public class DeviceAdminController {

    private final DeviceRepository deviceRepository;
    private final SettingRepository settingRepository;

    @GetMapping
    public ApiResponse<List<Device>> list() {
        return ApiResponse.ok(deviceRepository.findAll());
    }

    @PutMapping("/{id}")
    public ApiResponse<Void> rename(@PathVariable Long id, @RequestBody Map<String, String> body) {
        Device d = deviceRepository.findById(id)
                .orElseThrow(() -> new BizException(40401, "device not found"));
        d.setName(body.getOrDefault("name", d.getName()));
        deviceRepository.save(d);
        return ApiResponse.ok();
    }

    @DeleteMapping("/{id}")
    public ApiResponse<Void> revoke(@PathVariable Long id) {
        Device d = deviceRepository.findById(id)
                .orElseThrow(() -> new BizException(40401, "device not found"));
        d.setRevoked(true);
        deviceRepository.save(d);
        return ApiResponse.ok();
    }

    // 管理端重置主配对令牌
    @PostMapping("/pairing-token/reset")
    public ApiResponse<Map<String, String>> resetPairingToken() {
        String newToken = UUID.randomUUID().toString();
        Setting setting = new Setting();
        setting.setKey("pairing_token");
        setting.setValue(newToken);
        settingRepository.save(setting);
        return ApiResponse.ok(Map.of("pairing_token", newToken));
    }
}
