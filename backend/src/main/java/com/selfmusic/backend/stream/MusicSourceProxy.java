package com.selfmusic.backend.stream;

import java.io.FilterInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

import com.selfmusic.backend.common.BizException;
import com.selfmusic.backend.domain.entity.Song;

import lombok.extern.slf4j.Slf4j;

/**
 * 统一读取三类源的音频流：local / webdav / smb。
 * Phase 1 实现 local 和 webdav（HTTP 直取），SMB 预留桩。
 */
@Slf4j
@Service
public class MusicSourceProxy {

    @Value("${selfmusic.local.root:}")
    private String localRoot;

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
                Path p = localPath(song);
                try { yield Files.size(p); }
                catch (IOException e) { yield song.getFileSize(); }
            }
            case webdav -> song.getFileSize(); // 后续用 HEAD 探测
            case smb    -> song.getFileSize();
        };
    }

    public String getContentType(Song song) {
        return switch (song.getFormat()) {
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
        java.io.RandomAccessFile raf = new java.io.RandomAccessFile(p.toFile(), "r");
        raf.seek(offset);
        InputStream raw = java.nio.channels.Channels.newInputStream(raf.getChannel());
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
            @Override
            public void close() throws IOException {
                try {
                    super.close();
                } finally {
                    raf.close();
                }
            }
        };
    }

    private InputStream openWebdav(Song song, long offset, long length) throws IOException {
        String url = song.getSourceRef();
        try {
            java.net.http.HttpClient client = java.net.http.HttpClient.newHttpClient();
            java.net.http.HttpRequest req = java.net.http.HttpRequest.newBuilder()
                    .uri(java.net.URI.create(url))
                    .header("Range", "bytes=" + offset + "-" + (offset + length - 1))
                    .GET()
                    .build();
            java.net.http.HttpResponse<InputStream> resp =
                    client.send(req, java.net.http.HttpResponse.BodyHandlers.ofInputStream());
            if (resp.statusCode() != 206 && resp.statusCode() != 200) {
                throw new BizException(50201, "WebDAV fetch failed: " + resp.statusCode());
            }
            return resp.body();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new IOException("WebDAV request interrupted", e);
        }
    }

    private Path localPath(Song song) {
        return Path.of(localRoot, song.getSourceRef()).toAbsolutePath().normalize();
    }
}
