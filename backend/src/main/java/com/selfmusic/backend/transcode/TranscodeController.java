package com.selfmusic.backend.transcode;

import com.selfmusic.backend.common.BizException;
import com.selfmusic.backend.common.SourceAddresses;
import com.selfmusic.backend.domain.entity.SyncSource;
import com.selfmusic.backend.domain.repository.SyncSourceRepository;
import com.selfmusic.backend.transcode.ssh.SshEnvelope;
import com.selfmusic.backend.transcode.ssh.SshOriginFetcher;
import com.selfmusic.backend.transcode.smb.SmbEnvelope;
import com.selfmusic.backend.transcode.smb.SmbOriginFetcher;
import jakarta.servlet.http.HttpServletResponse;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;

/**
 * 无状态转码代理（阶段6）。
 *
 * <ul>
 *   <li>后端不建曲库、不存文件：{@code origin} 必须是已同步 WebDAV 源地址之下的
 *       文件 URL（强校验 {@code sync_sources}），凭据经 {@code X-Origin-Auth}
 *       随请求转发、不落地不记日志。</li>
 *   <li>输出恒为 MP3 CBR（bitrate 仅 192/256/320，默认 192；MP3 无 512 档——
 *       libmp3lame 会静默钳到 320，故不开放），整曲转码，
 *       不支持 Range（转码后字节≠源字节，R8：seek 由客户端重建请求）。</li>
 *   <li>并发由 {@link TranscodeService} 信号量门控（只 env，默认 2）；
 *       超限 429，客户端回落直连原文件。</li>
 *   <li>在 servlet 线程内**同步直写**响应，不用 {@code StreamingResponseBody}：
 *       后者的异步二次派发会重入安全过滤链（TokenFilter 默认跳过 async
 *       dispatch），导致流式响应阶段 401；并发上限仅 2，占用两个工作线程无碍。</li>
 *   <li>可选响度均衡（`loudnorm=off|14|16|23`，默认 off）：开时在编码前插入单遍
 *       动态 loudnorm（I=目标/TP=-1.5/LRA=11），统一各曲响度；只在代理转码
 *       链路生效（直连/缓存不经过服务端）。双遍线性需整曲预读，与流式低延迟
 *       冲突，暂不做。</li>
 * </ul>
 */
@RestController
@RequestMapping("/api/v1/transcode")
public class TranscodeController {

    private static final Logger log = LoggerFactory.getLogger(TranscodeController.class);

    private static final Set<String> ALLOWED_BITRATES = Set.of("192", "256", "320");

    /** 响度均衡目标（LUFS）：off=关；其余统一到该集成响度（单遍动态）。 */
    private static final Set<String> ALLOWED_LOUDNORM = Set.of("off", "14", "16", "23");

    /** 云元数据/链路本地：一律拒绝（SSRF 纵深，强校验之外再加一道）。 */
    private static final Set<String> BLOCKED_HOSTS = Set.of(
            "169.254.169.254", "metadata.google.internal",
            "metadata.goog", "instance-data", "metadata.azure.internal");

    private final TranscodeService transcodeService;
    private final SyncSourceRepository syncSourceRepository;

    public TranscodeController(TranscodeService transcodeService,
                               SyncSourceRepository syncSourceRepository) {
        this.transcodeService = transcodeService;
        this.syncSourceRepository = syncSourceRepository;
    }

