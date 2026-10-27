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

    private static SyncSource smbSrc(String address) {
        SyncSource s = new SyncSource();
        s.setKind("smb");
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
    void parseOriginAcceptsSmb() {
        assertDoesNotThrow(
                () -> TranscodeController.parseOrigin("smb://nas/music/a.flac"));
        assertDoesNotThrow(
                () -> TranscodeController.parseOrigin("smb://nas:445/music/a.flac"));
    }

    @Test
    void smbOriginMatchesSmbSourceOnly() {
        var c = controllerWith(smbSrc("nas/music"));
        // smb:// 归一化匹配同类源行（地址无 scheme，补 smb:// 后比）。
        assertDoesNotThrow(() -> c.checkAgainstSyncedSources(
                URI.create("smb://nas/music/a.flac")));
        assertDoesNotThrow(() -> c.checkAgainstSyncedSources(
                URI.create("smb://nas:445/music/sub/a.flac")));
        // 跨类不匹配：webdav/sftp 行挡不住 smb origin。
        assertThrows(BizException.class, () -> c.checkAgainstSyncedSources(
                URI.create("https://nas/music/a.flac")));
        assertThrows(BizException.class, () -> c.checkAgainstSyncedSources(
                URI.create("sftp://nas:22/music/a.flac")));
        // 别的共享挡不住。
        assertThrows(BizException.class, () -> c.checkAgainstSyncedSources(
                URI.create("smb://nas/other/a.flac")));
        // 反向：smb 行挡不住 webdav origin。
        var webOnly = controllerWith(src("https://nas/music"));
        assertThrows(BizException.class, () -> webOnly.checkAgainstSyncedSources(
                URI.create("smb://nas/music/a.flac")));
    }

    @Test
    void smbPathSplit() {
        assertEquals("music",
                TranscodeController.smbShareOf("/music/flac/a.mp3"));
        assertEquals("flac\\a.mp3",
                TranscodeController.smbFilePathOf("/music/flac/a.mp3"));
        assertThrows(BizException.class,
                () -> TranscodeController.smbShareOf("/"));
        assertThrows(BizException.class,
                () -> TranscodeController.smbFilePathOf("/music"));
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
                "https://nas:5006/music/a.flac", "128", "off", "0", null, null, null,
                new MockHttpServletResponse()));
        assertThrows(BizException.class, () -> c.stream(
                "https://nas:5006/music/a.flac", "512", "off", "0", null, null, null,
                new MockHttpServletResponse()));
    }

    @Test
    void rejectsInvalidLoudnorm() {
        var c = controllerWith(src("https://nas:5006/music"));
        assertThrows(BizException.class, () -> c.stream(
                "https://nas:5006/music/a.flac", "192", "99", "0", null, null, null,
                new MockHttpServletResponse()));
        assertThrows(BizException.class, () -> c.stream(
                "https://nas:5006/music/a.flac", "192", "loud", "0", null, null, null,
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
        assertTrue(TranscodeController.ffmpegArgs("192", "8")
                .contains("loudnorm=I=-8:TP=-1.5:LRA=11"));
        assertTrue(TranscodeController.ffmpegArgs("192", "10")
                .contains("loudnorm=I=-10:TP=-1.5:LRA=11"));
        assertTrue(TranscodeController.ffmpegArgs("192", "14")
                .contains("loudnorm=I=-14:TP=-1.5:LRA=11"));
        assertTrue(TranscodeController.ffmpegArgs("256", "16")
                .contains("loudnorm=I=-16:TP=-1.5:LRA=11"));
        assertTrue(TranscodeController.ffmpegArgs("320", "23")
                .contains("loudnorm=I=-23:TP=-1.5:LRA=11"));
        assertNull(TranscodeController.loudFilter("off"));
        assertNull(TranscodeController.loudFilter("bogus"));
    }

    @Test
    void ffmpegArgsSeekIsOutputOption() {
        // 0 不加 -ss：旧行为一致。
        assertFalse(TranscodeController.ffmpegArgs("192", "off", 0).contains("-ss"));
        // >0 时 -ss 落在 -i 之后（输出端；pipe 输入不可 seek，只能解码丢弃）。
        var cmd = TranscodeController.ffmpegArgs("320", "16", 90.5);
        int i = cmd.indexOf("-i");
        int ss = cmd.indexOf("-ss");
        assertTrue(i >= 0 && ss > i);
        assertEquals("90.5", cmd.get(ss + 1));
        // 整数去小数点（日志/响应头同口径）。
        var cmd2 = TranscodeController.ffmpegArgs("192", "off", 60);
        assertEquals("60", cmd2.get(cmd2.indexOf("-ss") + 1));
    }

    @Test
    void parseStartSecValidation() {
        assertEquals(0, TranscodeController.parseStartSec(null));
        assertEquals(0, TranscodeController.parseStartSec(""));
        assertEquals(90.5, TranscodeController.parseStartSec("90.5"));
        assertThrows(BizException.class,
                () -> TranscodeController.parseStartSec("abc"));
        assertThrows(BizException.class,
                () -> TranscodeController.parseStartSec("-1"));
        assertThrows(BizException.class,
                () -> TranscodeController.parseStartSec("NaN"));
        assertThrows(BizException.class,
                () -> TranscodeController.parseStartSec("99999"));
    }

    @Test
    void rejectsInvalidStartSec() {
        var c = controllerWith(src("https://nas:5006/music"));
        assertThrows(BizException.class, () -> c.stream(
                "https://nas:5006/music/a.flac", "192", "off", "-5", null, null, null,
                new MockHttpServletResponse()));
        assertThrows(BizException.class, () -> c.stream(
                "https://nas:5006/music/a.flac", "192", "off", "abc", null, null, null,
                new MockHttpServletResponse()));
    }
}
