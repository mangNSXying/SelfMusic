package com.selfmusic.backend.sync;

import java.io.IOException;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import java.util.function.Function;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.selfmusic.backend.common.BizException;
import com.selfmusic.backend.common.SourceAddresses;
import com.selfmusic.backend.domain.entity.PlayState;
import com.selfmusic.backend.domain.entity.Playlist;
import com.selfmusic.backend.domain.entity.PlaylistItem;
import com.selfmusic.backend.domain.entity.SongState;
import com.selfmusic.backend.domain.entity.SyncEvent;
import com.selfmusic.backend.domain.entity.SyncSource;
import com.selfmusic.backend.domain.repository.DeviceRepository;
import com.selfmusic.backend.domain.repository.PlayStateRepository;
import com.selfmusic.backend.domain.repository.PlaylistItemRepository;
import com.selfmusic.backend.domain.repository.PlaylistRepository;
import com.selfmusic.backend.domain.repository.SongStateRepository;
import com.selfmusic.backend.domain.repository.SyncEventRepository;
import com.selfmusic.backend.domain.repository.SyncSourceRepository;
import com.selfmusic.backend.domain.service.SettingService;

/**
 * 阶段5 同步引擎服务端（DEVELOPER.md「API 设计」／「播放算法与同步协议」，字段级合并）。
 *
 * 服务端不持有曲库：歌曲身份统一为 {@code source_id + source_ref}
 * （source_id 为客户端源实例 uuid，旧数据/旧客户端记作 {@code legacy:<协议>}），
 * 权重状态落 {@link SongState}，歌单条目/断点自持身份与展示快照。
 *
 * 合并矩阵：
 * - 权重事件（song.*）：事件重算（本类 {@link #applySongEvent}，§7.1 翻版），
 *   非绝对值覆盖，两设备并发点赞按到达序依次重放，不互相抹掉；
 * - 歌单元数据 / 删除墓碑 / 断点当前曲与进度：行级 LWW，以事件 occurred_at vs
 *   行 last_event_at 为准（{@link #eventWins} 纯函数），输方收 correction 回执自行纠正；
 * - 断点深层列表：新客户端带 `deep_added`（纯追加后缀）时执行服务端分支追加，
 *   带 `base_deep_list` 时执行三向列表合并（base/server/device），两端分支都保留；
 *   旧客户端无新字段时仍按整行 LWW 兼容；
 * - 歌单条目：按 seq 到达序重放，后到达胜出，天然收敛；
 * - 仲裁时钟：occurred_at 缺失或打平时，后处理（到达序）胜出；行 last_event_at
 *   为空（首写）恒胜。合并回执用不小于两分支的时钟，避免对端镜像时钟拒收。
 */
@Service
public class SyncService {

    private static final Logger log = LoggerFactory.getLogger(SyncService.class);

    public static final BigDecimal FACTOR_MIN = new BigDecimal("0.5");
    public static final BigDecimal FACTOR_MAX = new BigDecimal("1.5");
    public static final BigDecimal FACTOR_STEP = new BigDecimal("0.1");

    /** 「不喜欢」锁定态的固定权重：低于自动调权下限 {@link #FACTOR_MIN} 的唯一取值，与客户端 {@code SongWeightStore.dislikedFactor} 严格镜像。 */
    public static final BigDecimal DISLIKED_FACTOR = new BigDecimal("0.1");

    public static final int PUSH_EVENT_LIMIT = 500;
    public static final int PULL_EVENT_LIMIT = 2000;

    /** 旧数据/旧客户端协议级身份的 source_id 前缀。 */
    public static final String LEGACY_PREFIX = "legacy:";

    private final SyncEventRepository syncEventRepository;
    private final SongStateRepository songStateRepository;
    private final SyncSourceRepository syncSourceRepository;
    private final PlaylistRepository playlistRepository;
    private final PlaylistItemRepository playlistItemRepository;
    private final PlayStateRepository playStateRepository;
    private final DeviceRepository deviceRepository;
    private final SettingService settingService;
    private final ObjectMapper objectMapper;

    public SyncService(SyncEventRepository syncEventRepository,
                       SongStateRepository songStateRepository,
                       SyncSourceRepository syncSourceRepository,
                       PlaylistRepository playlistRepository,
                       PlaylistItemRepository playlistItemRepository,
                       PlayStateRepository playStateRepository,
                       DeviceRepository deviceRepository,
                       SettingService settingService,
                       ObjectMapper objectMapper) {
        this.syncEventRepository = syncEventRepository;
        this.songStateRepository = songStateRepository;
        this.syncSourceRepository = syncSourceRepository;
        this.playlistRepository = playlistRepository;
        this.playlistItemRepository = playlistItemRepository;
        this.playStateRepository = playStateRepository;
        this.deviceRepository = deviceRepository;
        this.settingService = settingService;
        this.objectMapper = objectMapper;
    }

    /** 协议 v2 的服务器数据代次：DB 重建/迁移后客户端据此重置本地 revision。 */
    public String serverEpoch() {
        String key = "sync.server_epoch";
        String epoch = settingService.get(key, "");
        if (epoch == null || epoch.isBlank()) {
            epoch = UUID.randomUUID().toString();
            settingService.set(key, epoch);
        }
        return epoch;
    }

    /** 静态纯函数（断点快照等）专用的映射器，避免依赖注入实例上下文。 */
    private static final ObjectMapper STATIC_MAPPER = new ObjectMapper();

    // ------------------------------------------------------------------
    // 纯函数：§7.1 权重状态机（无 DB，可单测）
    // ------------------------------------------------------------------

    /** 对服务端权重行应用一个权重事件（§7.1 事件表翻版）。未知类型抛 400。 */
    public static void applySongEvent(SongState song, String type, JsonNode payload) {
        switch (type) {
            case SyncEventTypes.SONG_COMPLETE -> {
                song.setLikeStreak(nvl(song.getLikeStreak()) + 1);
                song.setDislikeStreak(0);
                if (!song.isFrozen() && song.getLikeStreak() >= 3) {
                    song.setWeight(factor(song).add(FACTOR_STEP).min(FACTOR_MAX));
                    song.setLikeStreak(0);
                    song.setDislikeStreak(0);
                }
            }
            case SyncEventTypes.SONG_SKIP -> {
                song.setDislikeStreak(nvl(song.getDislikeStreak()) + 1);
                song.setLikeStreak(0);
                if (!song.isFrozen() && song.getDislikeStreak() >= 3) {
                    song.setWeight(factor(song).subtract(FACTOR_STEP).max(FACTOR_MIN));
                    song.setLikeStreak(0);
                    song.setDislikeStreak(0);
                }
            }
            case SyncEventTypes.SONG_COMPLETE_MANUAL -> {
                // 手动点播自然完播：直接提高一档权重 + 清空双 streak。
                // 「不喜欢」锁定态不动权重（与 complete/skip 一致，锁定最低优先级最高）。
                song.setLikeStreak(0);
                song.setDislikeStreak(0);
                if (!song.isFrozen()) {
                    song.setWeight(factor(song).add(FACTOR_STEP).min(FACTOR_MAX));
                }
            }
            case SyncEventTypes.SONG_LIKED -> {
                song.setFavorite(true);
                song.setWeight(FACTOR_MAX);
                song.setFrozen(false);
            }
            case SyncEventTypes.SONG_UNFAVORITE -> {
                song.setFavorite(false);
                if (!song.isFrozen()) song.setWeight(BigDecimal.ONE);
            }
            case SyncEventTypes.SONG_DISLIKED -> {
                boolean enabled = payload != null && payload.path("enabled").asBoolean(true);
                if (enabled) {
                    // 手动不喜欢 → 固定最低特殊档 0.1（低于自动调权下限，老语义为 FACTOR_MIN）。
                    song.setWeight(DISLIKED_FACTOR);
                    song.setFrozen(true);
                } else {
                    song.setWeight(BigDecimal.ONE);
                    song.setFrozen(false);
                }
            }
            case SyncEventTypes.SONG_RESET -> {
                song.setLikeStreak(0);
                song.setDislikeStreak(0);
                song.setWeight(BigDecimal.ONE);
                song.setFrozen(false);
            }
            default -> throw new BizException(40001, "unknown song event: " + type);
        }
    }

    /**
     * 补录标记：配对前存量补推事件（客户端 backfill）。补录事件“只建行、
     * 不赢现行行”——首配空库照常建；重配旧设备不再冲掉现行数据，判输回
     * correction 自纠。纯函数，可单测。
     */
    public static boolean isBackfill(JsonNode payload) {
        return payload != null && payload.path("backfill").asBoolean(false);
    }