    @GetMapping("/stream")
    public void stream(
            @RequestParam("origin") String origin,
            @RequestParam(value = "bitrate", defaultValue = "192") String bitrate,
            @RequestParam(value = "loudnorm", defaultValue = "off") String loudnorm,
            @RequestHeader(value = "X-Origin-Auth", required = false) String originAuth,
            @RequestHeader(value = "X-Origin-Ssh", required = false) String originSsh,
            @RequestHeader(value = "X-Origin-Smb", required = false) String originSmb,
            HttpServletResponse response) {
        String rate = bitrate == null ? "192" : bitrate.trim();
        if (!ALLOWED_BITRATES.contains(rate)) {
            throw new BizException(40001, "bitrate 仅支持 192/256/320");
        }
        String loud = loudnorm == null ? "off" : loudnorm.trim().toLowerCase();
        if (!ALLOWED_LOUDNORM.contains(loud)) {
            throw new BizException(40001, "loudnorm 仅支持 off/14/16/23");
        }
        URI uri = parseOrigin(origin);
        checkBlockedHost(uri);
        checkAgainstSyncedSources(uri);
        if (!transcodeService.isFfmpegAvailable()) {
            throw new ResponseStatusException(HttpStatus.SERVICE_UNAVAILABLE, "ffmpeg 不可用");
        }
        if (!transcodeService.tryAcquire()) {
            response.setHeader("Retry-After", "5");
            throw new ResponseStatusException(HttpStatus.TOO_MANY_REQUESTS, "转码并发已满，已回落直连");
        }
        Process ffmpeg = null;
        try {
            // 注意：绝不记录任何回源凭据的值（X-Origin-Auth / X-Origin-Ssh /
            // X-Origin-Smb 信封内容）。
            boolean isSftp = "sftp".equalsIgnoreCase(uri.getScheme());
            boolean isSmb = "smb".equalsIgnoreCase(uri.getScheme());
            log.info("transcode start scheme={} host={} bitrate={}k loudnorm={}",
                    uri.getScheme(), uri.getHost(), rate, loud);
            InputStream originStream;
            if (isSftp) {
                SshEnvelope.Credentials creds = SshEnvelope.parse(originSsh);
                int port = uri.getPort() != -1 ? uri.getPort() : 22;
                log.debug("transcode sftp auth={}", creds.useKey() ? "key" : "password");
                originStream = SshOriginFetcher.openStream(
                        uri.getHost(), port, uri.getPath(), creds);
            } else if (isSmb) {
                SmbEnvelope.Credentials creds = SmbEnvelope.parse(originSmb);
                int port = uri.getPort() != -1 ? uri.getPort() : 445;
                log.debug("transcode smb auth={}",
                        creds.anonymous() ? "anonymous" : "password");
                originStream = SmbOriginFetcher.openStream(
                        uri.getHost(), port,
                        smbShareOf(uri.getPath()), smbFilePathOf(uri.getPath()),
                        creds);
            } else {
                originStream = openHttpStream(uri, originAuth);
            }
            try {
                ffmpeg = new ProcessBuilder(ffmpegArgs(rate, loud))
                        .redirectErrorStream(false)
                        .start();
            } catch (IOException e) {
                throw new ResponseStatusException(HttpStatus.BAD_GATEWAY,
                        "转码进程启动失败: " + e.getMessage());
            }
            Process proc = ffmpeg;
            // 回源字节 → ffmpeg stdin（虚拟线程，避免阻塞当前线程）。
            Thread feeder = Thread.ofVirtual().start(() -> {
                try (InputStream in = originStream;
                     OutputStream stdin = proc.getOutputStream()) {
                    in.transferTo(stdin);
                } catch (Exception ignored) {
                }
            });
            // ffmpeg stderr 消费掉，避免缓冲撑满卡死（不记内容，只防堵）。
            Thread drainer = Thread.ofVirtual().start(() -> {
                try (InputStream err = proc.getErrorStream()) {
                    err.readAllBytes();
                } catch (Exception ignored) {
                }
            });
            // 头部只在「确定能开始输出」后再设：提早设置会让后续 JSON 错误响应
            // 因 preset Content-Type 无法写出（No converter ... preset audio/mpeg），
            // 进而落入 /error 派发被安全链二次拦截成 401。
            response.setContentType("audio/mpeg");
            response.setHeader("Accept-Ranges", "none");
            response.setHeader("X-Transcoded-By", "selfmusic");
            try {
                OutputStream out = response.getOutputStream();
                try (InputStream mp3 = proc.getInputStream()) {
                    byte[] buf = new byte[64 * 1024];
                    int n;
                    while ((n = mp3.read(buf)) != -1) {
                        out.write(buf, 0, n);
                    }
                    out.flush();
                }
            } catch (IOException e) {
                // 客户端中途断开（切歌/退播）：正常，掐掉 ffmpeg 静默收尾。
                proc.destroyForcibly();
                log.debug("transcode client disconnected host={}", uri.getHost());
                return;
            } finally {
                feeder.interrupt();
                drainer.interrupt();
            }
            int code;
            try {
                code = proc.waitFor();
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                code = -1;
            }
            log.info("transcode done host={} bitrate={}k exit={}", uri.getHost(), rate, code);
            if (code != 0) {
                if (!response.isCommitted()) {
                    throw new ResponseStatusException(HttpStatus.BAD_GATEWAY, "转码失败");
                }
                log.warn("transcode failed mid-stream host={} exit={}", uri.getHost(), code);
            }
        } finally {
            if (ffmpeg != null) ffmpeg.destroyForcibly();
            transcodeService.release();
        }
    }

