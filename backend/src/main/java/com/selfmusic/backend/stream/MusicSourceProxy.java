package com.selfmusic.backend.stream;

import java.io.FilterInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Base64;

import com.selfmusic.backend.common.BizException;
import com.selfmusic.backend.domain.entity.Song;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

/**
 * 统一读取三类源的音频流：local / webdav / smb。
 * Phase 1 实现 local 和 webdav（HTTP 直取），SMB 预留桩。
 */
@Slf4j
@Service
public class MusicSourceProxy {

    /** 全进程共享，支持 HTTP/2 连接复用；HttpClient 线程安全 */
    private static final java.net.http.HttpClient HTTP = java.net.http.HttpClient.newHttpClient();

    @Value("${selfmusic.local.root:}")
    private String localRoot;

    @Value("${selfmusic.webdav.base-url:}")
    private String webdavBaseUrl;

    @Value("${selfmusic.webdav.username:}")
    private String webdavUsername;

    @Value("${selfmusic.webdav.password:}")
    private String webdavPassword;

    /**
     * 以指定 offset + length 打开音频流
     */
    public InputStream open(Song song, long offset, long length) throws IOException {
        return switch (song.getSource()) {
            case local   -> openLocal(song, offset, length);
            case webdav  -> openWebdav(song, offset, length);
            case smb     -> throw new BizException(50101, "SMB direct not implemented yet");
        };
    }

    public long getFileSize(Song song) {
        return switch (song.getSource()) {
            case local  -> {
                try { yield Files.size(localPath(song)); }
                catch (IOException e) { yield song.getFileSize(); }
            }
            case webdav -> song.getFileSize(); // 后续用 HEAD 探测
            case smb    -> song.getFileSize();
        };
    }

    public String getContentType(Song song) {
        return switch (song.getFormat() == null ? "" : song.getFormat()) {
            case "mp3"  -> "audio/mpeg";
            case "flac" -> "audio/flac";
            case "m4a", "aac" -> "audio/mp4";
            case "ogg"  -> "audio/ogg";
            case "wav"  -> "audio/wav";
            default     -> "application/octet-stream";
        };
    }

    private InputStream openLocal(Song song, long offset, long length) throws IOException {
        Path p = localPath(song);
        // RandomAccessFile 经 FileChannel 包装为流；关闭流会连带关闭 channel 与文件句柄
        java.io.RandomAccessFile raf = new java.io.RandomAccessFile(p.toFile(), "r");
        boolean seekOk = false;
        try {
            raf.seek(offset);
            seekOk = true;
            InputStream raw = java.nio.channels.Channels.newInputStream(raf.getChannel());
            return limit(raw, length);
        } finally {
            if (!seekOk) raf.close();
        }
    }

    /** 限制读取长度到 len 字节 */
    private static InputStream limit(InputStream raw, long length) {
        return new FilterInputStream(raw) {
            private long remaining = length;
            @Override
            public int read() throws IOException {
                if (remaining <= 0) return -1;
                int b = super.read();
                if (b >= 0) remaining--;
                return b;
            }
            @Override
            public int read(byte[] buf, int off, int len) throws IOException {
                if (remaining <= 0) return -1;
                int toRead = (int) Math.min(len, remaining);
                int n = super.read(buf, off, toRead);
                if (n > 0) remaining -= n;
                return n;
            }
        };
    }

    private InputStream openWebdav(Song song, long offset, long length) throws IOException {
        String ref = song.getSourceRef();
        String url = ref.startsWith("http://") || ref.startsWith("https://")
                ? ref
                : webdavBaseUrl + (webdavBaseUrl.endsWith("/") || ref.startsWith("/") ? "" : "/") + ref;
        if (url.isBlank() || url.equals("/")) {
            throw new BizException(50002, "WebDAV base-url not configured");
        }

        java.net.http.HttpRequest.Builder builder;
        try {
            builder = java.net.http.HttpRequest.newBuilder()
                    .uri(java.net.URI.create(url))
                    .header("Range", "bytes=" + offset + "-" + (offset + length - 1))
                    .GET();
        } catch (IllegalArgumentException e) {
            throw new BizException(50202, "invalid WebDAV url: " + url);
        }
        if (!webdavUsername.isBlank()) {
            String cred = Base64.getEncoder().encodeToString(
                    (webdavUsername + ":" + webdavPassword).getBytes(StandardCharsets.UTF_8));
            builder.header("Authorization", "Basic " + cred);
        }

        try {
            java.net.http.HttpResponse<InputStream> resp =
                    HTTP.send(builder.build(), java.net.http.HttpResponse.BodyHandlers.ofInputStream());
            if (resp.statusCode() != 206 && resp.statusCode() != 200) {
                throw new BizException(50201, "WebDAV fetch failed: HTTP " + resp.statusCode());
            }
            return resp.body();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new IOException("WebDAV request interrupted", e);
        }
    }

    /**
     * 解析本地路径并做穿越校验：解析后的绝对路径必须仍位于 localRoot 内。
     */
    private Path localPath(Song song) {
        if (localRoot == null || localRoot.isBlank()) {
            throw new BizException(50003, "local music root not configured");
        }
        Path root = Path.of(localRoot).toAbsolutePath().normalize();
        Path resolved = root.resolve(song.getSourceRef()).normalize();
        if (!resolved.startsWith(root)) {
            log.warn("Blocked path traversal attempt: sourceRef={}", song.getSourceRef());
            throw new BizException(40301, "invalid source reference");
        }
        return resolved;
    }
}