    /**
     * 权重绝对态（song.state，补推/纠偏用）：行级 LWW，判输返回快照纠偏。
     * 载荷缺键保持行上原值；全键齐备时即整行覆盖。
     * 例外：累计播放时长是单调量，取 `max(行值, 载荷值)`（与客户端落库同口径），
     * 旧快照晚到不把累计值写小；「不喜欢」锁定行（frozen）权重恒归一为
     * {@link #DISLIKED_FACTOR}（老语义 0.5 收敛到 0.1）。
     * 补录事件行已存在（last_event_at 非空）即判输：只补没有的行。
     */
    private Object applySongState(PushEvent ev, SongState song) {
        if (isBackfill(ev.payload()) && song.getLastEventAt() != null) return songSnapshot(song);
        if (!eventWins(ev.occurred_at(), song.getLastEventAt())) {
            log.debug("song.state 判输（保留服务端较新行） ref={} device={} occurred={} lastEventAt={}",
                    song.getSourceRef(), ev.device_client_id(), ev.occurred_at(), song.getLastEventAt());
            return songSnapshot(song);
        }
        JsonNode p = ev.payload();
        if (p != null) {
            if (p.has("like_streak")) song.setLikeStreak(p.path("like_streak").asInt(nvl(song.getLikeStreak())));
            if (p.has("dislike_streak")) song.setDislikeStreak(p.path("dislike_streak").asInt(nvl(song.getDislikeStreak())));
            if (p.has("weight")) song.setWeight(BigDecimal.valueOf(p.path("weight").asDouble(factor(song).doubleValue())));
            if (p.has("frozen")) song.setFrozen(p.path("frozen").asBoolean(song.isFrozen()));
            if (p.has("is_favorite")) song.setFavorite(p.path("is_favorite").asBoolean(song.isFavorite()));
            // 累计播放时长（秒）：单调合并，不随 LWW 倒退。
            if (p.has("play_sec")) song.setPlaySec(mergePlaySec(song.getPlaySec(), p.path("play_sec").asInt()));
        }
        // 「不喜欢」锁定行权重归一：历史语义写的是自动调权下限 0.5，现固定最低档
        // DISLIKED_FACTOR——老行/异常快照随任意一次绝对态推送自愈。
        song.setWeight(normalizeFrozenWeight(song.isFrozen(), factor(song)));
        song.setLastEventAt(ev.occurred_at());
        songStateRepository.save(song);
        return null;
    }

    /**
     * 累计播放时长合并：取 `max(行值, 本次值)`，null 按 0 处理。纯函数，可单测。
     */
    public static int mergePlaySec(Integer current, int incoming) {
        return Math.max(current == null ? 0 : current, incoming);
    }

    /**
     * LWW 仲裁：当前事件是否胜过行上次应用的事件。
     * lastEventAt 为空=首写恒胜；occurred 缺失恒输；
     * occurred 更大胜出，打平则后处理（到达序）胜出，保证确定性收敛。
     */
    public static boolean eventWins(LocalDateTime occurred, LocalDateTime lastEventAt) {
        if (lastEventAt == null) return true;
        if (occurred == null) return false;
        return !occurred.isBefore(lastEventAt);
    }

    /**
     * 播放头 HLC：`wallMillis-counter-deviceId`，按字典序比较（wall, counter, device）。
     *
     * <p>HLC 不依赖客户端裸墙钟做「谁更新」的唯一判断：客户端用服务端
     * server_time 做时钟校准，同一毫秒内递增 counter；deviceId 兜底保证全序。</p>
     */
    public record Hlc(long wallMs, int counter, String deviceId) implements Comparable<Hlc> {
        public static Hlc parse(String raw, String fallbackDevice) {
            if (raw == null || raw.isBlank()) return null;
            String[] parts = raw.split("-", 3);
            if (parts.length < 2) return null;
            try {
                long wall = Long.parseLong(parts[0]);
                int counter = Integer.parseInt(parts[1]);
                String device = parts.length >= 3 && !parts[2].isBlank()
                        ? parts[2] : fallbackDevice;
                if (device == null || device.isBlank()) return null;
                return new Hlc(wall, counter, device);
            } catch (NumberFormatException e) {
                return null;
            }
        }

        public static Hlc fromOccurred(LocalDateTime occurred, String device) {
            if (occurred == null || device == null || device.isBlank()) return null;
            long wall = occurred.toInstant(java.time.ZoneOffset.UTC).toEpochMilli();
            return new Hlc(wall, 0, device);
        }

        public String encode() {
            return wallMs + "-" + counter + "-" + deviceId;
        }

        @Override
        public int compareTo(Hlc o) {
            int c = Long.compare(wallMs, o.wallMs);
            if (c != 0) return c;
            c = Integer.compare(counter, o.counter);
            if (c != 0) return c;
            return deviceId.compareTo(o.deviceId);
        }
    }

    /** 事件里的操作时钟：优先 op_clock，缺失回退 occurred_at（旧客户端/测试）。 */
    public static Hlc eventClock(PushEvent ev, JsonNode p) {
        String raw = p == null ? null : p.path("op_clock").asText(null);
        Hlc hlc = Hlc.parse(raw, ev.device_client_id());
        return hlc != null ? hlc : Hlc.fromOccurred(ev.occurred_at(), ev.device_client_id());
    }

    /**
     * 自我回灌过滤：本设备产生的事件在 pull 收集实体时跳过（cursor 照常推进）。
     * push 已强制 device_client_id == authClientId，故比对可靠；历史/缺失设备号保守保留。
     */
    public static boolean isSelfEvent(String authClientId, SyncEvent e) {
        if (authClientId == null || authClientId.isBlank() || e == null) return false;
        return authClientId.equals(e.getDeviceClientId());
    }

    // ------------------------------------------------------------------
    // push：批量上推（幂等 + 重放 + correction 回执）
    // ------------------------------------------------------------------

    @Transactional
    public Map<String, Object> push(String authClientId, List<PushEvent> events) {
        List<String> applied = new ArrayList<>();
        List<String> duplicates = new ArrayList<>();
        List<Map<String, String>> rejected = new ArrayList<>();
        Map<String, Object> corrections = new LinkedHashMap<>();
        Map<String, Object> merged = new LinkedHashMap<>();
        Map<String, Object> breakpoints = new LinkedHashMap<>();
        if (events == null || events.isEmpty()) {
            return pushResult(syncEventRepository.maxSeq(), applied, duplicates, rejected,
                    corrections, merged, breakpoints);
        }
        if (events.size() > PUSH_EVENT_LIMIT) {
            throw new BizException(40001, "too many events (max " + PUSH_EVENT_LIMIT + ")");
        }
        log.info("sync.push 开始 device={} events={}", authClientId, events.size());

        // 同批内排序：playlist.create 优先（条目/断点依赖歌单先存在），其余按 occurred_at
        List<PushEvent> sorted = events.stream()
                .sorted(Comparator.comparing((PushEvent e) -> !SyncEventTypes.PLAYLIST_CREATE.equals(e.type()))
                        .thenComparing(PushEvent::occurred_at, Comparator.nullsLast(Comparator.naturalOrder())))
                .toList();

        for (PushEvent ev : sorted) {
            if (ev.event_uuid() == null || ev.event_uuid().isBlank()
                    || ev.type() == null || ev.type().isBlank()) {
                rejected.add(reject(String.valueOf(ev.event_uuid()), "invalid event"));
                log.warn("sync.push 拒绝 device={} uuid={} reason=invalid event",
                        authClientId, ev.event_uuid());
                continue;
            }
            if (!authClientId.equals(ev.device_client_id())) {
                rejected.add(reject(ev.event_uuid(), "device_mismatch"));
                log.warn("sync.push 拒绝 device={} uuid={} reason=device_mismatch(事件设备={})",
                        authClientId, ev.event_uuid(), ev.device_client_id());
                continue;
            }
            if (syncEventRepository.findByEventUuid(ev.event_uuid()).isPresent()) {
                duplicates.add(ev.event_uuid());
                collectV2BreakpointSnapshot(ev, breakpoints);
                continue;
            }
            try {
                ApplyOutcome outcome = applyEvent(ev);
                collectV2BreakpointSnapshot(ev, breakpoints);
                SyncEvent row = new SyncEvent();
                row.setEventUuid(ev.event_uuid());
                row.setDeviceClientId(ev.device_client_id());
                row.setType(ev.type());
                row.setPayload(ev.payload() == null ? null : ev.payload().toString());
                row.setOccurredAt(ev.occurred_at());
                // 压缩去重锚点：同实体旧事件可在设备水位以下被回收。
                row.setEntityKey(entityKeyOf(ev.type(), ev.payload()));
                syncEventRepository.save(row);
                applied.add(ev.event_uuid());
                if (outcome.correction() != null) {
                    corrections.put(ev.event_uuid(), outcome.correction());
                    log.info("sync.push 判输回执 device={} uuid={} type={}",
                            authClientId, ev.event_uuid(), ev.type());
                }
                if (outcome.merged() != null) {
                    merged.put(ev.event_uuid(), outcome.merged());
                    log.info("sync.push 合并回执 device={} uuid={} type={}",
                            authClientId, ev.event_uuid(), ev.type());
                }
            } catch (BizException be) {
                rejected.add(reject(ev.event_uuid(), be.getMessage()));
                log.warn("sync.push 拒绝 device={} uuid={} type={} reason={}",
                        authClientId, ev.event_uuid(), ev.type(), be.getMessage());
            }
        }
        touchDevice(authClientId, null);
        Map<String, Object> result = pushResult(syncEventRepository.maxSeq(), applied,
                duplicates, rejected, corrections, merged, breakpoints);
        // 汇总行（与客户端 push.batch/push.ack 时间线对齐用）。
        log.info("sync.push 完成 device={} applied={} duplicates={} rejected={} corrections={} merged={} breakpoints={} cursor={}",
                authClientId, applied.size(), duplicates.size(), rejected.size(),
                corrections.size(), merged.size(), breakpoints.size(), result.get("cursor"));
        return result;
    }

