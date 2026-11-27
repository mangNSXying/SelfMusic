package com.selfmusic.backend.sync;

import java.time.Duration;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.MediaType;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import org.springframework.web.servlet.mvc.method.annotation.SseEmitter;

import com.fasterxml.jackson.databind.ObjectMapper;

import jakarta.annotation.PreDestroy;

/**
 * 断点推送连接中心（服务端 → 客户端，SSE）。
 *
 * <p>只承担「把某个歌单刚发生变化」这件事告诉其它在线设备，不携带权威快照，
 * 也不参与 head/history 仲裁。客户端收到后仍走既有 {@code /playstates/latest}
 * 快路径或 {@code /sync/pull}，所有版本守卫、pending head、自写回声过滤、
 * 「播放中不打断」逻辑保持原样。</p>
 *
 * <p>单实例内存实现：当前 docker-compose 单副本，连接只存在进程内；服务重启
 * 全部断开，客户端靠 30s 轮询收敛。将来水平扩容需改为 Redis pub/sub 或粘性路由。</p>
 */
@Component
public class BreakpointPushHub {

    private static final Logger log = LoggerFactory.getLogger(BreakpointPushHub.class);

    /** 单连接最长 30 分钟：到期客户端重连，顺带完成 token 续签/吊销检查。 */
    private static final long SSE_TIMEOUT_MS = Duration.ofMinutes(30).toMillis();

    /** 心跳间隔：远小于 nginx 默认 60s 读超时，也小于客户端 45s 空闲判定。 */
    private static final long HEARTBEAT_INTERVAL_MS = 15_000L;

    private final ObjectMapper objectMapper;
    private final Map<String, SseEmitter> emitters = new ConcurrentHashMap<>();

    public BreakpointPushHub(ObjectMapper objectMapper) {
        this.objectMapper = objectMapper;
    }

    /** 一条设备连接（同 clientId 重连时关闭旧连接）。 */
    public synchronized SseEmitter connect(String clientId, Map<String, Object> hello) {
        SseEmitter emitter = new SseEmitter(SSE_TIMEOUT_MS);
        emitter.onCompletion(() -> emitters.remove(clientId, emitter));
        emitter.onTimeout(() -> {
            emitters.remove(clientId, emitter);
            emitter.complete();
        });
        emitter.onError(e -> {
            emitters.remove(clientId, emitter);
            log.debug("sync.sse error client={} {}", clientId, e.toString());
        });

        SseEmitter old = emitters.put(clientId, emitter);
        if (old != null) {
            // 旧连接的 onCompletion 按 (clientId, old) 精确移除，不会误删新连接。
            try {
                old.complete();
            } catch (Exception ignored) {
            }
        }
        sendJson(emitter, clientId, "ready", hello);
        log.info("sync.sse connect client={} active={}", clientId, emitters.size());
        return emitter;
    }

    /**
     * 事务提交后广播断点变化。事务回滚不通知；无事务环境（单测）立即通知。
     * 同一批事件按 playlist 去重，只保最后一条。
     */
    public void publishAfterCommit(String originClientId,
                                   Collection<BreakpointSignal> signals,
                                   long cursor) {
        if (signals == null || signals.isEmpty()) return;
        Map<String, BreakpointSignal> byPlaylist = new LinkedHashMap<>();
        for (BreakpointSignal signal : signals) {
            if (signal == null || signal.playlistUuid() == null
                    || signal.playlistUuid().isBlank()) {
                continue;
            }
            byPlaylist.put(signal.playlistUuid(), signal);
        }
        if (byPlaylist.isEmpty()) return;

        Runnable task = () -> publish(originClientId, byPlaylist.values(), cursor);
        if (TransactionSynchronizationManager.isSynchronizationActive()) {
            TransactionSynchronizationManager.registerSynchronization(
                    new TransactionSynchronization() {
                        @Override
                        public void afterCommit() {
                            task.run();
                        }
                    });
        } else {
            task.run();
        }
    }

    private void publish(String originClientId,
                         Collection<BreakpointSignal> signals,
                         long cursor) {
        if (emitters.isEmpty()) return;
        int sent = 0;
        for (BreakpointSignal signal : signals) {
            Map<String, Object> payload = new LinkedHashMap<>();
            payload.put("playlist_uuid", signal.playlistUuid());
            payload.put("head_rev", signal.headRev());
            payload.put("history_rev", signal.historyRev());
            if (signal.headDevice() != null) payload.put("head_device", signal.headDevice());
            if (signal.intent() != null) payload.put("intent", signal.intent());
            payload.put("cursor", cursor);
            payload.put("server_time", SyncService.serverTimeNow());
            for (Map.Entry<String, SseEmitter> entry : emitters.entrySet()) {
                // 自写回声过滤第一层：不向产生事件的设备回灌。
                if (entry.getKey().equals(originClientId)) continue;
                if (sendJson(entry.getValue(), entry.getKey(), "breakpoint", payload)) {
                    sent++;
                }
            }
        }
        log.debug("sync.sse publish origin={} playlists={} sent={} active={}",
                originClientId, signals.size(), sent, emitters.size());
    }

    /** 心跳：注释帧不产生事件，只保证连接/反代不因空闲断流。 */
    @Scheduled(fixedRate = HEARTBEAT_INTERVAL_MS)
    public void heartbeat() {
        if (emitters.isEmpty()) return;
        for (Map.Entry<String, SseEmitter> entry : emitters.entrySet()) {
            try {
                entry.getValue().send(SseEmitter.event().comment("ping"));
            } catch (Exception e) {
                emitters.remove(entry.getKey(), entry.getValue());
                try {
                    entry.getValue().complete();
                } catch (Exception ignored) {
                }
            }
        }
    }

    /** 吊销/解绑立即断流。 */
    public synchronized void disconnect(String clientId) {
        SseEmitter emitter = emitters.remove(clientId);
        if (emitter == null) return;
        try {
            emitter.complete();
        } catch (Exception ignored) {
        }
        log.info("sync.sse disconnect client={} active={}", clientId, emitters.size());
    }

    /** 排障/测试用。 */
    public int activeCount() {
        return emitters.size();
    }

    @PreDestroy
    public void shutdown() {
        for (SseEmitter emitter : emitters.values()) {
            try {
                emitter.complete();
            } catch (Exception ignored) {
            }
        }
        emitters.clear();
    }

    /**
     * 手动序列化成 JSON 字符串再发：SSE 响应类型是 text/event-stream，
     * 直接发 Map 会找不到匹配的 HttpMessageConverter；字符串由
     * StringHttpMessageConverter 原样写入 data 字段。
     */
    private boolean sendJson(SseEmitter emitter, String clientId,
                             String event, Object payload) {
        try {
            String json = objectMapper.writeValueAsString(payload);
            // 显式 text/plain：确保 StringHttpMessageConverter 能匹配
            // text/event-stream 响应，避免被 Jackson/Map 转换器选择逻辑卡住。
            emitter.send(SseEmitter.event().name(event).data(json, MediaType.TEXT_PLAIN));
            return true;
        } catch (Exception e) {
            emitters.remove(clientId, emitter);
            try {
                emitter.complete();
            } catch (Exception ignored) {
            }
            log.debug("sync.sse send failed client={} event={} err={}",
                    clientId, event, e.toString());
            return false;
        }
    }

    /**
     * 推送信号：只描述「哪个歌单变了、版本到哪」，客户端据此决定拉最新。
     * 不包含 position/playing/deep_list 等权威数据，避免成为第二事实源。
     */
    public record BreakpointSignal(String playlistUuid, long headRev, long historyRev,
                                   String headDevice, String intent) {}
}
