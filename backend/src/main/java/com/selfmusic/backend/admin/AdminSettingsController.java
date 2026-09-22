package com.selfmusic.backend.admin;

import com.selfmusic.backend.common.ApiResponse;
import com.selfmusic.backend.domain.service.SettingService;
import lombok.RequiredArgsConstructor;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * 管理端设置（settings.md §3.5）：
 * <ul>
 *   <li>GET /api/v1/admin/pairing-token —— 当前配对密钥明文（权威源 env 的 settings 镜像）。</li>
 * </ul>
 */
@RestController
@RequestMapping("/api/v1/admin")
@RequiredArgsConstructor
public class AdminSettingsController {

    private final SettingService settingService;

    @GetMapping("/pairing-token")
    public ApiResponse<Map<String, String>> pairingToken() {
        String token = settingService.get("pairing_token", "");
        Map<String, String> data = new LinkedHashMap<>();
        data.put("pairing_token", token);
        return ApiResponse.ok(data);
    }
}