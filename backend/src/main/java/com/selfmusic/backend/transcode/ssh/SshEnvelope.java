package com.selfmusic.backend.transcode.ssh;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.selfmusic.backend.common.BizException;
import net.schmizz.sshj.common.Buffer;
import net.schmizz.sshj.common.KeyType;

import java.security.MessageDigest;
import java.security.PublicKey;
import java.util.Base64;

/**
 * SFTP 回源鉴权信封（{@code X-Origin-Ssh}，base64url(JSON)）：
 * {@code {"u":用户名, "p":密码?, "k":PEM私钥文本?, "pp":passphrase?, "hk":"SHA256:主机指纹"}}。
 *
 * <ul>
 *   <li>{@code p}/{@code k} 二选一必填；{@code hk} 必填（客户端 TOFU 钉，
 *       与弹窗展示同口径的 OpenSSH {@code SHA256:} 形态）；</li>
 *   <li>内存态单次使用：不记日志（日志仅记认证方式），不落盘；</li>
 *   <li>解析失败一律 {@code 40001}（请求非法），连接/鉴权/指纹问题由取流器
 *       报 {@code 502}（源侧失败，客户端回落直连）。</li>
 * </ul>
 */
public final class SshEnvelope {

    /** 解析后的单次凭据（调用方用完即弃）。 */
    public record Credentials(String username, String password, String keyPem,
                              String passphrase, String hostFingerprint) {
        public boolean useKey() {
            return keyPem != null;
        }
    }

    private static final ObjectMapper MAPPER = new ObjectMapper();

    private SshEnvelope() {
    }

    public static Credentials parse(String b64) {
        if (b64 == null || b64.isBlank()) {
            throw new BizException(40001, "SFTP 源需 X-Origin-Ssh 凭据");
        }
        JsonNode n;
        try {
            String padded = b64.trim();
            int rem = padded.length() % 4;
            if (rem != 0) padded += "=".repeat(4 - rem);
            n = MAPPER.readTree(Base64.getUrlDecoder().decode(padded));
        } catch (Exception e) {
            throw new BizException(40001, "X-Origin-Ssh 非法");
        }
        String u = text(n, "u");
        String p = text(n, "p");
        String k = text(n, "k");
        String pp = text(n, "pp");
        String hk = text(n, "hk");
        if (u == null || u.isBlank()) {
            throw new BizException(40001, "X-Origin-Ssh 缺少用户名");
        }
        boolean hasPass = p != null && !p.isEmpty();
        boolean hasKey = k != null && !k.isEmpty();
        if (hasPass == hasKey) {
            throw new BizException(40001, "X-Origin-Ssh 需密码与私钥二选一");
        }
        if (hk == null || !hk.startsWith("SHA256:")) {
            throw new BizException(40001, "X-Origin-Ssh 缺少主机指纹");
        }
        return new Credentials(u, hasPass ? p : null, hasKey ? k : null, pp, hk);
    }

    private static String text(JsonNode n, String field) {
        JsonNode v = n.get(field);
        if (v == null || v.isNull() || !v.isTextual()) return null;
        return v.asText();
    }

    /**
     * 主机公钥 → OpenSSH {@code SHA256:} 指纹（与客户端 TOFU 展示同口径：
     * {@code SHA256(base64nopad(SHA-256(wireBytes)))}）。
     */
    public static String fingerprintOf(PublicKey key) {
        return "SHA256:" + Base64.getEncoder().withoutPadding()
                .encodeToString(sha256(wireOf(key)));
    }

    /** 指纹比对（ constant-time；类型不支持/形态非法一律 false）。 */
    public static boolean fingerprintMatches(String expected, PublicKey observed) {
        if (expected == null || !expected.startsWith("SHA256:")) return false;
        byte[] want;
        try {
            want = Base64.getDecoder().decode(expected.substring(7));
        } catch (IllegalArgumentException e) {
            return false;
        }
        byte[] got;
        try {
            got = sha256(wireOf(observed));
        } catch (IllegalArgumentException e) {
            return false;
        }
        return MessageDigest.isEqual(want, got);
    }

    /** JCE 公钥 → SSH wire 编码（string type + 内容），供指纹哈希。 */
    static byte[] wireOf(PublicKey key) {
        KeyType type = KeyType.fromKey(key);
        if (type == KeyType.UNKNOWN) {
            throw new IllegalArgumentException("unsupported host key type: " + key.getAlgorithm());
        }
        Buffer<?> buf = new Buffer.PlainBuffer();
        type.putPubKeyIntoBuffer(key, buf);
        return buf.getCompactData();
    }

    private static byte[] sha256(byte[] in) {
        try {
            return MessageDigest.getInstance("SHA-256").digest(in);
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }
}