    /**
     * v2 push 回执：按 playlist 维度回权威 head+history 快照（不是 event_uuid）。
     * 同一批多事件同一歌单时以最后一次应用结果为准。
     */
    private void collectV2BreakpointSnapshot(PushEvent ev, Map<String, Object> out) {
        if (!SyncEventTypes.BREAKPOINT_SET.equals(ev.type()) || ev.payload() == null) return;
        JsonNode p = ev.payload();
        if (p.path("protocol").asInt(0) < 2) return;
        String uuid = p.path("playlist_uuid").asText(null);
        if (uuid == null || uuid.isBlank()) return;
        Playlist pl = playlistRepository.findByClientUuid(uuid).orElse(null);
        if (pl == null) return;
        PlayState st = playStateRepository.findById(pl.getId()).orElse(null);
        if (st == null) return;
        out.put(uuid, playstateSnapshot(st, uuid));
    }

    /** 单事件应用结果：correction=判输快照，merged=深层列表合并后的快照。 */
    private record ApplyOutcome(Object correction, Object merged) {
        static ApplyOutcome none() { return new ApplyOutcome(null, null); }
        static ApplyOutcome correction(Object snap) { return new ApplyOutcome(snap, null); }
        static ApplyOutcome merged(Object snap) { return new ApplyOutcome(null, snap); }
    }

    /**
     * 应用单个已去重事件。correction 快照进 push 回执 corrections；
     * merged 快照进独立 merged 通道（即使 device_client_id 是本机也要强制套用）。
     */
    private ApplyOutcome applyEvent(PushEvent ev) {
        JsonNode p = ev.payload();
        return switch (typeGroup(ev.type())) {
            case "song" -> {
                SongState song = stateOf(p, true);
                if (SyncEventTypes.SONG_STATE.equals(ev.type())) {
                    yield ApplyOutcome.correction(applySongState(ev, song));
                }
                applySongEvent(song, ev.type(), p);
                songStateRepository.save(song);
                yield ApplyOutcome.none();
            }
            case "source_meta" -> ApplyOutcome.correction(applySourceMeta(ev));
            case "playlist_meta" -> ApplyOutcome.correction(applyPlaylistMeta(ev));
            case "playlist_item" -> {
                applyPlaylistItem(ev);
                yield ApplyOutcome.none();
            }
            case "breakpoint" -> applyBreakpoint(ev);
            default -> throw new BizException(40001, "unknown event group: " + ev.type());
        };
    }

    private static String typeGroup(String type) {
        if (type.startsWith("song.")) return "song";
        if (type.startsWith("source.")) return "source_meta";
        if (type.equals(SyncEventTypes.PLAYLIST_CREATE)
                || type.equals(SyncEventTypes.PLAYLIST_UPDATE)
                || type.equals(SyncEventTypes.PLAYLIST_DELETE)) return "playlist_meta";
        if (type.startsWith("playlist.item_")) return "playlist_item";
        if (type.equals(SyncEventTypes.BREAKPOINT_SET)) return "breakpoint";
        return "?";
    }

    // ------------------------------------------------------------------
    // 歌曲身份解析（source_id + source_ref）
    // ------------------------------------------------------------------

    /**
     * 事件载荷中的源实例身份：优先 `source_id`（客户端 sources.client_uuid）；
     * 缺省时按协议名回退 {@code legacy:<协议>}（旧客户端/旧数据）；
     * `source` 为空或 `'server'` 占位（无实例信息的旧快照行）返回 null。
     */
    static String sourceIdOf(JsonNode p) {
        if (p == null) return null;
        String sid = p.path("source_id").asText(null);
        if (sid != null && !sid.isBlank()) return sid;
        String source = p.path("source").asText(null);
        if (source != null && !source.isBlank() && !"server".equals(source)) {
            return LEGACY_PREFIX + source;
        }
        return null;
    }

    private static String protocolOf(JsonNode p) {
        if (p == null) return null;
        String source = p.path("source").asText(null);
        if (source == null || source.isBlank() || "server".equals(source)) return null;
        return source;
    }

    private static String refOf(JsonNode p) {
        return p == null ? null : p.path("source_ref").asText(null);
    }

    /**
     * 事件实体键（事件日志压缩的去重锚点，纯函数）：
     * `song|source_id|ref` / `source|uuid` / `playlist|uuid` / `breakpoint|uuid`。
     * 无法识别的载荷返回 null——这类行不参与压缩（保守保留，永不误删）。
     */
    public static String entityKeyOf(String type, JsonNode p) {
        if (type == null || p == null) return null;
        if (type.startsWith("song.")) {
            String ref = refOf(p);
            if (ref == null || ref.isBlank()) return null;
            String sid = sourceIdOf(p);
            return "song|" + (sid == null ? "" : sid) + "|" + ref;
        }
        if (type.startsWith("source.")) {
            String uuid = p.path("client_uuid").asText(null);
            return (uuid == null || uuid.isBlank()) ? null : "source|" + uuid;
        }
        if (type.startsWith("playlist.")) {
            String uuid = p.path("client_uuid").asText(null);
            if (uuid == null || uuid.isBlank()) {
                uuid = p.path("playlist_uuid").asText(null);
            }
            return (uuid == null || uuid.isBlank()) ? null : "playlist|" + uuid;
        }
        if (SyncEventTypes.BREAKPOINT_SET.equals(type)) {
            String uuid = p.path("playlist_uuid").asText(null);
            return (uuid == null || uuid.isBlank()) ? null : "breakpoint|" + uuid;
        }
        return null;
    }

    /**
     * 解析事件中的歌曲权重行：按 (source_id, source_ref) 唯一键；
     * 无 source_id 的旧占位数据按 source_ref 全源兜底。
     * [provision] 为真时缺行新建（承载权重/收藏）；为假时（pull 身份收集）
     * 找不到抛 404，由调用方跳过（已删歌曲不复活）。
     */
    private SongState stateOf(JsonNode p, boolean provision) {
        String ref = refOf(p);
        if (ref == null || ref.isBlank()) {
            throw new BizException(40001, "source_ref required");
        }
        String sid = sourceIdOf(p);
        if (sid == null) {
            return songStateRepository.findFirstBySourceRef(ref)
                    .orElseThrow(() -> new BizException(40402, "song not found: " + ref));
        }
        Optional<SongState> found = songStateRepository.findBySourceIdAndSourceRef(sid, ref);
        if (found.isPresent()) return found.get();
        // 旧协议级身份懒迁移：首台升级设备重新上报时，把 legacy:<协议> 行收编到源实例 uuid。
        String protocol = protocolOf(p);
        if (protocol != null) {
            Optional<SongState> legacy = songStateRepository
                    .findBySourceIdAndSourceRef(LEGACY_PREFIX + protocol, ref);
            if (legacy.isPresent()) {
                SongState row = legacy.get();
                row.setSourceId(sid);
                row.setSource(protocol);
                return songStateRepository.save(row);
            }
        }
        if (!provision) {
            throw new BizException(40402, "song not found: " + sid + "/" + ref);
        }
        SongState created = new SongState();
        created.setSourceId(sid);
        created.setSource(protocolOf(p));
        created.setSourceRef(ref);
        created.setTitle(shadowTitle(p, ref));
        return songStateRepository.save(created);
    }

    /**
     * 权重行标题：事件载荷 title 优先（去空白），否则取 ref 最后一段
     * （去末尾斜杠 + URL 解码），再兜底 ref 全串。纯函数，可单测。
     */
    static String shadowTitle(JsonNode p, String ref) {
        if (p != null && p.has("title") && !p.path("title").isNull()) {
            String t = p.path("title").asText("").trim();
            if (!t.isEmpty()) return t;
        }
        String s = ref == null ? "" : ref;
        while (s.endsWith("/") && s.length() > 1) s = s.substring(0, s.length() - 1);
        int cut = Math.max(s.lastIndexOf('/'), s.lastIndexOf('\\'));
        String tail = cut >= 0 ? s.substring(cut + 1) : s;
        try {
            tail = java.net.URLDecoder.decode(tail, java.nio.charset.StandardCharsets.UTF_8);
        } catch (IllegalArgumentException ignored) {
            // 非法百分号编码：用解码前原文
        }
        tail = tail.trim();
        return tail.isEmpty() ? s : tail;
    }

