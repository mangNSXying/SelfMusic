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
 * - 歌单元数据 / 删除墓碑 / 断点：行级 LWW，以事件 occurred_at vs 行 last_event_at
 *   为准（{@link #eventWins} 纯函数），输方收 correction 回执自行纠正；
 * - 歌单条目：按 seq 到达序重放，后到达胜出，天然收敛；
 * - 仲裁时钟：occurred_at 缺失或打平时，后处理（到达序）胜出；行 last_event_at
 *   为空（首写）恒胜。客户端本地时钟不可信，不做跨时钟比较之外的推断。
 */
@Service
public class SyncService {

    private static final Logger log = LoggerFactory.getLogger(SyncService.class);

    public static final BigDecimal FACTOR_MIN = new BigDecimal("0.5");
    public static final BigDecimal FACTOR_MAX = new BigDecimal("1.5");
    public static final BigDecimal FACTOR_STEP = new BigDecimal("0.1");

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
    private final ObjectMapper objectMapper;

    public SyncService(SyncEventRepository syncEventRepository,
                       SongStateRepository songStateRepository,
                       SyncSourceRepository syncSourceRepository,
                       PlaylistRepository playlistRepository,
                       PlaylistItemRepository playlistItemRepository,
                       PlayStateRepository playStateRepository,
                       DeviceRepository deviceRepository,
                       ObjectMapper objectMapper) {
        this.syncEventRepository = syncEventRepository;
        this.songStateRepository = songStateRepository;
        this.syncSourceRepository = syncSourceRepository;
        this.playlistRepository = playlistRepository;
        this.playlistItemRepository = playlistItemRepository;
        this.playStateRepository = playStateRepository;
        this.deviceRepository = deviceRepository;
        this.objectMapper = objectMapper;
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
                    song.setWeight(FACTOR_MIN);
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
     * 权重绝对态（song.state，补推/纠偏用）：行级 LWW，判输返回快照纠偏。
     * 载荷缺键保持行上原值；全键齐备时即整行覆盖。
     * 例外：累计播放时长是单调量，取 `max(行值, 载荷值)`（与客户端落库同口径），
     * 旧快照晚到不把累计值写小。
     */
    private Object applySongState(PushEvent ev, SongState song) {
        if (!eventWins(ev.occurred_at(), song.getLastEventAt())) return songSnapshot(song);
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
        if (events == null || events.isEmpty()) {
            return pushResult(syncEventRepository.maxSeq(), applied, duplicates, rejected, corrections);
        }
        if (events.size() > PUSH_EVENT_LIMIT) {
            throw new BizException(40001, "too many events (max " + PUSH_EVENT_LIMIT + ")");
        }

        // 同批内排序：playlist.create 优先（条目/断点依赖歌单先存在），其余按 occurred_at
        List<PushEvent> sorted = events.stream()
                .sorted(Comparator.comparing((PushEvent e) -> !SyncEventTypes.PLAYLIST_CREATE.equals(e.type()))
                        .thenComparing(PushEvent::occurred_at, Comparator.nullsLast(Comparator.naturalOrder())))
                .toList();

        for (PushEvent ev : sorted) {
            if (ev.event_uuid() == null || ev.event_uuid().isBlank()
                    || ev.type() == null || ev.type().isBlank()) {
                rejected.add(reject(String.valueOf(ev.event_uuid()), "invalid event"));
                continue;
            }
            if (!authClientId.equals(ev.device_client_id())) {
                rejected.add(reject(ev.event_uuid(), "device_mismatch"));
                continue;
            }
            if (syncEventRepository.findByEventUuid(ev.event_uuid()).isPresent()) {
                duplicates.add(ev.event_uuid());
                continue;
            }
            try {
                Object correction = applyEvent(ev);
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
                if (correction != null) corrections.put(ev.event_uuid(), correction);
            } catch (BizException be) {
                rejected.add(reject(ev.event_uuid(), be.getMessage()));
            }
        }
        touchDevice(authClientId, null);
        return pushResult(syncEventRepository.maxSeq(), applied, duplicates, rejected, corrections);
    }

    /**
     * 应用单个已去重事件。返回 null=服务端接受；返回快照= LWW 判输，
     * 调用方把快照放入 corrections，客户端用它纠正本地。
     */
    private Object applyEvent(PushEvent ev) {
        JsonNode p = ev.payload();
        return switch (typeGroup(ev.type())) {
            case "song" -> {
                SongState song = stateOf(p, true);
                if (SyncEventTypes.SONG_STATE.equals(ev.type())) {
                    yield applySongState(ev, song);
                }
                applySongEvent(song, ev.type(), p);
                songStateRepository.save(song);
                yield null;
            }
            case "source_meta" -> applySourceMeta(ev);
            case "playlist_meta" -> applyPlaylistMeta(ev);
            case "playlist_item" -> {
                applyPlaylistItem(ev);
                yield null;
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
            if (!eventWins(ev.occurred_at(), row.getLastEventAt())) return sourceSnapshot(row);
            row.setDeleted(true);
            row.setLastEventAt(ev.occurred_at());
            row.setSyncVer(nvlLong(row.getSyncVer()) + 1);
            syncSourceRepository.save(row);
            return null;
        }

        SyncSource row = syncSourceRepository.findByClientUuid(uuid).orElse(null);
        if (row == null) {
            SyncSource same = syncSourceRepository.findByKindAndAddress(kind, address).orElse(null);
            if (same != null) {
                // 同址去重合并：采纳既有权威 uuid，事件方收 correction 重绑。
                if (!eventWins(ev.occurred_at(), same.getLastEventAt())) return sourceSnapshot(same);
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
        if (!eventWins(ev.occurred_at(), row.getLastEventAt())) return sourceSnapshot(row);
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
            // 幂等重试：同 uuid 已存在则按 update 走 LWW
            if (playlistRepository.findByClientUuid(uuid).isPresent()) {
                return applyPlaylistUpdate(ev, playlistRepository.findByClientUuid(uuid).orElseThrow());
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
            if (!eventWins(ev.occurred_at(), pl.getLastEventAt())) return playlistSnapshot(pl);
            pl.setDeleted(true);
            pl.setLastEventAt(ev.occurred_at());
            pl.setSyncVer(nvlLong(pl.getSyncVer()) + 1);
            playlistRepository.save(pl);
            return null;
        }
        return applyPlaylistUpdate(ev, pl);
    }

    private Object applyPlaylistUpdate(PushEvent ev, Playlist pl) {
        if (!eventWins(ev.occurred_at(), pl.getLastEventAt())) return playlistSnapshot(pl);
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

    private Object applyBreakpoint(PushEvent ev) {
        JsonNode p = ev.payload();
        Playlist pl = playlistOf(p);
        PlayState st = playStateRepository.findById(pl.getId()).orElseGet(() -> {
            PlayState ns = new PlayState();
            ns.setPlaylistId(pl.getId());
            return ns;
        });
        if (!eventWins(ev.occurred_at(), st.getLastEventAt())) {
            return playstateSnapshot(st, pl.getClientUuid());
        }
        String ref = refOf(p);
        if (ref == null || ref.isBlank()) throw new BizException(40001, "source_ref required");
        st.setSourceId(sourceIdOf(p));
        st.setSource(protocolOf(p));
        st.setSourceRef(ref);
        st.setDeviceClientId(ev.device_client_id());
        st.setPositionMs(p.path("position_ms").asInt(0));
        // 深层列表（播放历史）：原样保存 JSON 数组（元素 {source, source_ref}），
        // 对端据此重建融合队列；空/缺失则置空（旧客户端向后兼容）。
        st.setDeepListJson(p.has("deep_list") && !p.path("deep_list").isNull()
                ? p.path("deep_list").toString()
                : null);
        st.setLastEventAt(ev.occurred_at());
        playStateRepository.save(st);
        return null;
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
        return out;
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
        m.put("weight", s.getWeight() == null ? 1.0 : s.getWeight().doubleValue());
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
        m.put("updated_at", st.getUpdatedAt() == null ? null : st.getUpdatedAt().toString());
        m.put("deep_list", st.getDeepListJson() == null ? null
                : parseDeepList(st.getDeepListJson()));
        return m;
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

    private static Map<String, Object> pushResult(long cursor, List<String> applied,
                                                  List<String> duplicates,
                                                  List<Map<String, String>> rejected,
                                                  Map<String, Object> corrections) {
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("cursor", cursor);
        out.put("applied", applied);
        out.put("duplicates", duplicates);
        out.put("rejected", rejected);
        out.put("corrections", corrections);
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

    private static int nvl(Integer v) { return v == null ? 0 : v; }

    private static long nvlLong(Long v) { return v == null ? 0L : v; }

    private static String textOr(JsonNode p, String key, String def) {
        if (p == null || !p.has(key) || p.path(key).isNull()) return def;
        return p.path(key).asText(def);
    }
}
