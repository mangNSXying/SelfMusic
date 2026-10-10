package com.selfmusic.backend.transcode;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

/**
 * TRANSCODE_MAX_CONCURRENCY 只 env（默认 2，范围 1-32）。
 */
class TranscodeServiceTest {

    @Test
    void defaultsWhenMissingOrInvalid() {
        assertEquals(2, TranscodeService.resolveMaxConcurrency(null));
        assertEquals(2, TranscodeService.resolveMaxConcurrency(""));
        assertEquals(2, TranscodeService.resolveMaxConcurrency("abc"));
        assertEquals(2, TranscodeService.resolveMaxConcurrency("0"));
        assertEquals(2, TranscodeService.resolveMaxConcurrency("99"));
    }

    @Test
    void acceptsValidRange() {
        assertEquals(1, TranscodeService.resolveMaxConcurrency("1"));
        assertEquals(4, TranscodeService.resolveMaxConcurrency("4"));
        assertEquals(32, TranscodeService.resolveMaxConcurrency("32"));
    }

    @Test
    void semaphoreTracksActive() {
        TranscodeService s = new TranscodeService(2, true);
        assertEquals(0, s.activeCount());
        assertTrue(s.tryAcquire());
        assertEquals(1, s.activeCount());
        assertTrue(s.tryAcquire());
        assertEquals(2, s.activeCount());
        assertFalse(s.tryAcquire());
        s.release();
        assertEquals(1, s.activeCount());
    }
}