    /**
     * 播放源元数据（create/update/delete）：LWW + 去重（kind+address）。
     * 名称不参与去重；配置不含密码。若事件 uuid 与既有同址源不同，回 correction
     * （携带权威 uuid），事件方据此重绑本地源标识。
     * 补录 create 只建行、不赢现行行（同 uuid 或同址行已存在即判输回现行快照）。
     */
    private Object applySourceMeta(PushEvent ev) {
        JsonNode p = ev.payload();
        String uuid = p == null ? null : p.path("client_uuid").asText(null);
        if (uuid == null || uuid.isBlank()) throw new BizException(40001, "client_uuid required");
        String kind = textOr(p, "kind", null);
        if (kind == null || kind.isBlank()) throw new BizException(40001, "kind required");
        String address = textOr(p, "address", null);
        if (address == null || address.isBlank()) throw new BizException(40001, "address required");
        // 写入边界归一化（WebDAV 缺 scheme 补 https）：旧客户端/历史行曾落原始
        // 无 scheme 地址，否则去重键与转码强校验都会失配。
        address = SourceAddresses.normalize(kind, address);

        if (SyncEventTypes.SOURCE_DELETE.equals(ev.type())) {
            SyncSource row = syncSourceRepository.findByClientUuid(uuid).orElse(null);
            if (row == null || row.isDeleted()) return null; // 重复删除：幂等 no-op
            if (!eventWins(ev.occurred_at(), row.getLastEventAt())) {
                log.debug("source.delete 判输（保留服务端较新行） uuid={} device={} occurred={} lastEventAt={}",
                        uuid, ev.device_client_id(), ev.occurred_at(), row.getLastEventAt());
                return sourceSnapshot(row);
            }
            row.setDeleted(true);
            row.setLastEventAt(ev.occurred_at());
            row.setSyncVer(nvlLong(row.getSyncVer()) + 1);
            syncSourceRepository.save(row);
            return null;
        }

        final boolean backfill = isBackfill(p)
                && SyncEventTypes.SOURCE_CREATE.equals(ev.type());
        SyncSource row = syncSourceRepository.findByClientUuid(uuid).orElse(null);
        if (row == null) {
            SyncSource same = syncSourceRepository.findByKindAndAddress(kind, address).orElse(null);
            if (same != null) {
                // 同址去重合并：采纳既有权威 uuid，事件方收 correction 重绑。
                // 补录只建行：同址行已存在即判输，不碰现行 name/config。
                if (backfill || !eventWins(ev.occurred_at(), same.getLastEventAt())) return sourceSnapshot(same);
                applySourceFields(same, p);
                same.setLastEventAt(ev.occurred_at());
                same.setSyncVer(nvlLong(same.getSyncVer()) + 1);
                syncSourceRepository.save(same);
                return sourceSnapshot(same);
            }
            SyncSource created = new SyncSource();
            created.setClientUuid(uuid);
            created.setKind(kind);
            created.setAddress(address);
            created.setDeleted(false);
            created.setName(textOr(p, "name", null));
            applySourceFields(created, p);
            created.setLastEventAt(ev.occurred_at());
            created.setSyncVer(1L);
            syncSourceRepository.save(created);
            return null;
        }
        // 补录 create 撞到同 uuid 行：只建行，已存在即判输回现行快照。
        if (backfill) return sourceSnapshot(row);
        if (!eventWins(ev.occurred_at(), row.getLastEventAt())) {
            log.debug("source.update 判输（保留服务端较新行） uuid={} device={} occurred={} lastEventAt={}",
                    uuid, ev.device_client_id(), ev.occurred_at(), row.getLastEventAt());
            return sourceSnapshot(row);
        }
        // 地址可改：若与其它既有同址行冲突则合并（同址即同源，回 correction 重绑）。
        if (!address.equals(row.getAddress())) {
            SyncSource conflict = syncSourceRepository
                    .findByKindAndAddress(kind, address).orElse(null);
            if (conflict != null && !conflict.getClientUuid().equals(row.getClientUuid())) {
                row.setDeleted(true);
                row.setLastEventAt(ev.occurred_at());
                row.setSyncVer(nvlLong(row.getSyncVer()) + 1);
                syncSourceRepository.save(row);
                return sourceSnapshot(conflict);
            }
            row.setAddress(address);
        }
        applySourceFields(row, p);
        row.setLastEventAt(ev.occurred_at());
        row.setSyncVer(nvlLong(row.getSyncVer()) + 1);
        syncSourceRepository.save(row);
        return null;
    }

    private static void applySourceFields(SyncSource row, JsonNode p) {
        if (p == null) return;
        if (p.has("name") && !p.path("name").isNull()) row.setName(p.path("name").asText(null));
        if (p.has("config") && !p.path("config").isNull()) {
            row.setConfigJson(p.path("config").isObject()
                    ? p.path("config").toString() : p.path("config").asText(null));
        }
        if (p.has("enabled")) row.setEnabled(p.path("enabled").asBoolean(true));
    }

    private Playlist playlistOf(JsonNode p) {
        String uuid = p == null ? null : p.path("client_uuid").asText(null);
        if (uuid == null || uuid.isBlank())
            uuid = p == null ? null : p.path("playlist_uuid").asText(null);
        if (uuid == null || uuid.isBlank()) throw new BizException(40001, "playlist uuid required");
        String id = uuid;
        return playlistRepository.findByClientUuid(id)
                .orElseThrow(() -> new BizException(40402, "playlist not found: " + id));
    }

    private Object applyPlaylistMeta(PushEvent ev) {
        JsonNode p = ev.payload();
        if (SyncEventTypes.PLAYLIST_CREATE.equals(ev.type())) {
            String uuid = p == null ? null : p.path("client_uuid").asText(null);
            if (uuid == null || uuid.isBlank()) throw new BizException(40001, "client_uuid required");
            // 幂等重试：同 uuid 已存在则按 update 走 LWW；
            // 补录 create 只建行，已存在即判输回现行快照（不覆名）。
            if (playlistRepository.findByClientUuid(uuid).isPresent()) {
                Playlist existing = playlistRepository.findByClientUuid(uuid).orElseThrow();
                if (isBackfill(p)) return playlistSnapshot(existing);
                return applyPlaylistUpdate(ev, existing);
            }
            Playlist pl = new Playlist();
            pl.setClientUuid(uuid);
            pl.setName(textOr(p, "name", "新建歌单"));
            pl.setDescription(textOr(p, "description", null));
            pl.setMode(parseMode(textOr(p, "mode", null)));
            pl.setDeleted(false);
            pl.setSyncVer(1L);
            pl.setLastEventAt(ev.occurred_at());
            playlistRepository.save(pl);
            applyCreateItems(pl, p);
            return null;
        }
        Playlist pl = playlistOf(p);
        if (SyncEventTypes.PLAYLIST_DELETE.equals(ev.type())) {
            if (pl.isDeleted()) return null; // 重复删除：幂等 no-op
            if (!eventWins(ev.occurred_at(), pl.getLastEventAt())) {
                log.debug("playlist.delete 判输（保留服务端较新行） uuid={} device={} occurred={} lastEventAt={}",
                        pl.getClientUuid(), ev.device_client_id(), ev.occurred_at(), pl.getLastEventAt());
                return playlistSnapshot(pl);
            }
            pl.setDeleted(true);
            pl.setLastEventAt(ev.occurred_at());
            pl.setSyncVer(nvlLong(pl.getSyncVer()) + 1);
            playlistRepository.save(pl);
            return null;
        }
        return applyPlaylistUpdate(ev, pl);
    }

    private Object applyPlaylistUpdate(PushEvent ev, Playlist pl) {
        if (!eventWins(ev.occurred_at(), pl.getLastEventAt())) {
            log.debug("playlist.update 判输（保留服务端较新行） uuid={} device={} occurred={} lastEventAt={}",
                    pl.getClientUuid(), ev.device_client_id(), ev.occurred_at(), pl.getLastEventAt());
            return playlistSnapshot(pl);
        }
        JsonNode p = ev.payload();
        if (p != null && p.has("name")) pl.setName(p.path("name").asText(pl.getName()));
        if (p != null && p.has("description")) {
            pl.setDescription(p.path("description").isNull() ? null : p.path("description").asText());
        }
        if (p != null && p.has("mode")) pl.setMode(parseMode(p.path("mode").asText(null)));
        pl.setLastEventAt(ev.occurred_at());
        pl.setSyncVer(nvlLong(pl.getSyncVer()) + 1);
        playlistRepository.save(pl);
        return null;
    }

    private void applyCreateItems(Playlist pl, JsonNode p) {
        if (p == null || !p.has("items") || !p.path("items").isArray()) return;
        for (JsonNode it : p.path("items")) {
            String ref = refOf(it);
            String sid = sourceIdOf(it);
            if (ref == null || ref.isBlank() || sid == null) continue;
            PlaylistItem item = new PlaylistItem();
            item.setPlaylist(pl);
            applyItemSnapshot(item, it, sid, ref);
            item.setSortOrder(it.path("sort_order").asInt(0));
            playlistItemRepository.save(item);
        }
    }

    private void applyPlaylistItem(PushEvent ev) {
        JsonNode p = ev.payload();
        Playlist pl = playlistOf(p);
        if (pl.isDeleted()) throw new BizException(40001, "playlist_deleted");
        String t = ev.type();
        String ref = refOf(p);
        String sid = sourceIdOf(p);
        if (SyncEventTypes.PLAYLIST_ITEM_REMOVE.equals(t)) {
            // 移除幂等：服务端无此条目 = 早已收敛，直接 no-op（不建行）。
            if (sid != null && ref != null && !ref.isBlank()) {
                playlistItemRepository.deleteByPlaylistIdAndSourceIdAndSourceRef(pl.getId(), sid, ref);
                String protocol = protocolOf(p);
                if (protocol != null) {
                    playlistItemRepository.deleteByPlaylistIdAndSourceIdAndSourceRef(
                            pl.getId(), LEGACY_PREFIX + protocol, ref);
                }
            }
        } else {
            if (sid == null || ref == null || ref.isBlank()) {
                throw new BizException(40001, "source_id and source_ref required");
            }
            PlaylistItem item = playlistItemRepository
                    .findByPlaylistIdAndSourceIdAndSourceRef(pl.getId(), sid, ref)
                    .orElse(null);
            String protocol = protocolOf(p);
            if (item == null && protocol != null) {
                // 旧协议级条目懒迁移到源实例身份。
                item = playlistItemRepository
                        .findByPlaylistIdAndSourceIdAndSourceRef(
                                pl.getId(), LEGACY_PREFIX + protocol, ref)
                        .orElse(null);
            }
            // 补录 item_add 只建行：条目已存在不覆快照（不复活已删条目、不覆新标题），
            // 直接 no-op（版本号亦不推进）。
            if (item != null && isBackfill(p)) return;
            if (item == null) {
                item = new PlaylistItem();
                item.setPlaylist(pl);
            }
            applyItemSnapshot(item, p, sid, ref);
            if (p != null && p.has("sort_order")) item.setSortOrder(p.path("sort_order").asInt(0));
            playlistItemRepository.save(item);
        }
        pl.setSyncVer(nvlLong(pl.getSyncVer()) + 1);
        playlistRepository.save(pl);
    }

