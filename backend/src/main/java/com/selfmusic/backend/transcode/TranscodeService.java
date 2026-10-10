package com.selfmusic.backend.transcode;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

import java.util.concurrent.Semaphore;
import java.util.concurrent.TimeUnit;

/**
 * 无状态转码并发门控 + ffmpeg 可用性探测（阶段6）。
 *
 * <ul>
 *   <li>后端不建曲库、不存文件：转码只是“回源拉流 → ffmpeg 管道 → 流式回客户端”，
 *       凭据随请求转发、不落地。</li>
 *   <li>并发上限只来自 env {@code TRANSCODE_MAX_CONCURRENCY}（默认 2），
 *       不进 settings 表、不经 PUT 修改（用户决策：只 env）。</li>
 *   <li>超限时调用方应回 429 并让客户端回落直连原文件（R5 缓解）。</li>
 * </ul>
 */
@Service
public class TranscodeService {

    private static final Logger log = LoggerFactory.getLogger(TranscodeService.class);

    public static final int DEFAULT_MAX_CONCURRENCY = 2;

    private final int maxConcurrency;
    private final Semaphore permits;
    private final boolean ffmpegAvailable;

    public TranscodeService() {
        this(resolveMaxConcurrency(), probeFfmpeg());
    }

    TranscodeService(int maxConcurrency, boolean ffmpegAvailable) {
        this.maxConcurrency = maxConcurrency;
        this.permits = new Semaphore(maxConcurrency);
        this.ffmpegAvailable = ffmpegAvailable;
    }

    /** env 解析口（测试可直接调）：非法/缺省回退默认 2。 */
    public static int resolveMaxConcurrency() {
        return resolveMaxConcurrency(System.getenv("TRANSCODE_MAX_CONCURRENCY"));
    }

    static int resolveMaxConcurrency(String raw) {
        if (raw == null || raw.trim().isEmpty()) return DEFAULT_MAX_CONCURRENCY;
        try {
            int v = Integer.parseInt(raw.trim());
            if (v >= 1 && v <= 32) return v;
        } catch (NumberFormatException ignored) {
        }
        return DEFAULT_MAX_CONCURRENCY;
    }

    private static boolean probeFfmpeg() {
        try {
            Process p = new ProcessBuilder("ffmpeg", "-version")
                    .redirectErrorStream(true).start();
            boolean done = p.waitFor(5, TimeUnit.SECONDS);
            if (!done) {
                p.destroyForcibly();
                return false;
            }
            return p.exitValue() == 0;
        } catch (Exception e) {
            log.warn("ffmpeg 探测失败（视为不可用）: {}", e.toString());
            return false;
        }
    }

    public int getMaxConcurrency() {
        return maxConcurrency;
    }

    public boolean isFfmpegAvailable() {
        return ffmpegAvailable;
    }

    /** 当前占用数（max - 可用许可）。 */
    public int activeCount() {
        return maxConcurrency - permits.availablePermits();
    }

    /** 非阻塞尝试占用；成功须在 finally 中 {@link #release()}。 */
    public boolean tryAcquire() {
        return permits.tryAcquire();
    }

    public void release() {
        permits.release();
    }
}
