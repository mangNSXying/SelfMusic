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

    private static SyncSource sftpSrc(String address) {
        SyncSource s = new SyncSource();
        s.setKind("sftp");
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
    void sftpOriginMatchesSftpSourceOnly() {
        var c = controllerWith(sftpSrc("nas:22/music"));
        // sftp:// 归一化匹配同类源行。
        assertDoesNotThrow(() -> c.checkAgainstSyncedSources(
                URI.create("sftp://nas:22/music/a.flac")));
        assertDoesNotThrow(() -> c.checkAgainstSyncedSources(
                URI.create("sftp://nas/music/a.flac")));
        // 跨类不匹配：http 源行挡不住 sftp origin。
        assertThrows(BizException.class, () -> c.checkAgainstSyncedSources(
                URI.create("https://nas/music/a.flac")));
        var mixed = controllerWith(src("https://nas/music"), sftpSrc("nas:22/music"));
        assertDoesNotThrow(() -> mixed.checkAgainstSyncedSources(
                URI.create("https://nas/music/a.flac")));
        assertDoesNotThrow(() -> mixed.checkAgainstSyncedSources(
                URI.create("sftp://nas/music/a.flac")));
        // webdav 行挡不住 sftp origin（反向亦然）。
        var webOnly = controllerWith(src("https://nas/music"));
        assertThrows(BizException.class, () -> webOnly.checkAgainstSyncedSources(
                URI.create("sftp://nas/music/a.flac")));
    }

    @Test
    void parseOriginAcceptsSftp() {
        assertDoesNotThrow(
                () -> TranscodeController.parseOrigin("sftp://nas:22/music/a.flac"));
        assertThrows(BizException.class,
                () -> TranscodeController.parseOrigin("ftp://x/a.flac"));
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
        // 已下架的低档与非法值同样拒绝（档位现为 192/256/320）。
        assertThrows(BizException.class, () -> c.stream(
                "https://nas:5006/music/a.flac", "128", "off", null, null,
                new MockHttpServletResponse()));
        assertThrows(BizException.class, () -> c.stream(
                "https://nas:5006/music/a.flac", "512", "off", null, null,
                new MockHttpServletResponse()));
    }

    @Test
    void rejectsInvalidLoudnorm() {
        var c = controllerWith(src("https://nas:5006/music"));
        assertThrows(BizException.class, () -> c.stream(
                "https://nas:5006/music/a.flac", "192", "99", null, null,
                new MockHttpServletResponse()));
        assertThrows(BizException.class, () -> c.stream(
                "https://nas:5006/music/a.flac", "192", "loud", null, null,
                new MockHttpServletResponse()));
    }

    @Test
    void ffmpegArgsOmitsFilterWhenOff() {
        var cmd = TranscodeController.ffmpegArgs("192", "off");
        assertFalse(cmd.contains("-af"));
        assertTrue(cmd.contains("libmp3lame"));
        assertTrue(cmd.contains("192k"));
    }

    @Test
    void ffmpegArgsMapsLoudnessTiers() {
        assertTrue(TranscodeController.ffmpegArgs("192", "14")
                .contains("loudnorm=I=-14:TP=-1.5:LRA=11"));
        assertTrue(TranscodeController.ffmpegArgs("256", "16")
                .contains("loudnorm=I=-16:TP=-1.5:LRA=11"));
        assertTrue(TranscodeController.ffmpegArgs("320", "23")
                .contains("loudnorm=I=-23:TP=-1.5:LRA=11"));
        assertNull(TranscodeController.loudFilter("off"));
        assertNull(TranscodeController.loudFilter("bogus"));
    }
}