    /** 条目身份与展示快照：载荷缺省字段不覆盖已有快照。 */
    private static void applyItemSnapshot(PlaylistItem item, JsonNode p, String sid, String ref) {
        item.setSourceId(sid);
        item.setSourceRef(ref);
        if (p != null && p.has("source") && !p.path("source").isNull()) {
            item.setSource(p.path("source").asText(null));
        }
        if (p != null && p.has("title") && !p.path("title").isNull()) {
            item.setTitle(p.path("title").asText(null));
        }
        if (p != null && p.has("artist") && !p.path("artist").isNull()) {
            item.setArtist(p.path("artist").asText(null));
        }
        if (p != null && p.has("album") && !p.path("album").isNull()) {
            item.setAlbum(p.path("album").asText(null));
        }
        if (p != null && p.has("duration") && p.path("duration").canConvertToInt()) {
            item.setDuration(p.path("duration").asInt());
        }
    }

    private ApplyOutcome applyBreakpoint(PushEvent ev) {
        JsonNode p = ev.payload();
        Playlist pl = playlistOf(p);
        PlayState st = playStateRepository.findById(pl.getId()).orElseGet(() -> {
            PlayState ns = new PlayState();
            ns.setPlaylistId(pl.getId());
            return ns;
        });
        int incomingPos = p == null ? 0 : p.path("position_ms").asInt(0);
        String ref = refOf(p);
        if (ref == null || ref.isBlank()) throw new BizException(40001, "source_ref required");
        int capacity = playlistCapacity(pl);

        boolean hasBase = p != null && p.has("base_deep_list")
                && p.path("base_deep_list").isArray();
        boolean hasAdded = p != null && p.has("deep_added")
                && p.path("deep_added").isArray();
        boolean hasFull = p != null && p.has("deep_list")
                && p.path("deep_list").isArray();
        List<JsonNode> incoming = hasFull ? deepNodes(p.path("deep_list")) : null;

        // v2：head 与 history 分开仲裁；head 输了也照常合并历史。
        if (p != null && p.path("protocol").asInt(0) >= 2) {
            return applyBreakpointV2(ev, p, pl, st, capacity, hasBase, hasAdded, incoming);
        }

        // 非追加操作（上一首/替换末尾/清空）无法从快照 diff 精确还原：
        // 客户端带上次确认的 base 走三向合并，两端分支都保留。
        if (hasBase) {
            List<JsonNode> base = deepNodes(p.path("base_deep_list"));
            List<JsonNode> server = parseDeepNodes(st.getDeepListJson());
            // 新协议必须带全量 deep_list；缺失时按“不改历史”处理，避免误清空。
            List<JsonNode> device = incoming == null ? server : incoming;
            List<JsonNode> merged = mergeDeepLists(base, server, device, capacity);
            boolean changedFromIncoming = incoming != null
                    && !sameDeepKeys(merged, incoming);
            st.setDeepListJson(deepJson(merged));
            applyBreakpointCurrent(st, ev, p, ref);
            st.setLastEventAt(changedFromIncoming
                    ? mergeClock(st.getLastEventAt(), ev.occurred_at())
                    : acceptClock(st.getLastEventAt(), eventTime(ev)));
            playStateRepository.save(st);
            log.info("sync.breakpoint 三向合并 playlist={} device={} base={} server={} deviceList={} merged={} changed={} clock={}",
                    pl.getClientUuid(), ev.device_client_id(), base.size(),
                    server.size(), device.size(), merged.size(), changedFromIncoming,
                    st.getLastEventAt());
            return changedFromIncoming
                    ? ApplyOutcome.merged(playstateSnapshot(st, pl.getClientUuid()))
                    : ApplyOutcome.none();
        }

        if (hasAdded) {
            List<JsonNode> added = deepNodes(p.path("deep_added"));
            String serverRaw = st.getDeepListJson();
            List<JsonNode> server = parseDeepNodes(serverRaw);
            boolean serverMissing = serverRaw == null || serverRaw.isBlank();

            // 空后缀 = 仅位置更新：不覆盖服务端深层列表，仍按 LWW 仲裁当前曲/进度。
            if (added.isEmpty()) {
                if (!eventWins(ev.occurred_at(), st.getLastEventAt())) {
                    log.info("sync.breakpoint 位置判输（保留服务端断点） playlist={} 来件[device={} occurred={} pos={}ms] 现行[lastEventAt={} device={} pos={}ms]",
                            pl.getClientUuid(), ev.device_client_id(), ev.occurred_at(),
                            incomingPos, st.getLastEventAt(), st.getDeviceClientId(),
                            st.getPositionMs());
                    return ApplyOutcome.correction(playstateSnapshot(st, pl.getClientUuid()));
                }
                // 服务端从未有过深层列表（旧行/首写）→ 用本次全量做种子。
                if (serverMissing && incoming != null) {
                    st.setDeepListJson(deepJson(dedupeDeep(incoming, capacity)));
                }
                applyBreakpointCurrent(st, ev, p, ref);
                st.setLastEventAt(ev.occurred_at());
                playStateRepository.save(st);
                List<JsonNode> current = parseDeepNodes(st.getDeepListJson());
                // 服务端历史与设备全量不同（例如对端已合并出另一分支）时也回
                // merged 快照：设备只更新历史、不 seek，下一轮就能看到完整分支。
                boolean historyDiff = incoming != null
                        && !sameDeepKeys(current, incoming);
                log.info("sync.breakpoint 位置接受 playlist={} device={} occurred={} pos={}ms deep={} histDiff={}",
                        pl.getClientUuid(), ev.device_client_id(), ev.occurred_at(),
                        incomingPos, current.size(), historyDiff);
                return historyDiff
                        ? ApplyOutcome.merged(playstateSnapshot(st, pl.getClientUuid()))
                        : ApplyOutcome.none();
            }

            // 纯追加：服务端当前分支 + 设备新增后缀。服务端无历史时用设备全量
            // 兜底（新库/旧行没有可追加的 base）。
            List<JsonNode> merged = (serverMissing && incoming != null)
                    ? dedupeDeep(incoming, capacity)
                    : appendDeepAdded(server, added, capacity);
            boolean changedFromIncoming = incoming == null
                    || !sameDeepKeys(merged, incoming);
            st.setDeepListJson(deepJson(merged));
            applyBreakpointCurrent(st, ev, p, ref);
            st.setLastEventAt(changedFromIncoming
                    ? mergeClock(st.getLastEventAt(), ev.occurred_at())
                    : acceptClock(st.getLastEventAt(), eventTime(ev)));
            playStateRepository.save(st);
            log.info("sync.breakpoint 追加合并 playlist={} device={} server={} added={} merged={} changed={} clock={}",
                    pl.getClientUuid(), ev.device_client_id(), server.size(),
                    added.size(), merged.size(), changedFromIncoming,
                    st.getLastEventAt());
            return changedFromIncoming
                    ? ApplyOutcome.merged(playstateSnapshot(st, pl.getClientUuid()))
                    : ApplyOutcome.none();
        }

        // 旧客户端/旧协议：无 base/added 字段，整行 LWW（保持向后兼容）。
        if (!eventWins(ev.occurred_at(), st.getLastEventAt())) {
            log.info("sync.breakpoint 判输（保留服务端断点） playlist={} 来件[device={} occurred={} pos={}ms] 现行[lastEventAt={} device={} pos={}ms]",
                    pl.getClientUuid(), ev.device_client_id(), ev.occurred_at(), incomingPos,
                    st.getLastEventAt(), st.getDeviceClientId(), st.getPositionMs());
            return ApplyOutcome.correction(playstateSnapshot(st, pl.getClientUuid()));
        }
        log.info("sync.breakpoint 接受（旧协议覆盖现行） playlist={} 来件[device={} occurred={} pos={}ms] 现行[lastEventAt={} device={} pos={}ms]",
                pl.getClientUuid(), ev.device_client_id(), ev.occurred_at(), incomingPos,
                st.getLastEventAt(), st.getDeviceClientId(), st.getPositionMs());
        applyBreakpointCurrent(st, ev, p, ref);
        // 旧协议没有合并语义：深层列表原样保存（空/缺失置空）。
        st.setDeepListJson(hasFull ? p.path("deep_list").toString() : null);
        st.setLastEventAt(ev.occurred_at());
        playStateRepository.save(st);
        return ApplyOutcome.none();
    }

