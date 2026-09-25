package com.selfmusic.backend.sync;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.selfmusic.backend.common.BizException;
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
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

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

/**
 * 阶段5 同步引擎服务端（DESIGN.md §4.4 / §7.2，字段级合并）。
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
@RequiredArgsConstructor
public class SyncService {

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
        }
        song.setLastEventAt(ev.occurred_at());
        songStateRepository.save(song);
        return null;
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
                rejected.add(reject(ev == null ? "?" : String.valueOf(ev.event_uuid()), "invalid event"));
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
                syncEventRepository.save(row);
                applied.add(ev.event_uuid());
                if (correction != null) corrections.put(ev.event_uuid(), correction);
            } catch (BizException be) {
                rejected.add(reject(ev.event_uuid(), be.getMessage()));
            }
        }
        touchDevice(authClientId);
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
        if (uuid == null || uuid.isBlank()) uuid = p.path("playlist_uuid").asText(null);
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
        st.setLastEventAt(ev.occurred_at());
        playStateRepository.save(st);
        return null;
    }

    // ------------------------------------------------------------------
    // pull：增量拉取（事件页内去重 id → 当前行快照）
    // ------------------------------------------------------------------

    @Transactional
    public Map<String, Object> pull(String authClientId, long sinceCursor) {
        List<SyncEvent> page = syncEventRepository.findTop2000BySeqGreaterThanOrderBySeqAsc(sinceCursor);
        Set<Long> songStateIds = new LinkedHashSet<>();
        Set<String> playlistUuids = new LinkedHashSet<>();
        Set<String> sourceUuids = new LinkedHashSet<>();
        for (SyncEvent e : page) {
            // 本设备事件不再回灌（push 已即时应用并同步返回 corrections）：
            // 避免拉取自己的歌单/权重快照重建本地条目（丢失本机快照字段）。
            // cursor 照常推进；他人事件正常收敛。
            if (isSelfEvent(authClientId, e)) continue;
            JsonNode p = parsePayload(e.getPayload());
            if (e.getType().startsWith("song.")) {
                Long sid = tryResolveStateId(p);
                if (sid != null) songStateIds.add(sid);
            } else if (e.getType().startsWith("source.")) {
                String uuid = p.path("client_uuid").asText(null);
                if (uuid != null) sourceUuids.add(uuid);
            } else if (e.getType().startsWith("playlist.")) {
                String uuid = p.path("client_uuid").asText(null);
                if (uuid == null) uuid = p.path("playlist_uuid").asText(null);
                if (uuid != null) playlistUuids.add(uuid);
            } else if (SyncEventTypes.BREAKPOINT_SET.equals(e.getType())) {
                String uuid = p.path("playlist_uuid").asText(null);
                if (uuid != null) playlistUuids.add(uuid);
            }
        }
        List<Map<String, Object>> songs = new ArrayList<>();
        for (SongState s : songStateRepository.findAllById(songStateIds)) songs.add(songSnapshot(s));
        List<Map<String, Object>> sources = new ArrayList<>();
        for (String uuid : sourceUuids) {
            syncSourceRepository.findByClientUuid(uuid).ifPresent(ss -> sources.add(sourceSnapshot(ss)));
        }
        List<Map<String, Object>> playlists = new ArrayList<>();
        List<Map<String, Object>> playstates = new ArrayList<>();
        for (String uuid : playlistUuids) {
            playlistRepository.findByClientUuid(uuid).ifPresent(pl -> {
                playlists.add(playlistSnapshot(pl));
                playStateRepository.findById(pl.getId()).ifPresent(st ->
                        playstates.add(playstateSnapshot(st, pl.getClientUuid())));
            });
        }
        long cursor = page.size() < PULL_EVENT_LIMIT
                ? syncEventRepository.maxSeq()
                : page.get(page.size() - 1).getSeq();
        touchDevice(authClientId);
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
        return m;
    }

    // ------------------------------------------------------------------
    // 小工具
    // ------------------------------------------------------------------

    private void touchDevice(String clientId) {
        deviceRepository.findByClientId(clientId).ifPresent(d -> {
            d.setLastSeenAt(LocalDateTime.now());
            deviceRepository.save(d);
        });
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
        } catch (Exception e) {
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