    /** HTTP(S) 回源取流（SFTP 走 {@link SshOriginFetcher}）。失败抛 502，客户端回落直连。 */
    static InputStream openHttpStream(URI uri, String originAuth) {
        String authHeader = originAuth == null ? "" : originAuth.trim();
        HttpClient http = HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(15))
                .followRedirects(HttpClient.Redirect.NEVER)
                .build();
        HttpRequest.Builder rb = HttpRequest.newBuilder(uri)
                .timeout(Duration.ofMinutes(10))
                .GET();
        if (!authHeader.isEmpty()) {
            rb.header("Authorization", authHeader);
        }
        rb.header("User-Agent", "SelfMusic-Transcode");
        HttpResponse<InputStream> originResp;
        try {
            originResp = http.send(rb.build(), HttpResponse.BodyHandlers.ofInputStream());
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new ResponseStatusException(HttpStatus.BAD_GATEWAY, "转码回源被中断");
        } catch (IOException e) {
            // 源不可达/连接被拒（如容器无 IPv6 路由而源仅 AAAA）：502，客户端回落直连。
            throw new ResponseStatusException(HttpStatus.BAD_GATEWAY,
                    "源不可达: " + e.getMessage());
        }
        int st = originResp.statusCode();
        if (st != 200 && st != 206) {
            try (InputStream ignored = originResp.body()) {
                // 耗尽以复用连接，内容丢弃。
                ignored.readAllBytes();
            } catch (Exception ignored) {
            }
            if (st == 401 || st == 403) {
                throw new ResponseStatusException(HttpStatus.BAD_GATEWAY, "源鉴权失败");
            }
            throw new ResponseStatusException(HttpStatus.BAD_GATEWAY, "源取流失败: " + st);
        }
        return originResp.body();
    }

    static URI parseOrigin(String origin) {
        if (origin == null || origin.isBlank()) {
            throw new BizException(40001, "origin 不能为空");
        }
        URI uri;
        try {
            uri = URI.create(origin.trim());
        } catch (IllegalArgumentException e) {
            throw new BizException(40001, "origin 非法 URL");
        }
        String scheme = uri.getScheme() == null ? "" : uri.getScheme().toLowerCase();
        if (!scheme.equals("http") && !scheme.equals("https")
                && !scheme.equals("sftp") && !scheme.equals("smb")) {
            throw new BizException(40001, "origin 仅支持 http/https/sftp/smb");
        }
        if (uri.getHost() == null || uri.getHost().isEmpty()) {
            throw new BizException(40001, "origin 缺少主机");
        }
        return uri;
    }

    static void checkBlockedHost(URI uri) {
        String host = uri.getHost().toLowerCase();
        if (BLOCKED_HOSTS.contains(host)) {
            throw new BizException(40301, "origin 主机被拒绝");
        }
    }

    /** 强校验：origin 必须落在某个未删除**同类**源地址之下（含端口与路径前缀）。 */
    void checkAgainstSyncedSources(URI uri) {
        boolean wantSftp = "sftp".equalsIgnoreCase(uri.getScheme());
        boolean wantSmb = "smb".equalsIgnoreCase(uri.getScheme());
        List<SyncSource> sources = syncSourceRepository.findAll();
        for (SyncSource s : sources) {
            if (s.isDeleted()) continue;
            if (wantSftp ? !"sftp".equalsIgnoreCase(s.getKind())
                    : wantSmb ? !"smb".equalsIgnoreCase(s.getKind())
                    : !"webdav".equalsIgnoreCase(s.getKind())) continue;
            // 容忍历史/原始形态的无 scheme 地址（客户端会补 https 再请求）。
            String normalized = SourceAddresses.normalize(s.getKind(), s.getAddress());
            URI base;
            try {
                base = URI.create(normalized);
            } catch (IllegalArgumentException e) {
                continue;
            }
            if (!sameSchemeHostPort(base, uri)) continue;
            String basePath = normPath(base.getPath());
            String originPath = normPath(uri.getPath());
            if (originPath.startsWith(basePath)) return;
        }
        log.warn("transcode origin rejected: {}://{}{}（候选源数 {}）",
                uri.getScheme(), uri.getAuthority(), uri.getPath(), sources.size());
        throw new BizException(40301, "origin 不在已同步源之下");
    }

    private static boolean sameSchemeHostPort(URI a, URI b) {
        return eqIgnoreCase(a.getScheme(), b.getScheme())
                && eqIgnoreCase(a.getHost(), b.getHost())
                && effectivePort(a) == effectivePort(b);
    }

    private static boolean eqIgnoreCase(String a, String b) {
        if (a == null || b == null) return a == b;
        return a.equalsIgnoreCase(b);
    }

    private static int effectivePort(URI u) {
        if (u.getPort() != -1) return u.getPort();
        if ("https".equalsIgnoreCase(u.getScheme())) return 443;
        if ("sftp".equalsIgnoreCase(u.getScheme())) return 22;
        if ("smb".equalsIgnoreCase(u.getScheme())) return 445;
        return 80;
    }

    private static String normPath(String p) {
        if (p == null || p.isEmpty()) return "/";
        return p.endsWith("/") ? p : p + "/";
    }

    /**
     * smb origin 路径（`/share/余下路径`，百分号编码已由 {@link URI#getPath}
     * 解码）拆出共享名；缺共享段抛请求非法。
     */
    static String smbShareOf(String path) {
        String[] segs = splitSmbPath(path);
        if (segs.length == 0) {
            throw new BizException(40001, "smb origin 缺少共享名");
        }
        return segs[0];
    }

    /**
     * smb origin 路径拆出共享内文件路径（smbj 用反斜杠；文件名不可能含 `/`，
     * 逐段转义安全）。仅共享根时抛请求非法（转码必须指向文件）。
     */
    static String smbFilePathOf(String path) {
        String[] segs = splitSmbPath(path);
        if (segs.length < 2) {
            throw new BizException(40001, "smb origin 必须指向共享内文件");
        }
        StringBuilder sb = new StringBuilder();
        for (int i = 1; i < segs.length; i++) {
            if (i > 1) sb.append('\\');
            sb.append(segs[i]);
        }
        return sb.toString();
    }

    private static String[] splitSmbPath(String path) {
        if (path == null) return new String[0];
        String[] raw = path.split("/");
        java.util.List<String> out = new java.util.ArrayList<>();
        for (String s : raw) {
            if (s == null || s.isEmpty() || s.equals(".") || s.equals("..")) continue;
            out.add(s);
        }
        return out.toArray(new String[0]);
    }

    /** 供测试：纯函数校验（不查库）。 */
    static boolean matchesBase(String baseAddress, String origin) {
        URI base = URI.create(baseAddress);
        URI o = URI.create(origin);
        if (!sameSchemeHostPort(base, o)) return false;
        return normPath(o.getPath()).startsWith(normPath(base.getPath()));
    }

    /**
     * ffmpeg 命令组装（纯函数，可单测）：响度均衡开时在编码前插入单遍动态
     * loudnorm；off 时与旧行为一致、无 {@code -af}。
     */
    static List<String> ffmpegArgs(String rate, String loudnorm) {
        List<String> cmd = new ArrayList<>(List.of(
                "ffmpeg", "-hide_banner", "-loglevel", "error",
                "-i", "pipe:0",
                "-vn"));
        String filter = loudFilter(loudnorm);
        if (filter != null) {
            cmd.add("-af");
            cmd.add(filter);
        }
        cmd.addAll(List.of("-c:a", "libmp3lame", "-b:a", rate + "k",
                "-f", "mp3", "pipe:1"));
        return cmd;
    }

    /** loudnorm 滤镜参数；off/未知（防御）返回 null（不加滤镜）。 */
    static String loudFilter(String loudnorm) {
        if (loudnorm == null) return null;
        return switch (loudnorm.trim().toLowerCase()) {
            case "14" -> "loudnorm=I=-14:TP=-1.5:LRA=11";
            case "16" -> "loudnorm=I=-16:TP=-1.5:LRA=11";
            case "23" -> "loudnorm=I=-23:TP=-1.5:LRA=11";
            default -> null;
        };
    }
}