    /**
     * 协议 v2 断点：历史三向合并与 head HLC 仲裁独立执行。
     *
     * <p>head 的接受规则：</p>
     * <ul>
     *   <li>{@code play_track}：新的真实起播/切歌，op_clock 更大即赢；</li>
     *   <li>{@code pause/resume/seek}：必须作用于当前 session（session 缺失时按
     *       source_ref 匹配），op_clock 更大才赢；</li>
     *   <li>{@code progress}：只接受当前 head 设备、当前 session 的进度心跳，
     *       不改变「谁是最新操作」；</li>
     *   <li>{@code history_only}：绝不改 head，只合并历史。</li>
     * </ul>
     *
     * <p>历史即使 head 输了也照常合并：离线设备听过的歌不能因为当前曲输掉而丢。</p>
     */
    private ApplyOutcome applyBreakpointV2(PushEvent ev, JsonNode p, Playlist pl,
                                           PlayState st, int capacity,
                                           boolean hasBase, boolean hasAdded,
                                           List<JsonNode> incoming) {
        List<JsonNode> server = parseDeepNodes(st.getDeepListJson());
        List<JsonNode> mergedHistory = server;
        boolean historyChanged = false;

        if (hasBase) {
            List<JsonNode> base = deepNodes(p.path("base_deep_list"));
            List<JsonNode> device = incoming == null ? server : incoming;
            mergedHistory = mergeDeepLists(base, server, device, capacity);
            historyChanged = !sameDeepKeys(mergedHistory, server);
        } else if (hasAdded) {
            List<JsonNode> added = deepNodes(p.path("deep_added"));
            // 新库/旧行无历史：用本次全量做种子；否则服务端分支 + 设备后缀。
            mergedHistory = (server.isEmpty() && incoming != null)
                    ? dedupeDeep(incoming, capacity)
                    : appendDeepAdded(server, added, capacity);
            historyChanged = !sameDeepKeys(mergedHistory, server);
        } else if (incoming != null) {
            // 没带 base 的 v2 客户端：以服务端为 base 做三向合并，避免整表覆盖；
            // 两边都改时服务端分支在前、设备分支在后。
            mergedHistory = mergeDeepLists(server, server, incoming, capacity);
            historyChanged = !sameDeepKeys(mergedHistory, server);
        }

        String intent = p.path("intent").asText("play_track");
        JsonNode head = p.path("head").isObject() ? p.path("head") : p;
        Hlc incomingClock = eventClock(ev, p);
        if (incomingClock == null) {
            incomingClock = new Hlc(System.currentTimeMillis(), 0, ev.device_client_id());
        }
        Hlc currentClock = Hlc.parse(st.getHeadClock(), st.getHeadDevice());
        boolean headChanged = false;

        if (!"history_only".equals(intent)) {
            String ref = refOf(head);
            if (ref == null || ref.isBlank()) ref = st.getSourceRef();
            String session = head.path("session_id").asText(null);
            boolean sameSession = session == null || st.getHeadSession() == null
                    || session.equals(st.getHeadSession());
            boolean sameTrack = ref == null || st.getSourceRef() == null
                    || ref.equals(st.getSourceRef());
            boolean clockWins = currentClock == null
                    || incomingClock.compareTo(currentClock) > 0;

            boolean accept = false;
            switch (intent) {
                case "progress" -> {
                    // 进度心跳不能改歌、不能改会话；只允许当前 head 设备上报。
                    // 它还必须是同一首曲（同会话但换曲的陈旧心跳不能改 head）。
                    accept = clockWins
                            && sameSession
                            && sameTrack
                            && ev.device_client_id().equals(st.getHeadDevice());
                }
                case "pause", "resume", "seek" -> {
                    // 暂停/继续/seek 可以来自跟随设备，但必须仍作用于同一会话/同一曲，
                    // 防止旧会话在别处新起播后又被它的旧暂停覆盖。
                    accept = clockWins && sameSession && sameTrack;
                }
                case "play_track" -> accept = clockWins;
                default -> accept = clockWins;
            }
            if (accept) {
                final boolean progress = "progress".equals(intent);
                if (!progress) {
                    if (head.hasNonNull("source_id")) st.setSourceId(sourceIdOf(head));
                    if (head.hasNonNull("source")) st.setSource(protocolOf(head));
                    if (head.hasNonNull("source_ref")) st.setSourceRef(ref);
                    st.setHeadSession("play_track".equals(intent)
                            ? (session == null ? UUID.randomUUID().toString() : session)
                            : (session == null ? st.getHeadSession() : session));
                }
                if (head.has("position_ms")) {
                    st.setPositionMs(head.path("position_ms").asInt(0));
                }
                if (head.has("playing")) {
                    st.setHeadPlaying(head.path("playing").asBoolean(false));
                } else if ("pause".equals(intent)) {
                    st.setHeadPlaying(false);
                } else if ("resume".equals(intent) || "play_track".equals(intent)) {
                    st.setHeadPlaying(true);
                }
                st.setDeviceClientId(ev.device_client_id());
                // progress 只刷新进度/播放态，不改变「谁是最新真实操作」：
                // head_clock/head_op_id/head_session 保持上一次真实操作的值。
                // 否则一次心跳会把时钟推高，使另一台设备稍后到达的真实操作
                // 因 clockWins 失败而被误判为旧操作。
                if (!progress) {
                    st.setHeadDevice(ev.device_client_id());
                    st.setHeadOpId(p.path("op_id").asText(ev.event_uuid()));
                    st.setHeadClock(incomingClock.encode());
                }
                st.setHeadUpdatedAt(LocalDateTime.now());
                st.setLastEventAt(eventTime(ev));
                st.setHeadRev(st.getHeadRev() + 1);
                headChanged = true;
            }
        }

        // 当前曲必须出现在历史里（play_track 被接受时补一次尾部；已有则不动）。
        if (headChanged && "play_track".equals(intent)
                && st.getSourceRef() != null && !st.getSourceRef().isBlank()) {
            List<String> keys = deepKeys(mergedHistory);
            String ref = st.getSourceRef();
            if (keys.isEmpty() || !ref.equals(keys.get(keys.size() - 1))) {
                var e = STATIC_MAPPER.createObjectNode();
                if (st.getSource() != null) e.put("source", st.getSource());
                e.put("source_ref", ref);
                mergedHistory.add(e);
                mergedHistory = dedupeDeep(mergedHistory, capacity);
                historyChanged = true;
            }
        }

        if (historyChanged) {
            st.setDeepListJson(deepJson(mergedHistory));
            st.setHistoryRev(st.getHistoryRev() + 1);
        }
        playStateRepository.save(st);
        log.info("sync.breakpoint v2 playlist={} device={} intent={} clock={} headChanged={} historyChanged={} headRev={} historyRev={}",
                pl.getClientUuid(), ev.device_client_id(), intent, incomingClock.encode(),
                headChanged, historyChanged, st.getHeadRev(), st.getHistoryRev());
        return ApplyOutcome.none();
    }

    private static void applyBreakpointCurrent(PlayState st, PushEvent ev, JsonNode p,
                                               String ref) {
        st.setSourceId(sourceIdOf(p));
        st.setSource(protocolOf(p));
        st.setSourceRef(ref);
        st.setDeviceClientId(ev.device_client_id());
        st.setPositionMs(p == null ? 0 : p.path("position_ms").asInt(0));
    }

    private int playlistCapacity(Playlist pl) {
        long n = playlistItemRepository.countByPlaylistId(pl.getId());
        if (n <= 0) return 0;
        return n > Integer.MAX_VALUE ? Integer.MAX_VALUE : (int) n;
    }

    /**
     * 合并时钟取不小于两分支的服务端时间，且严格大于两边，避免对端镜像
     * 时钟用 `<=` 拒收（设备墙钟跑到未来时 now 也可能不够新）。
     */
    static LocalDateTime mergeClock(LocalDateTime current, LocalDateTime incoming) {
        LocalDateTime out = current;
        if (incoming != null && (out == null || incoming.isAfter(out))) out = incoming;
        LocalDateTime now = LocalDateTime.now();
        if (out == null || now.isAfter(out)) out = now;
        // 1ms 步进：覆盖 MySQL/ISO 序列化的微秒/毫秒精度。
        if (current != null && !out.isAfter(current)) {
            out = current.plusNanos(1_000_000);
        }
        if (incoming != null && !out.isAfter(incoming)) {
            out = incoming.plusNanos(1_000_000);
        }
        return out;
    }

    /** 历史未变但仍接受了本次当前曲/进度：时钟只前进，不允许被旧事件回退。 */
    static LocalDateTime acceptClock(LocalDateTime current, LocalDateTime incoming) {
        if (incoming != null && (current == null || incoming.isAfter(current))) {
            return incoming;
        }
        if (current == null) return incoming;
        return current.plusNanos(1_000_000);
    }

    private static LocalDateTime eventTime(PushEvent ev) {
        return ev.occurred_at() == null ? LocalDateTime.now() : ev.occurred_at();
    }

    // ------------------------------------------------------------------
    // pull：增量拉取（事件页内去重 id → 当前行快照）
    // ------------------------------------------------------------------

    /**
     * 一页事件的分类结果（纯函数产物，便于单测「断点不牵连歌单快照」）。
     * [songPayloads] 需再进行 (source_id, source_ref) 行解析；其余为实体 uuid 集合。
     */
    public record PullCollections(List<JsonNode> songPayloads,
                                  Set<String> sourceUuids,
                                  Set<String> playlistUuids,
                                  Set<String> playstateUuids) {}

