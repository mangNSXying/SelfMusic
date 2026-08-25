package com.selfmusic.backend.auth;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.LocalDateTime;
import java.util.List;

import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import com.selfmusic.backend.domain.repository.DeviceRepository;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import lombok.RequiredArgsConstructor;

@Component
@RequiredArgsConstructor
public class TokenFilter extends OncePerRequestFilter {

    private final DeviceRepository deviceRepository;

    @Override
    protected void doFilterInternal(HttpServletRequest request,
                                    HttpServletResponse response,
                                    FilterChain chain) throws ServletException, IOException {
        String path = request.getRequestURI();
        // 仅配对接口匿名；unpair 等其余 auth 接口需要 Bearer token 识别设备身份
        if (path.startsWith("/api/v1/auth/pair")) {
            chain.doFilter(request, response);
            return;
        }

        String header = request.getHeader("Authorization");
        if (header != null && header.startsWith("Bearer ")) {
            String token = header.substring(7);
            String hash = sha256(token);
            deviceRepository.findByTokenHashAndRevokedFalse(hash).ifPresent(device -> {
                var auth = new UsernamePasswordAuthenticationToken(
                        device.getClientId(), null,
                        List.of(new SimpleGrantedAuthority("ROLE_USER")));
                SecurityContextHolder.getContext().setAuthentication(auth);
                // 节流刷新 last_seen_at（最多 60s 一次）
                if (device.getLastSeenAt() == null
                        || device.getLastSeenAt().isBefore(LocalDateTime.now().minusSeconds(60))) {
                    device.setLastSeenAt(LocalDateTime.now());
                    deviceRepository.save(device);
                }
            });
        }

        chain.doFilter(request, response);
    }

    public static String sha256(String input) {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            byte[] digest = md.digest(input.getBytes(StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder(64);
            for (byte b : digest) sb.append(String.format("%02x", b));
            return sb.toString();
        } catch (NoSuchAlgorithmException e) {
            throw new RuntimeException(e);
        }
    }
}
