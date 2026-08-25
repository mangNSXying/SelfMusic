package com.selfmusic.backend.auth;

import java.util.Map;
import java.util.UUID;

import com.selfmusic.backend.common.ApiResponse;
import com.selfmusic.backend.common.BizException;
import com.selfmusic.backend.domain.entity.Device;
import com.selfmusic.backend.domain.repository.DeviceRepository;
import com.selfmusic.backend.domain.repository.SettingRepository;
import jakarta.servlet.http.HttpServletRequest;
import lombok.RequiredArgsConstructor;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/v1/auth")
@RequiredArgsConstructor
public class AuthController {

    private final DeviceRepository deviceRepository;
    private final SettingRepository settingRepository;

    @PostMapping("/pair")
    public ApiResponse<Map<String, String>> pair(@RequestBody PairRequest req,
                                                  HttpServletRequest request) {
        // 校验主配对令牌（明文比较，仅用于一次性配对）
        String stored = settingRepository.findById("pairing_token")
                .map(s -> s.getValue())
                .orElseThrow(() -> new BizException(50001, "server not initialized"));
        if (!constantTimeEquals(stored, req.pairing_token())) {
            throw new BizException(40100, "invalid pairing token");
        }

        String client = UUID.randomUUID().toString();
        String deviceToken = UUID.randomUUID().toString();
        String tokenHash = TokenFilter.sha256(deviceToken);

        Device device = new Device();
        device.setClientId(client);
        device.setName(req.device_name());
        device.setPlatform(req.platform());
        device.setTokenHash(tokenHash);
        device.setRevoked(false);
        device.setPairedAt(java.time.LocalDateTime.now());
        deviceRepository.save(device);

        return ApiResponse.ok(Map.of(
                "client_id", client,
                "device_token", deviceToken
        ));
    }

    @PostMapping("/unpair")
    public ApiResponse<Void> unpair() {
        Authentication auth = SecurityContextHolder.getContext().getAuthentication();
        if (auth == null || auth.getPrincipal() == null)
            throw new BizException(40101, "unauthenticated");
        String clientId = auth.getPrincipal().toString();
        deviceRepository.findByClientId(clientId).ifPresent(d -> {
            d.setRevoked(true);
            deviceRepository.save(d);
        });
        return ApiResponse.ok();
    }

    private static boolean constantTimeEquals(String a, String b) {
        if (a == null || b == null) return false;
        if (a.length() != b.length()) return false;
        int diff = 0;
        for (int i = 0; i < a.length(); i++) diff |= a.charAt(i) ^ b.charAt(i);
        return diff == 0;
    }

    public record PairRequest(String pairing_token, String device_name, String platform) {}
}