    /**
     * 把一页事件分类为待回快照的目标（本设备事件跳过，cursor 照常推进）。
     *
     * 关键规则：`breakpoint.set` 只贡献 playstate（断点）快照，**不贡献歌单
     * 快照**——否则他机每播一首（25s 节流事件），本机每次 pull 都要整包重下
     * 该歌单全部条目，是稳态流量最大的放大器。歌单自身的变化由 `playlist.*`
     * 事件负责携带；歌单元数据/条目事件仍顺带回其当前断点（原行为保留）。
     */
    public static PullCollections collectPulls(List<SyncEvent> page,
                                               String authClientId,
                                               Function<String, JsonNode> payloadParser) {
        List<JsonNode> songPayloads = new ArrayList<>();
        Set<String> sourceUuids = new LinkedHashSet<>();
        Set<String> playlistUuids = new LinkedHashSet<>();
        Set<String> playstateUuids = new LinkedHashSet<>();
        for (SyncEvent e : page) {
            // 本设备事件不再回灌（push 已即时应用并同步返回 corrections）：
            // 避免拉取自己的歌单/权重快照重建本地条目（丢失本机快照字段）。
            // cursor 照常推进；他人事件正常收敛。
            if (isSelfEvent(authClientId, e)) continue;
            JsonNode p = payloadParser.apply(e.getPayload());
            if (e.getType().startsWith("song.")) {
                songPayloads.add(p);
            } else if (e.getType().startsWith("source.")) {
                String uuid = p.path("client_uuid").asText(null);
                if (uuid != null) sourceUuids.add(uuid);
            } else if (e.getType().startsWith("playlist.")) {
                String uuid = p.path("client_uuid").asText(null);
                if (uuid == null) uuid = p.path("playlist_uuid").asText(null);
                if (uuid != null) {
                    playlistUuids.add(uuid);
                    playstateUuids.add(uuid);
                }
            } else if (SyncEventTypes.BREAKPOINT_SET.equals(e.getType())) {
                String uuid = p.path("playlist_uuid").asText(null);
                if (uuid != null) playstateUuids.add(uuid);
            }
        }
        return new PullCollections(songPayloads, sourceUuids, playlistUuids, playstateUuids);
    }

    @Transactional
    public Map<String, Object> pull(String authClientId, long sinceCursor) {
        List<SyncEvent> page = syncEventRepository.findTop2000BySeqGreaterThanOrderBySeqAsc(sinceCursor);
        PullCollections collected = collectPulls(page, authClientId, this::parsePayload);
        Set<Long> songStateIds = new LinkedHashSet<>();
        for (JsonNode p : collected.songPayloads()) {
            Long sid = tryResolveStateId(p);
            if (sid != null) songStateIds.add(sid);
        }
        List<Map<String, Object>> songs = new ArrayList<>();
        for (SongState s : songStateRepository.findAllById(songStateIds)) songs.add(songSnapshot(s));
        List<Map<String, Object>> sources = new ArrayList<>();
        for (String uuid : collected.sourceUuids()) {
            syncSourceRepository.findByClientUuid(uuid).ifPresent(ss -> sources.add(sourceSnapshot(ss)));
        }
        List<Map<String, Object>> playlists = new ArrayList<>();
        for (String uuid : collected.playlistUuids()) {
            playlistRepository.findByClientUuid(uuid).ifPresent(pl -> playlists.add(playlistSnapshot(pl)));
        }
        List<Map<String, Object>> playstates = new ArrayList<>();
        for (String uuid : collected.playstateUuids()) {
            playlistRepository.findByClientUuid(uuid).ifPresent(pl ->
                    playStateRepository.findById(pl.getId()).ifPresent(st ->
                            playstates.add(playstateSnapshot(st, pl.getClientUuid()))));
        }
        long cursor;
        if (page.size() < PULL_EVENT_LIMIT) {
            cursor = syncEventRepository.maxSeq();
        } else {
            Long tailSeq = page.get(page.size() - 1).getSeq();
            cursor = tailSeq == null ? 0L : tailSeq;
        }
        // 设备水位：pull 返回的 cursor 即该设备已消费到的位置（事件日志压缩依据）。
        touchDevice(authClientId, cursor);
        // 事件日志压缩（每小时至多一次；每实体保留最新一条，见 repo 查询）。
        maybeCompact();
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("cursor", cursor);
        out.put("has_more", page.size() >= PULL_EVENT_LIMIT);
        out.put("songs", songs);
        out.put("sources", sources);
        out.put("playlists", playlists);
        out.put("playstates", playstates);
        // v2：客户端据此切换到「head_rev/history_rev」路径；旧服务端无此字段。
        out.put("breakpoint_protocol", 2);
        out.put("server_epoch", serverEpoch());
        // 时钟校准：客户端据此修正出队时间戳，治设备墙钟偏移导致的 LWW 误判。
        out.put("server_time", serverTimeNow());
        log.info("sync.pull device={} since={} page={} cursor={} has_more={} songs={} sources={} playlists={} playstates={}",
                authClientId, sinceCursor, page.size(), cursor, out.get("has_more"),
                songs.size(), sources.size(), playlists.size(), playstates.size());
        return out;
    }

    /**
     * 服务端当前时间（ISO-8601，客户端 `DateTime.parse` 可读）。
     * 纯函数，可单测格式。
     */
    public static String serverTimeNow() {
        return java.time.LocalDateTime.now().toString();
    }

    // ------------------------------------------------------------------
    // 快照（pull 与 correction 共用同一形状）
    // ------------------------------------------------------------------

