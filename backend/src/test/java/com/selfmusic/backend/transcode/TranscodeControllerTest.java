package com.selfmusic.backend.transcode;

import com.selfmusic.backend.common.BizException;
import com.selfmusic.backend.domain.entity.SyncSource;
import com.selfmusic.backend.domain.repository.SyncSourceRepository;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletResponse;

import java.net.URI;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

/**
 * 强校验：origin 必须落在已同步 WebDAV 源之下；bitrate/scheme/黑名单host。
 */
class TranscodeControllerTest {

    private TranscodeController controllerWith(SyncSource... sources) {
        SyncSourceRepository repo = mock(SyncSourceRepository.class);
        when(repo.findAll()).thenReturn(List.of(sources));
        return new TranscodeController(new TranscodeService(2, true), repo);
    }

    private static SyncSource src(String address) {
        SyncSource s = new SyncSource();
        s.setKind("webdav");
        s.setAddress(address);
        s.setDeleted(false);
        return s;
    }

    @Test
    void matchesBase() {
        assertTrue(TranscodeController.matchesBase(
                "https://nas:5006/music", "https://nas:5006/music/a.flac"));
        assertTrue(TranscodeController.matchesBase(
                "https://nas:5006/music/", "https://nas:5006/music/sub/a.flac"));
        assertFalse(TranscodeController.matchesBase(
                "https://nas:5006/music", "https://nas:5006/other/a.flac"));
        assertFalse(TranscodeController.matchesBase(
                "https://nas:5006/music", "http://nas:5006/music/a.flac"));
        assertFalse(TranscodeController.matchesBase(
                "https://nas:5006/music", "https://evil:5006/music/a.flac"));
    }

    @Test
    void rejectsBadSchemeAndBlockedHosts() {
        assertThrows(BizException.class,
                () -> TranscodeController.parseOrigin("ftp://x/a.flac"));
        assertThrows(BizException.class,
                () -> TranscodeController.checkBlockedHost(URI.create("http://169.254.169.254/x")));
    }

    @Test
    void rejectsOriginOutsideSyncedSources() {
        var c = controllerWith(src("https://nas:5006/music"));
        assertThrows(BizException.class, () -> c.checkAgainstSyncedSources(
                URI.create("https://evil:5006/music/a.flac")));
        assertDoesNotThrow(() -> c.checkAgainstSyncedSources(
                URI.create("https://nas:5006/music/a.flac")));
    }

    @Test
    void acceptsLegacyAddressWithoutScheme() {
        // 历史行：客户端可输入无 scheme 地址，落库为 webdav.shamiko.site/data；
        // 校验须按「补 https」归一化后匹配（回归：转码 40301/400 直接失败）。
        var c = controllerWith(src("webdav.shamiko.site/data"));
        assertDoesNotThrow(() -> c.checkAgainstSyncedSources(
                URI.create("https://webdav.shamiko.site/data/foo.flac")));
        assertThrows(BizException.class, () -> c.checkAgainstSyncedSources(
                URI.create("https://other.site/data/foo.flac")));
    }

    @Test
    void rejectsInvalidBitrateBeforeAnything() {
        var c = controllerWith(src("https://nas:5006/music"));
        assertThrows(BizException.class, () -> c.stream(
                "https://nas:5006/music/a.flac", "320", null,
                new MockHttpServletResponse()));
    }
}
