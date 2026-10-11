package com.selfmusic.backend.transcode.smb;

import com.selfmusic.backend.common.BizException;
import org.junit.jupiter.api.Test;

import java.util.Base64;

import static org.junit.jupiter.api.Assertions.*;

/**
 * SMB 信封解析：base64url(JSON {@code {u?, p?}})，双空即匿名。
 */
class SmbEnvelopeTest {

    private static String env(String json) {
        return Base64.getUrlEncoder().withoutPadding()
                .encodeToString(json.getBytes(java.nio.charset.StandardCharsets.UTF_8));
    }

    @Test
    void parsesPasswordAuth() {
        var c = SmbEnvelope.parse(env("{\"u\":\"nas-user\",\"p\":\"s3cret\"}"));
        assertEquals("nas-user", c.username());
        assertEquals("s3cret", c.password());
        assertFalse(c.anonymous());
    }

    @Test
    void anonymousWhenBothEmpty() {
        var c = SmbEnvelope.parse(env("{\"u\":\"\",\"p\":\"\"}"));
        assertTrue(c.anonymous());
        var missing = SmbEnvelope.parse(env("{}"));
        assertTrue(missing.anonymous());
    }

    @Test
    void rejectsMissingOrBroken() {
        assertThrows(BizException.class, () -> SmbEnvelope.parse(null));
        assertThrows(BizException.class, () -> SmbEnvelope.parse("  "));
        assertThrows(BizException.class, () -> SmbEnvelope.parse("!!!not-base64!!!"));
        assertThrows(BizException.class, () -> SmbEnvelope.parse(env("[1,2]")));
    }
}
