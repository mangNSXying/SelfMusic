package com.selfmusic.backend.auth;

import java.time.Duration;
import java.time.LocalDateTime;
import java.util.Map;
import java.util.UUID;

import com.selfmusic.backend.common.ApiResponse;
import com.selfmusic.backend.common.BizException;
import com.selfmusic.backend.domain.entity.Device;
import com.selfmusic.backend.domain.repository.DeviceRepository;
import com.selfmusic.backend.domain.repository.SettingRepository;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/v1/auth")
public class AuthController {

    private static final Duration ACCESS_TTL = Duration.ofHours(24);
    private static final Duration REFRESH_TTL = Duration.ofDays(30);

    private final DeviceRepository deviceRepository;
    private final SettingRepository settingRepository;

    public AuthController(DeviceRepository deviceRepository, SettingRepository settingRepository) {
        this.deviceRepository = deviceRepository;
        this.settingRepository = settingRepository;
    }

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

        LocalDateTime now = LocalDateTime.now();
        String client = UUID.randomUUID().toString();
        String deviceToken = UUID.randomUUID().toString();
        String refreshToken = UUID.randomUUID().toString();
        String tokenHash = TokenFilter.sha256(deviceToken);
        String refreshHash = TokenFilter.sha256(refreshToken);

        Device device = new Device();
        device.setClientId(client);
        device.setName(req.device_name());
        device.setPlatform(req.platform());
        device.setTokenHash(tokenHash);
        device.setRefreshTokenHash(refreshHash);
        device.setTokenExpiresAt(now.plus(ACCESS_TTL));
        device.setRefreshExpiresAt(now.plus(REFRESH_TTL));
        device.setRevoked(false);
        device.setPairedAt(now);
        device.setRenewedAt(now);
        deviceRepository.save(device);

        return ApiResponse.ok(Map.of(
                "client_id", client,
                "device_token", deviceToken,
                "access_token", deviceToken,
                "refresh_token", refreshToken,
                "expires_in", String.valueOf(ACCESS_TTL.toSeconds()),
                "refresh_expires_in", String.valueOf(REFRESH_TTL.toSeconds())
        ));
    }

    // 匿名端点：用 refresh_token 换发新的 access_token + refresh_token（轮换式）
    @PostMapping("/refresh")
    public ApiResponse<Map<String, String>> refresh(@RequestBody RefreshRequest req) {
        String refreshHash = TokenFilter.sha256(req.refresh_token());
        Device device = deviceRepository.findByRefreshTokenHashAndRevokedFalse(refreshHash)
                .orElseThrow(() -> new BizException(40102, "refresh token invalid or revoked"));

        LocalDateTime now = LocalDateTime.now();
        if (device.getRefreshExpiresAt() == null || device.getRefreshExpiresAt().isBefore(now)) {
            throw new BizException(40102, "refresh token expired");
        }

        String newAccess = UUID.randomUUID().toString();
        String newRefresh = UUID.randomUUID().toString();
        device.setTokenHash(TokenFilter.sha256(newAccess));
        device.setRefreshTokenHash(TokenFilter.sha256(newRefresh));
        device.setTokenExpiresAt(now.plus(ACCESS_TTL));
        device.setRefreshExpiresAt(now.plus(REFRESH_TTL));
        device.setRenewedAt(now);
        deviceRepository.save(device);

        return ApiResponse.ok(Map.of(
                "client_id", device.getClientId(),
                "device_token", newAccess,
                "access_token", newAccess,
                "refresh_token", newRefresh,
                "expires_in", String.valueOf(ACCESS_TTL.toSeconds()),
                "refresh_expires_in", String.valueOf(REFRESH_TTL.toSeconds())
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
    public record RefreshRequest(String refresh_token) {}
}