    public static Map<String, Object> songSnapshot(SongState s) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("id", s.getId());
        m.put("source_id", s.getSourceId());
        m.put("source", s.getSource());
        m.put("source_ref", s.getSourceRef());
        m.put("like_streak", nvl(s.getLikeStreak()));
        m.put("dislike_streak", nvl(s.getDislikeStreak()));
        // 锁定行权重出线即归一（DB 老行可能仍是 FACTOR_MIN 0.5）：客户端拉到的即 0.1。
        m.put("weight", normalizeFrozenWeight(s.isFrozen(),
                s.getWeight() == null ? BigDecimal.ONE : s.getWeight()).doubleValue());
        m.put("frozen", s.isFrozen());
        m.put("is_favorite", s.isFavorite());
        m.put("play_sec", nvl(s.getPlaySec()));
        return m;
    }

    public Map<String, Object> sourceSnapshot(SyncSource s) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("id", s.getId());
        m.put("client_uuid", s.getClientUuid());
        m.put("kind", s.getKind());
        m.put("name", s.getName());
        m.put("address", s.getAddress());
        m.put("config", parsePayload(s.getConfigJson()));
        m.put("enabled", s.isEnabled());
        m.put("deleted", s.isDeleted());
        m.put("sync_ver", s.getSyncVer());
        m.put("updated_at", s.getUpdatedAt() == null ? null : s.getUpdatedAt().toString());
        return m;
    }

    public Map<String, Object> playlistSnapshot(Playlist p) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("id", p.getId());
        m.put("client_uuid", p.getClientUuid());
        m.put("name", p.getName());
        m.put("description", p.getDescription());
        m.put("mode", p.getMode() == null ? null : p.getMode().name());
        m.put("deleted", p.isDeleted());
        m.put("sync_ver", p.getSyncVer());
        m.put("updated_at", p.getUpdatedAt() == null ? null : p.getUpdatedAt().toString());
        List<Map<String, Object>> items = new ArrayList<>();
        if (!p.isDeleted()) {
            for (PlaylistItem it : playlistItemRepository.findByPlaylistIdOrderBySortOrderAsc(p.getId())) {
                Map<String, Object> im = new LinkedHashMap<>();
                im.put("source_id", it.getSourceId());
                im.put("source", it.getSource());
                im.put("source_ref", it.getSourceRef());
                im.put("title", it.getTitle());
                im.put("artist", it.getArtist());
                im.put("album", it.getAlbum());
                im.put("duration", it.getDuration());
                im.put("sort_order", it.getSortOrder());
                items.add(im);
            }
        }
        m.put("items", items);
        return m;
    }

    public static Map<String, Object> playstateSnapshot(PlayState st, String clientUuid) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("playlist_id", st.getPlaylistId());
        m.put("client_uuid", clientUuid);
        m.put("source_id", st.getSourceId());
        m.put("source", st.getSource());
        m.put("source_ref", st.getSourceRef());
        m.put("device_client_id", st.getDeviceClientId());
        m.put("position_ms", st.getPositionMs());
        // v2：head 版本与历史版本分开；客户端只用 rev 判断是否应用，
        // head_clock 仅用于服务端仲裁/诊断，不再让客户端比较墙钟。
        m.put("head_rev", st.getHeadRev());
        m.put("head_clock", st.getHeadClock());
        m.put("head_device", st.getHeadDevice());
        m.put("head_op_id", st.getHeadOpId());
        m.put("head_session", st.getHeadSession());
        m.put("head_playing", st.getHeadPlaying());
        m.put("head_updated_at",
                st.getHeadUpdatedAt() == null ? null : st.getHeadUpdatedAt().toString());
        m.put("history_rev", st.getHistoryRev());
        // 旧协议字段：仍保留给未升级客户端和诊断。
        // 最后操作时间（= 命中事件的 occurred_at）；updated_at 是服务端写入时间。
        m.put("last_event_at",
                st.getLastEventAt() == null ? null : st.getLastEventAt().toString());
        m.put("updated_at", st.getUpdatedAt() == null ? null : st.getUpdatedAt().toString());
        m.put("deep_list", st.getDeepListJson() == null ? null
                : parseDeepList(st.getDeepListJson()));
        return m;
    }

    // ------------------------------------------------------------------
    // 深层列表合并（纯函数，可单测）
    // ------------------------------------------------------------------

    /** 深层列表元素身份：与客户端现有 `source_ref` 匹配口径一致。 */
    static String deepRef(JsonNode e) {
        if (e == null || !e.isObject()) return null;
        String ref = e.path("source_ref").asText(null);
        return (ref == null || ref.isBlank()) ? null : ref;
    }

    /** 过滤无效元素后的深层列表节点。 */
    static List<JsonNode> deepNodes(JsonNode array) {
        if (array == null || !array.isArray()) return List.of();
        List<JsonNode> out = new ArrayList<>();
        for (JsonNode e : array) {
            if (deepRef(e) != null) out.add(e);
        }
        return out;
    }

    static List<JsonNode> parseDeepNodes(String json) {
        if (json == null || json.isBlank()) return List.of();
        try {
            return deepNodes(STATIC_MAPPER.readTree(json));
        } catch (IOException | IllegalArgumentException e) {
            return List.of();
        }
    }

    static List<String> deepKeys(List<JsonNode> list) {
        List<String> out = new ArrayList<>(list.size());
        for (JsonNode e : list) out.add(deepRef(e));
        return out;
    }

    static boolean sameDeepKeys(List<JsonNode> a, List<JsonNode> b) {
        if (a.size() != b.size()) return false;
        for (int i = 0; i < a.size(); i++) {
            String ka = deepRef(a.get(i));
            String kb = deepRef(b.get(i));
            if (ka == null || !ka.equals(kb)) return false;
        }
        return true;
    }

    /**
     * 去重保留最后出现项（深层列表“最近播放”在尾部），再按容量从头部裁剪。
     * 容量来自歌单当前条目数；溢出只丢最旧端，两端新增的尾部都保留。
     */
    static List<JsonNode> dedupeDeep(List<JsonNode> list, int capacity) {
        LinkedHashMap<String, JsonNode> byRef = new LinkedHashMap<>();
        for (JsonNode e : list) {
            String ref = deepRef(e);
            if (ref == null) continue;
            byRef.remove(ref);
            byRef.put(ref, e);
        }
        List<JsonNode> out = new ArrayList<>(byRef.values());
        int cap = Math.max(0, capacity);
        if (out.size() > cap) {
            out = new ArrayList<>(out.subList(out.size() - cap, out.size()));
        }
        return out;
    }

    /** 纯追加：服务端当前分支 + 设备新增后缀。 */
    static List<JsonNode> appendDeepAdded(List<JsonNode> server,
                                          List<JsonNode> added,
                                          int capacity) {
        List<JsonNode> out = new ArrayList<>(server.size() + added.size());
        out.addAll(server);
        out.addAll(added);
        return dedupeDeep(out, capacity);
    }

    /**
     * 三向列表合并：C=base/server/device 最长公共前缀，
     * result = C + server[C:] + device[C:]（去重保留最后、按容量裁头）。
     *
     * 快路径保证非追加操作可自动裁决：
     * - server==base：设备分支（含 pop/replace/clear）胜出；
     * - device==base：服务端分支胜出（本设备未改历史，不抹对端）；
     * - server==device：幂等收敛。
     * 两端都改时先保留服务端分支、再接设备分支，并以设备分支为末尾。
     */
    static List<JsonNode> mergeDeepLists(List<JsonNode> base,
                                         List<JsonNode> server,
                                         List<JsonNode> device,
                                         int capacity) {
        if (sameDeepKeys(server, base)) return dedupeDeep(device, capacity);
        if (sameDeepKeys(device, base)) return dedupeDeep(server, capacity);
        if (sameDeepKeys(server, device)) return dedupeDeep(server, capacity);

        List<String> bk = deepKeys(base);
        List<String> sk = deepKeys(server);
        List<String> dk = deepKeys(device);
        int max = Math.min(bk.size(), Math.min(sk.size(), dk.size()));
        int c = 0;
        while (c < max && bk.get(c).equals(sk.get(c)) && bk.get(c).equals(dk.get(c))) {
            c++;
        }
        List<JsonNode> out = new ArrayList<>();
        out.addAll(base.subList(0, c));
        out.addAll(server.subList(c, server.size()));
        out.addAll(device.subList(c, device.size()));
        return dedupeDeep(out, capacity);
    }

    static String deepJson(List<JsonNode> list) {
        var arr = STATIC_MAPPER.createArrayNode();
        for (JsonNode e : list) arr.add(e);
        return arr.toString();
    }

    /** 深层列表 JSON 字符串 → 列表（坏数据返回空列表，不抛错）。 */
    static List<Object> parseDeepList(String json) {
        if (json == null || json.isBlank()) return List.of();
        try {
            JsonNode n = STATIC_MAPPER.readTree(json);
            if (!n.isArray()) return List.of();
            List<Object> out = new ArrayList<>();
            for (JsonNode e : n) out.add(STATIC_MAPPER.convertValue(e, Map.class));
            return out;
        } catch (IOException | IllegalArgumentException e) {
            return List.of();
        }
    }

    // ------------------------------------------------------------------
    // 小工具
    // ------------------------------------------------------------------

    /**
     * 设备活跃标记。[pullCursor] 非空时同时推进该设备的事件消费水位
     * （压缩依据；push 只更新 lastSeenAt）。
     */
    private void touchDevice(String clientId, Long pullCursor) {
        deviceRepository.findByClientId(clientId).ifPresent(d -> {
            d.setLastSeenAt(LocalDateTime.now());
            if (pullCursor != null) d.setLastPullCursor(pullCursor);
            deviceRepository.save(d);
        });
    }

    /** 事件日志压缩的最小间隔（每小时至多一次，避免每次 pull 都跑删除）。 */
    private static final long COMPACT_INTERVAL_MS = 3_600_000L;

    private final java.util.concurrent.atomic.AtomicLong lastCompactAtMs =
            new java.util.concurrent.atomic.AtomicLong(0);

    /**
     * 事件日志压缩：删除「所有未吊销设备都已消费完（min 水位以下）」的事件，
     * 但每实体保留最新一条——cursor=0 的新设备回放剩余事件仍能收敛到现状。
     * 压缩让 `sync_events` 不随使用时长无限增长（新设备首拉的页数从
     * O(历史事件数) 收敛到 O(实体数)）。
     */
    void maybeCompact() {
        long now = System.currentTimeMillis();
        long last = lastCompactAtMs.get();
        if (now - last < COMPACT_INTERVAL_MS) return;
        if (!lastCompactAtMs.compareAndSet(last, now)) return;
        Long watermark = deviceRepository.minActivePullCursor();
        if (watermark == null || watermark <= 0) return;
        try {
            int removed = syncEventRepository.compactBelow(watermark);
            if (removed > 0) {
                log.info("sync_events 压缩：删除 {} 条（水位 {}）", removed, watermark);
            }
        } catch (RuntimeException e) {
            // 压缩失败不影响 pull 主流程；清空计时让下轮重试。
            lastCompactAtMs.set(0);
            log.warn("sync_events 压缩失败（下轮重试）：{}", e.toString());
        }
    }

    /**
     * pull 收集权重行 id：与 stateOf 同一身份规则，找不到返回 null（歌已删则跳过）。
     * 注意此处恒不建行（provision=false）：已删歌曲不复活。
     */
    private Long tryResolveStateId(JsonNode p) {
        try {
            return stateOf(p, false).getId();
        } catch (BizException e) {
            return null;
        }
    }

    private JsonNode parsePayload(String payload) {
        if (payload == null || payload.isBlank()) return objectMapper.createObjectNode();
        try {
            return objectMapper.readTree(payload);
        } catch (IOException e) {
            return objectMapper.createObjectNode();
        }
    }

    private Playlist.PlaylistMode parseMode(String mode) {
        if (mode == null || mode.isBlank()) return Playlist.PlaylistMode.shuffle_weighted;
        try {
            return Playlist.PlaylistMode.valueOf(mode);
        } catch (IllegalArgumentException e) {
            throw new BizException(40001, "invalid playlist mode: " + mode);
        }
    }

    private Map<String, Object> pushResult(long cursor, List<String> applied,
                                           List<String> duplicates,
                                           List<Map<String, String>> rejected,
                                           Map<String, Object> corrections,
                                           Map<String, Object> merged,
                                           Map<String, Object> breakpoints) {
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("cursor", cursor);
        out.put("applied", applied);
        out.put("duplicates", duplicates);
        out.put("rejected", rejected);
        out.put("corrections", corrections);
        // 旧协议：深层列表合并快照按 event_uuid 键控；客户端即使发现
        // device_client_id 是自己也必须强制套用（其中含对端分支）。
        out.put("merged", merged);
        // v2：按 playlist 维度回权威 head+history；旧客户端忽略。
        out.put("breakpoints", breakpoints);
        out.put("breakpoint_protocol", 2);
        out.put("server_epoch", serverEpoch());
        // 时钟校准：见 pull（客户端修正出队时间戳用）。
        out.put("server_time", serverTimeNow());
        return out;
    }

    private static Map<String, String> reject(String uuid, String reason) {
        Map<String, String> m = new LinkedHashMap<>();
        m.put("event_uuid", uuid);
        m.put("reason", reason);
        return m;
    }

    private static BigDecimal factor(SongState song) {
        return song.getWeight() == null ? BigDecimal.ONE : song.getWeight();
    }

    /**
     * 「不喜欢」锁定行权重归一：锁定即固定最低档 {@link #DISLIKED_FACTOR}
     * （与客户端抽样侧的锁定态计权口径镜像）。纯函数，可单测。
     */
    public static BigDecimal normalizeFrozenWeight(boolean frozen, BigDecimal weight) {
        if (!frozen) return weight;
        return DISLIKED_FACTOR;
    }

    private static int nvl(Integer v) { return v == null ? 0 : v; }

    private static long nvlLong(Long v) { return v == null ? 0L : v; }

    private static String textOr(JsonNode p, String key, String def) {
        if (p == null || !p.has(key) || p.path(key).isNull()) return def;
        return p.path(key).asText(def);
    }
}
