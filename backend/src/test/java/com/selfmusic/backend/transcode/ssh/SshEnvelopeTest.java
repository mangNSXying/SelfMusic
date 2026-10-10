package com.selfmusic.backend.transcode.ssh;

import com.selfmusic.backend.common.BizException;
import net.schmizz.sshj.common.Buffer;
import net.schmizz.sshj.common.KeyType;
import org.junit.jupiter.api.Test;

import java.security.PublicKey;
import java.util.Base64;

import static org.junit.jupiter.api.Assertions.*;

/**
 * SFTP 信封解析 + 主机指纹（ssh-keygen 实测向量回归）。
 *
 * <p>向量来自本机 {@code ssh-keygen}（ed25519 / RSA-2048），
 * 期望指纹为 {@code ssh-keygen -E sha256} 输出：
 * <ul>
 *   <li>ed25519 → {@code SHA256:Cd+Oc1D9sGJ4o7E4c5/HJ/NxAJePMH3eP9eW+M8Q/Fo}</li>
 *   <li>rsa → {@code SHA256:ARHEgVstFaPDbqxSojdGb7U/9IYUE6xAwozNoeHQ/Sg}</li>
 * </ul>
 */
class SshEnvelopeTest {

    private static final String ED25519_WIRE_B64 =
            "AAAAC3NzaC1lZDI1NTE5AAAAIFwL5elUdX58bXZgSzXbc8dcXdSU62WmJyYz42tA7GLR";
    private static final String ED25519_FP =
            "SHA256:Cd+Oc1D9sGJ4o7E4c5/HJ/NxAJePMH3eP9eW+M8Q/Fo";

    private static final String RSA_WIRE_B64 =
            "AAAAB3NzaC1yc2EAAAADAQABAAABAQDoE6wutCM/bnW6BjdzfYN5T062iiraErUoVFQyZgwKzlgScmY0WbxpMowBrdAyqIR2wHkX53jHIyN6hCNISEEXXWRgjOVHonRnUT6K9SHgqD7gdQ+Z13ivah+2z7GbRyKUZVl+wgUJEVlme2IImpGL6L72ZoVQprmJkCCINCP9bJG8XJASFWhMVKB3CUWvImLPMGATaV8sqcDQB/riyAKt+jSt5blkxz94oVf89sUVPwbDeiw7C4Puo+eEqlx9CpGKUKqCOdMfns7SpmkarXN9xSuBqzfdKt6qbkP/onPjgilvG0pa2K9FZObGC3v3/uNqAETBhUULsOvVen1o+vKz";
    private static final String RSA_FP =
            "SHA256:ARHEgVstFaPDbqxSojdGb7U/9IYUE6xAwozNoeHQ/Sg";

    /** wire bytes → PublicKey（与生产侧 verifier 的逆过程对称）。 */
    private static PublicKey decodeKey(String wireB64) throws Exception {
        byte[] wire = Base64.getDecoder().decode(wireB64);
        Buffer<?> buf = new Buffer.PlainBuffer(wire);
        String type = buf.readString();
        return KeyType.fromString(type).readPubKeyFromBuffer(buf);
    }

    @Test
    void fingerprintMatchesSshKeygen() throws Exception {
        assertEquals(ED25519_FP, SshEnvelope.fingerprintOf(decodeKey(ED25519_WIRE_B64)));
        assertEquals(RSA_FP, SshEnvelope.fingerprintOf(decodeKey(RSA_WIRE_B64)));
    }

    @Test
    void fingerprintCompare() throws Exception {
        PublicKey ed = decodeKey(ED25519_WIRE_B64);
        assertTrue(SshEnvelope.fingerprintMatches(ED25519_FP, ed));
        assertFalse(SshEnvelope.fingerprintMatches(RSA_FP, ed));
        assertFalse(SshEnvelope.fingerprintMatches("bogus", ed));
        assertFalse(SshEnvelope.fingerprintMatches(null, ed));
    }

    private static String envelope(String json) {
        return Base64.getUrlEncoder().withoutPadding()
                .encodeToString(json.getBytes(java.nio.charset.StandardCharsets.UTF_8));
    }

    @Test
    void parsePasswordEnvelope() {
        var c = SshEnvelope.parse(envelope(
                "{\"u\":\"bob\",\"p\":\"s3cret\",\"hk\":\"SHA256:abc\"}"));
        assertEquals("bob", c.username());
        assertEquals("s3cret", c.password());
        assertFalse(c.useKey());
        assertEquals("SHA256:abc", c.hostFingerprint());
    }

    @Test
    void parseKeyEnvelope() {
        var c = SshEnvelope.parse(envelope(
                "{\"u\":\"bob\",\"k\":\"PEM\",\"pp\":\"pw\",\"hk\":\"SHA256:abc\"}"));
        assertTrue(c.useKey());
        assertEquals("PEM", c.keyPem());
        assertEquals("pw", c.passphrase());
    }

    @Test
    void parseRejectsBadEnvelopes() {
        assertThrows(BizException.class, () -> SshEnvelope.parse(null));
        assertThrows(BizException.class, () -> SshEnvelope.parse("!!!not-base64!!!"));
        assertThrows(BizException.class,
                () -> SshEnvelope.parse(envelope("{\"u\":\"bob\"}")));
        assertThrows(BizException.class, () -> SshEnvelope.parse(envelope(
                "{\"u\":\"bob\",\"p\":\"x\",\"k\":\"y\",\"hk\":\"SHA256:abc\"}")));
        assertThrows(BizException.class, () -> SshEnvelope.parse(envelope(
                "{\"u\":\"bob\",\"p\":\"x\"}")));
        assertThrows(BizException.class, () -> SshEnvelope.parse(envelope(
                "{\"u\":\"\",\"p\":\"x\",\"hk\":\"SHA256:abc\"}")));
    }
}
