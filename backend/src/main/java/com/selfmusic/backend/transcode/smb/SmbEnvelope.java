package com.selfmusic.backend.transcode.smb;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.selfmusic.backend.common.BizException;

import java.util.Base64;

/**
 * SMB 回源鉴权信封（{@code X-Origin-Smb}，base64url(JSON)）：
 * {@code {"u":用户名?, "p":密码?}}（双空即匿名）。
 *
 * <ul>
 *   <li>SMB 无主机密钥 TOFU（NTLM/Kerberos 协商自带完整性），故无指纹字段；
 *       与 {@code X-Origin-Ssh} 对应但更宽松：{@code u}/{@code p} 全可选；</li>
 *   <li>内存态单次使用：不记日志（日志仅记是否匿名），不落盘；</li>
 *   <li>解析失败一律 {@code 40001}（请求非法），连接/鉴权问题由取流器
 *       报 {@code 502}（源侧失败，客户端回落直连）。</li>
 * </ul>
 */
public final class SmbEnvelope {

    /** 解析后的单次凭据（调用方用完即弃）。 */
    public record Credentials(String username, String password) {
        public boolean anonymous() {
            return (username == null || username.isEmpty())
                    && (password == null || password.isEmpty());
        }
    }

    private static final ObjectMapper MAPPER = new ObjectMapper();

    private SmbEnvelope() {
    }

    public static Credentials parse(String b64) {
        if (b64 == null || b64.isBlank()) {
            throw new BizException(40001, "SMB 源需 X-Origin-Smb 凭据");
        }
        JsonNode n;
        try {
            String padded = b64.trim();
            int rem = padded.length() % 4;
            if (rem != 0) padded += "=".repeat(4 - rem);
            n = MAPPER.readTree(Base64.getUrlDecoder().decode(padded));
        } catch (Exception e) {
            throw new BizException(40001, "X-Origin-Smb 非法");
        }
        if (!n.isObject()) {
            throw new BizException(40001, "X-Origin-Smb 非法");
        }
        return new Credentials(text(n, "u"), text(n, "p"));
    }

    private static String text(JsonNode n, String field) {
        JsonNode v = n.get(field);
        if (v == null || v.isNull() || !v.isTextual()) return null;
        return v.asText();
    }
}
