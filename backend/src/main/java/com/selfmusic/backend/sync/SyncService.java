package com.selfmusic.backend.sync;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.selfmusic.backend.common.BizException;
import com.selfmusic.backend.common.MusicSource;
import com.selfmusic.backend.domain.entity.PlayState;
import com.selfmusic.backend.domain.entity.Playlist;
import com.selfmusic.backend.domain.entity.PlaylistItem;
import com.selfmusic.backend.domain.entity.Song;
import com.selfmusic.backend.domain.entity.SyncEvent;
import com.selfmusic.backend.domain.repository.DeviceRepository;
import com.selfmusic.backend.domain.repository.PlayStateRepository;
import com.selfmusic.backend.domain.repository.PlaylistItemRepository;
import com.selfmusic.backend.domain.repository.PlaylistRepository;
import com.selfmusic.backend.domain.repository.SongRepository;
import com.selfmusic.backend.domain.repository.SyncEventRepository;
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
import java.util.UUID;

/**
 * 阶段5 同步引擎服务端（DESIGN.md §4.4 / §7.2，字段级合并）。
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

    private final SyncEventRepository syncEventRepository;
    private final SongRepository songRepository;
    private final PlaylistRepository playlistRepository;
    private final PlaylistItemRepository playlistItemRepository;
    private final PlayStateRepository playStateRepository;
    private final DeviceRepository deviceRepository;
    private final ObjectMapper objectMapper;

    // ------------------------------------------------------------------
    // 纯函数：§7.1 权重状态机（无 DB，可单测）
    // ------------------------------------------------------------------

    /** 对服务端 Song 行应用一个权重事件（§7.1 事件表翻版）。未知类型抛 400。 */
    public static void applySongEvent(Song song, String type, JsonNode payload) {
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
     * LWW 仲裁：当前事件是否胜过行上次应用的事件。
     * lastEventAt 为空=首写恒胜；occurred 缺失恒输；
     * occurred 更大胜出，打平则后处理（到达序）胜出，保证确定性收敛。
     */
    public static boolean eventWins(LocalDateTime occurred, LocalDateTime lastEventAt) {
        if (lastEventAt == null) return true;
        if (occurred == null) return false;
        return !occurred.isBefore(lastEventAt);
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
                Song song = songOf(p, true);
                applySongEvent(song, ev.type(), p);
                songRepository.save(song);
                yield null;
            }
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
        if (type.equals(SyncEventTypes.PLAYLIST_CREATE)
                || type.equals(SyncEventTypes.PLAYLIST_UPDATE)
                || type.equals(SyncEventTypes.PLAYLIST_DELETE)) return "playlist_meta";
        if (type.startsWith("playlist.item_")) return "playlist_item";
        if (type.equals(SyncEventTypes.BREAKPOINT_SET)) return "breakpoint";
        return "?";
    }

    /**
     * 解析事件中的歌曲身份：优先数字 song_id（直接 REST 调用），
     * 否则按 (source, source_ref) 唯一键解析（客户端 outbox 事件）；
     * source 缺失/非法（含 legacy 行的 'server' 占位）时按 source_ref 全源兜底找第一首。
     *
     * 直连歌曲在服务端曲库无此行：[provision] 为真时按 (source, source_ref)
     * 建影子行承载权重/收藏/断点（展示字段取载荷或 ref 兜底，pull 回执只带权重字段，
     * 不覆盖客户端本地标题）；为假时（如 pull 身份收集）沿用旧行为：找不到抛 404，
     * 由调用方跳过（已删歌曲不复活）。
     */
    private Song songOf(JsonNode p, boolean provision) {
        if (p != null && p.has("song_id") && p.path("song_id").asLong(0) != 0) {
            long songId = p.path("song_id").asLong(0);
            return songRepository.findById(songId)
                    .orElseThrow(() -> new BizException(40402, "song not found: " + songId));
        }
        String source = p == null ? null : p.path("source").asText(null);
        String ref = p == null ? null : p.path("source_ref").asText(null);
        if (ref == null || ref.isBlank()) {
            throw new BizException(40001, "song_id or source_ref required");
        }
        if (source != null && !source.isBlank() && !"server".equals(source)) {
            try {
                MusicSource ms = MusicSource.valueOf(source);
                Optional<Song> found = songRepository.findBySourceAndSourceRef(ms, ref);
                if (found.isPresent()) return found.get();
                if (!provision) {
                    throw new BizException(40402, "song not found: " + source + "/" + ref);
                }
                return provisionShadow(ms, ref, p);
            } catch (IllegalArgumentException ignored) {
                // 非法 source 值：继续走 source_ref 兜底
            }
        }
        return songRepository.findFirstBySourceRef(ref)
                .orElseThrow(() -> new BizException(40402, "song not found: " + ref));
    }

    /**
     * 直连歌曲影子行：服务端曲库没有的 (source, source_ref) 在此建最小行，
     * 只承载权重/收藏/断点状态；标题取事件载荷（歌单条目携带）或 ref 末段兜底。
     */
    private Song provisionShadow(MusicSource ms, String ref, JsonNode p) {
        Song shadow = new Song();
        shadow.setSource(ms);
        shadow.setSourceRef(ref);
        shadow.setTitle(shadowTitle(p, ref));
        if (p != null && p.has("artist") && !p.path("artist").isNull()) {
            shadow.setArtist(p.path("artist").asText(null));
        }
        shadow.setFileSize(0L);
        return songRepository.save(shadow);
    }

    /**
     * 影子行标题：事件载荷 title 优先（去空白），否则取 ref 最后一段
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
            long songId = it.path("song_id").asLong(0);
            if (songId == 0 || songRepository.findById(songId).isEmpty()) continue;
            PlaylistItem item = new PlaylistItem();
            item.setPlaylist(pl);
            item.setSong(songRepository.getReferenceById(songId));
            item.setSortOrder(it.path("sort_order").asInt(0));
            playlistItemRepository.save(item);
        }
    }

    private void applyPlaylistItem(PushEvent ev) {
        JsonNode p = ev.payload();
        Playlist pl = playlistOf(p);
        if (pl.isDeleted()) throw new BizException(40001, "playlist_deleted");
        String t = ev.type();
        if (SyncEventTypes.PLAYLIST_ITEM_REMOVE.equals(t)) {
            // 移除幂等：服务端无此歌 = 早已收敛，直接 no-op（不建影子行）。
            Long sid = tryResolveSongId(p);
            if (sid != null) {
                playlistItemRepository.deleteByPlaylistIdAndSongId(pl.getId(), sid);
            }
        } else {
            // add/move：直连歌曲无服务端 song_id，按 (source, source_ref)
            // 解析，缺行则建影子行（已存在则当 move 更新顺序）。
            long songId = p == null ? 0 : p.path("song_id").asLong(0);
            Song song = songId != 0
                    ? songRepository.findById(songId)
                            .orElseThrow(() -> new BizException(40402, "song not found: " + songId))
                    : songOf(p, true);
            long sid = song.getId();
            PlaylistItem item = playlistItemRepository
                    .findByPlaylistIdAndSongId(pl.getId(), sid)
                    .orElseGet(() -> {
                        PlaylistItem ni = new PlaylistItem();
                        ni.setPlaylist(pl);
                        ni.setSong(song);
                        return ni;
                    });
            if (p != null && p.has("sort_order")) item.setSortOrder(p.path("sort_order").asInt(0));
            playlistItemRepository.save(item);
        }
        pl.setSyncVer(nvlLong(pl.getSyncVer()) + 1);
        playlistRepository.save(pl);
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
        Song song = songOf(p, true);
        st.setSong(song);
        st.setPositionMs(p == null ? 0 : p.path("position_ms").asInt(0));
        st.setLastEventAt(ev.occurred_at());
        playStateRepository.save(st);
        return null;
    }

    // ------------------------------------------------------------------
    // 直接调权（POST /songs/{id}/weight）：走同一事件管线，保证 pull 可见
    // ------------------------------------------------------------------

    @Transactional
    public Map<String, Object> applyDirectWeight(Long songId, String eventType, JsonNode payload, String authClientId) {
        PushEvent ev = new PushEvent(UUID.randomUUID().toString(), authClientId, eventType,
                LocalDateTime.now(), payload == null ? objectMapper.createObjectNode() : payload);
        // song_id 强制为路径 id，防止载荷冒充他歌
        ((com.fasterxml.jackson.databind.node.ObjectNode) ev.payload()).put("song_id", songId);
        Map<String, Object> r = push(authClientId, List.of(ev));
        Song song = songRepository.findById(songId)
                .orElseThrow(() -> new BizException(40402, "song not found: " + songId));
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("song", songSnapshot(song));
        out.put("cursor", r.get("cursor"));
        return out;
    }

    // ------------------------------------------------------------------
    // pull：增量拉取（事件页内去重 id → 当前行快照）
    // ------------------------------------------------------------------

    @Transactional
    public Map<String, Object> pull(String authClientId, long sinceCursor) {
        List<SyncEvent> page = syncEventRepository.findTop2000BySeqGreaterThanOrderBySeqAsc(sinceCursor);
        Set<Long> songIds = new LinkedHashSet<>();
        Set<String> playlistUuids = new LinkedHashSet<>();
        for (SyncEvent e : page) {
            JsonNode p = parsePayload(e.getPayload());
            if (e.getType().startsWith("song.")) {
                Long sid = tryResolveSongId(p);
                if (sid != null) songIds.add(sid);
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
        for (Song s : songRepository.findAllById(songIds)) songs.add(songSnapshot(s));
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
        out.put("playlists", playlists);
        out.put("playstates", playstates);
        return out;
    }

    // ------------------------------------------------------------------
    // 快照（pull 与 correction 共用同一形状）
    // ------------------------------------------------------------------

    public static Map<String, Object> songSnapshot(Song s) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("id", s.getId());
        m.put("source", s.getSource() == null ? null : s.getSource().name());
        m.put("source_ref", s.getSourceRef());
        m.put("like_streak", nvl(s.getLikeStreak()));
        m.put("dislike_streak", nvl(s.getDislikeStreak()));
        m.put("weight", s.getWeight() == null ? 1.0 : s.getWeight().doubleValue());
        m.put("frozen", s.isFrozen());
        m.put("is_favorite", s.isFavorite());
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
                Song ss = it.getSong();
                im.put("song_id", ss == null ? null : ss.getId());
                im.put("source", ss == null || ss.getSource() == null ? null : ss.getSource().name());
                im.put("source_ref", ss == null ? null : ss.getSourceRef());
                im.put("title", ss == null ? null : ss.getTitle());
                im.put("artist", ss == null ? null : ss.getArtist());
                im.put("album", ss == null || ss.getAlbum() == null ? null : ss.getAlbum().getAlbum());
                im.put("duration", ss == null ? null : ss.getDuration());
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
        Song ss = st.getSong();
        m.put("song_id", ss == null ? null : ss.getId());
        m.put("source", ss == null || ss.getSource() == null ? null : ss.getSource().name());
        m.put("source_ref", ss == null ? null : ss.getSourceRef());
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
     * pull 收集歌曲快照 id：与 songOf 同一身份规则，找不到返回 null（歌已删则跳过）。
     * 注意此处恒不建影子行（provision=false）：已删歌曲不复活。
     */
    private Long tryResolveSongId(JsonNode p) {
        try {
            return songOf(p, false).getId();
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

    private static BigDecimal factor(Song song) {
        return song.getWeight() == null ? BigDecimal.ONE : song.getWeight();
    }

    private static int nvl(Integer v) { return v == null ? 0 : v; }

    private static long nvlLong(Long v) { return v == null ? 0L : v; }

    private static String textOr(JsonNode p, String key, String def) {
        if (p == null || !p.has(key) || p.path(key).isNull()) return def;
        return p.path(key).asText(def);
    }
}
