package com.selfmusic.backend.sync;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.selfmusic.backend.common.BizException;
import com.selfmusic.backend.domain.entity.SongState;
import com.selfmusic.backend.domain.entity.SyncEvent;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.List;
import java.util.Map;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.*;

/**
 * 阶段5：§7.1 服务端权重状态机 + LWW 仲裁纯函数单测（无 DB）。
 */
class SyncServiceTest {

    private final ObjectMapper mapper = new ObjectMapper();

    private static SongState freshState() {
        SongState s = new SongState();
        s.setLikeStreak(0);
        s.setDislikeStreak(0);
        s.setWeight(BigDecimal.ONE);
        s.setFrozen(false);
        s.setFavorite(false);
        return s;
    }

    @Test
    void completeThreeTimesRaisesFactor() {
        SongState s = freshState();
        ObjectNode empty = new ObjectMapper().createObjectNode();
        SyncService.applySongEvent(s, SyncEventTypes.SONG_COMPLETE, empty);
        SyncService.applySongEvent(s, SyncEventTypes.SONG_COMPLETE, empty);
        assertEquals(2, s.getLikeStreak());
        assertEquals(0, new BigDecimal("1.0").compareTo(s.getWeight()));
        SyncService.applySongEvent(s, SyncEventTypes.SONG_COMPLETE, empty);
        // streak 满 3 → factor+0.1 并清零
        assertEquals(0, s.getLikeStreak());
        assertEquals(0, new BigDecimal("1.1").compareTo(s.getWeight()));
    }

    @Test
    void skipThreeTimesLowersFactor() {
        SongState s = freshState();
        ObjectNode empty = new ObjectMapper().createObjectNode();
        SyncService.applySongEvent(s, SyncEventTypes.SONG_SKIP, empty);
        SyncService.applySongEvent(s, SyncEventTypes.SONG_SKIP, empty);
        SyncService.applySongEvent(s, SyncEventTypes.SONG_SKIP, empty);
        assertEquals(0, s.getDislikeStreak());
        assertEquals(0, new BigDecimal("0.9").compareTo(s.getWeight()));
    }

    @Test
    void factorClampedAtBounds() {
        SongState s = freshState();
        s.setWeight(new BigDecimal("1.5"));
        ObjectNode empty = new ObjectMapper().createObjectNode();
        for (int i = 0; i < 6; i++) SyncService.applySongEvent(s, SyncEventTypes.SONG_COMPLETE, empty);
        assertEquals(0, new BigDecimal("1.5").compareTo(s.getWeight()));

        s.setWeight(new BigDecimal("0.5"));
        for (int i = 0; i < 6; i++) SyncService.applySongEvent(s, SyncEventTypes.SONG_SKIP, empty);
        assertEquals(0, new BigDecimal("0.5").compareTo(s.getWeight()));
    }

    @Test
    void likedUnfavoriteDislikedReset() {
        SongState s = freshState();
        ObjectNode empty = new ObjectMapper().createObjectNode();

        SyncService.applySongEvent(s, SyncEventTypes.SONG_LIKED, empty);
        assertTrue(s.isFavorite());
        assertEquals(0, new BigDecimal("1.5").compareTo(s.getWeight()));
        assertFalse(s.isFrozen());

        SyncService.applySongEvent(s, SyncEventTypes.SONG_UNFAVORITE, empty);
        assertFalse(s.isFavorite());
        assertEquals(0, BigDecimal.ONE.compareTo(s.getWeight()));

        ObjectNode off = new ObjectMapper().createObjectNode();
        off.put("enabled", true);
        SyncService.applySongEvent(s, SyncEventTypes.SONG_DISLIKED, off);
        assertTrue(s.isFrozen());
        assertEquals(0, new BigDecimal("0.5").compareTo(s.getWeight()));

        ObjectNode on = new ObjectMapper().createObjectNode();
        on.put("enabled", false);
        SyncService.applySongEvent(s, SyncEventTypes.SONG_DISLIKED, on);
        assertFalse(s.isFrozen());
        assertEquals(0, BigDecimal.ONE.compareTo(s.getWeight()));

        SyncService.applySongEvent(s, SyncEventTypes.SONG_RESET, empty);
        assertEquals(0, s.getLikeStreak());
        assertEquals(0, s.getDislikeStreak());
        assertEquals(0, BigDecimal.ONE.compareTo(s.getWeight()));
        assertFalse(s.isFrozen());
    }

    @Test
    void unfavoriteKeepsWeightWhenFrozen() {
        SongState s = freshState();
        s.setFrozen(true);
        s.setWeight(new BigDecimal("0.5"));
        SyncService.applySongEvent(s, SyncEventTypes.SONG_UNFAVORITE, new ObjectMapper().createObjectNode());
        assertEquals(0, new BigDecimal("0.5").compareTo(s.getWeight()));
    }

    @Test
    void frozenSkipsAutoAdjustButCountsStreak() {
        SongState s = freshState();
        s.setFrozen(true);
        s.setWeight(new BigDecimal("0.5"));
        ObjectNode empty = new ObjectMapper().createObjectNode();
        for (int i = 0; i < 5; i++) SyncService.applySongEvent(s, SyncEventTypes.SONG_COMPLETE, empty);
        assertEquals(0, new BigDecimal("0.5").compareTo(s.getWeight()));
        assertEquals(5, s.getLikeStreak());
    }

    @Test
    void completeManualRaisesOneNotchAndClearsStreaks() {
        SongState s = freshState();
        ObjectNode empty = new ObjectMapper().createObjectNode();
        // 先累计完播/跳过各 2 次
        SyncService.applySongEvent(s, SyncEventTypes.SONG_COMPLETE, empty);
        SyncService.applySongEvent(s, SyncEventTypes.SONG_COMPLETE, empty);
        SyncService.applySongEvent(s, SyncEventTypes.SONG_SKIP, empty);
        SyncService.applySongEvent(s, SyncEventTypes.SONG_SKIP, empty);
        // 手动完播：不依赖 streak 门槛，直接 +0.1 并清空双 streak
        SyncService.applySongEvent(s, SyncEventTypes.SONG_COMPLETE_MANUAL, empty);
        assertEquals(0, s.getLikeStreak());
        assertEquals(0, s.getDislikeStreak());
        assertEquals(0, new BigDecimal("1.1").compareTo(s.getWeight()));
    }

    @Test
    void completeManualClampedAtMaxAndFrozenKeepsWeight() {
        SongState s = freshState();
        ObjectNode empty = new ObjectMapper().createObjectNode();
        s.setWeight(new BigDecimal("1.5"));
        SyncService.applySongEvent(s, SyncEventTypes.SONG_COMPLETE_MANUAL, empty);
        assertEquals(0, new BigDecimal("1.5").compareTo(s.getWeight()));

        SongState f = freshState();
        f.setFrozen(true);
        f.setWeight(new BigDecimal("0.5"));
        SyncService.applySongEvent(f, SyncEventTypes.SONG_COMPLETE_MANUAL, empty);
        assertEquals(0, new BigDecimal("0.5").compareTo(f.getWeight()));
        assertEquals(0, f.getLikeStreak());
        assertEquals(0, f.getDislikeStreak());
    }

    @Test
    void unknownSongEventThrows() {
        SongState s = freshState();
        BizException ex = assertThrows(BizException.class, () ->
                SyncService.applySongEvent(s, "song.nope", mapper.createObjectNode()));
        assertEquals(40001, ex.code);
    }

    @Test
    void eventWinsMatrix() {
        LocalDateTime t1 = LocalDateTime.of(2026, 9, 20, 12, 0, 0);
        LocalDateTime t2 = LocalDateTime.of(2026, 9, 20, 12, 0, 1);
        // 首写恒胜
        assertTrue(SyncService.eventWins(t1, null));
        // occurred 缺失恒输
        assertFalse(SyncService.eventWins(null, t1));
        // 更大胜出 / 打平后处理胜出 / 更小判输
        assertTrue(SyncService.eventWins(t2, t1));
        assertTrue(SyncService.eventWins(t1, t1));
        assertFalse(SyncService.eventWins(t1, t2));
    }

    @Test
    void shadowTitlePrefersPayloadTitle() {
        ObjectNode p = mapper.createObjectNode();
        p.put("title", "  直连歌名  ");
        assertEquals("直连歌名", SyncService.shadowTitle(p, "/music/a.mp3"));
    }

    @Test
    void selfEventsAreSkippedInPullCollection() {
        SyncEvent own = new SyncEvent();
        own.setDeviceClientId("dev-a");
        SyncEvent other = new SyncEvent();
        other.setDeviceClientId("dev-b");
        SyncEvent legacy = new SyncEvent(); // 设备号缺失：保守保留
        SyncEvent nullEvent = null;

        assertTrue(SyncService.isSelfEvent("dev-a", own));
        assertFalse(SyncService.isSelfEvent("dev-a", other));
        assertFalse(SyncService.isSelfEvent("dev-a", legacy));
        assertFalse(SyncService.isSelfEvent(null, own));
        assertFalse(SyncService.isSelfEvent("", own));
        assertFalse(SyncService.isSelfEvent("dev-a", nullEvent));
    }

    @Test
    void shadowTitleFallsBackToRefBasename() {
        ObjectNode p = mapper.createObjectNode();
        assertEquals("a.mp3", SyncService.shadowTitle(p, "/music/a.mp3"));
        // 百分号编码解码
        assertEquals("歌a.mp3", SyncService.shadowTitle(p, "/music/%E6%AD%8Ca.mp3"));
        // 空载荷 / 空标题同样兜底
        assertEquals("x", SyncService.shadowTitle(null, "x"));
        ObjectNode blank = mapper.createObjectNode();
        blank.put("title", "   ");
        assertEquals("b.flac", SyncService.shadowTitle(blank, "b.flac"));
    }

    @Test
    void songSnapshotCarriesPlaySec() {
        SongState s = freshState();
        s.setSourceId("uuid-1");
        s.setSourceRef("/music/a.mp3");
        s.setPlaySec(600);

        Map<String, Object> m = SyncService.songSnapshot(s);
        assertEquals(600, m.get("play_sec"));

        // 旧行 play_sec 为 null → 快照给 0（客户端按缺键/0 处理都不会崩）
        s.setPlaySec(null);
        assertEquals(0, SyncService.songSnapshot(s).get("play_sec"));
    }

    @Test
    void mergePlaySecTakesMaxAndTreatsNullAsZero() {
        // 旧快照晚到不把累计值写小（与客户端 max 口径一致）。
        assertEquals(600, SyncService.mergePlaySec(600, 120));
        assertEquals(900, SyncService.mergePlaySec(600, 900));
        assertEquals(100, SyncService.mergePlaySec(null, 100));
        assertEquals(0, SyncService.mergePlaySec(null, 0));
    }

    @Test
    void weightEventsDoNotTouchPlaySec() {
        SongState s = freshState();
        s.setPlaySec(3600);
        ObjectNode empty = mapper.createObjectNode();
        SyncService.applySongEvent(s, SyncEventTypes.SONG_COMPLETE, empty);
        SyncService.applySongEvent(s, SyncEventTypes.SONG_SKIP, empty);
        SyncService.applySongEvent(s, SyncEventTypes.SONG_RESET, empty);
        SyncService.applySongEvent(s, SyncEventTypes.SONG_LIKED, empty);
        assertEquals(3600, s.getPlaySec());
    }

    // ------------------------------------------------------------------
    // 事件日志压缩锚点（migration_008）与 pull 分类（数据增量化）
    // ------------------------------------------------------------------

    @Test
    void entityKeyDerivesIdentityForCompaction() {
        ObjectNode song = mapper.createObjectNode();
        song.put("source_id", "uuid-1");
        song.put("source_ref", "/music/a.mp3");
        assertEquals("song|uuid-1|/music/a.mp3",
                SyncService.entityKeyOf("song.complete", song));

        // 无 source_id → legacy 协议回退（与权重行身份解析同规则）
        ObjectNode legacySong = mapper.createObjectNode();
        legacySong.put("source", "webdav");
        legacySong.put("source_ref", "/m/b.flac");
        assertEquals("song|legacy:webdav|/m/b.flac",
                SyncService.entityKeyOf(SyncEventTypes.SONG_STATE, legacySong));

        // 缺 ref / 空载荷 / 未知类型 → null（该行不参与压缩，保守保留）
        assertNull(SyncService.entityKeyOf("song.skip", mapper.createObjectNode()));
        assertNull(SyncService.entityKeyOf("song.skip", null));
        assertNull(SyncService.entityKeyOf("unknown.type", song));

        ObjectNode src = mapper.createObjectNode();
        src.put("client_uuid", "s-1");
        assertEquals("source|s-1", SyncService.entityKeyOf("source.update", src));

        ObjectNode pl = mapper.createObjectNode();
        pl.put("client_uuid", "p-1");
        assertEquals("playlist|p-1",
                SyncService.entityKeyOf("playlist.item_add", pl));

        ObjectNode plLegacy = mapper.createObjectNode();
        plLegacy.put("playlist_uuid", "p-2");
        assertEquals("playlist|p-2",
                SyncService.entityKeyOf("playlist.update", plLegacy));

        ObjectNode bp = mapper.createObjectNode();
        bp.put("playlist_uuid", "p-3");
        assertEquals("breakpoint|p-3",
                SyncService.entityKeyOf(SyncEventTypes.BREAKPOINT_SET, bp));
    }

    @Test
    void breakpointEventsDoNotCollectPlaylistSnapshots() {
        // 他机断点：只回 playstate，不整包重下歌单条目（稳态流量放大器修复）
        SyncEvent bp = event(SyncEventTypes.BREAKPOINT_SET, "dev-b",
                "{\"playlist_uuid\":\"pl-1\",\"source_ref\":\"/a.mp3\"}");
        // 歌单事件：歌单 + 其断点都回（原行为保留）
        SyncEvent plAdd = event("playlist.item_add", "dev-b",
                "{\"playlist_uuid\":\"pl-2\",\"source_ref\":\"/b.mp3\"}");
        // 本机事件：整体跳过
        SyncEvent self = event(SyncEventTypes.BREAKPOINT_SET, "dev-a",
                "{\"playlist_uuid\":\"pl-3\",\"source_ref\":\"/c.mp3\"}");

        SyncService.PullCollections c = SyncService.collectPulls(
                List.of(bp, plAdd, self), "dev-a", this::parse);

        assertEquals(Set.of("pl-2"), c.playlistUuids());
        assertEquals(Set.of("pl-1", "pl-2"), c.playstateUuids());
        assertTrue(c.songPayloads().isEmpty());
        assertTrue(c.sourceUuids().isEmpty());
    }

    @Test
    void collectPullsGathersSongSourceAndPlaylistIdentity() {
        SyncEvent song = event("song.liked", "dev-b",
                "{\"source_id\":\"u1\",\"source_ref\":\"/a.mp3\"}");
        SyncEvent src = event("source.update", "dev-b",
                "{\"client_uuid\":\"s1\",\"kind\":\"webdav\",\"address\":\"https://x\"}");
        SyncEvent pl = event("playlist.update", "dev-b",
                "{\"client_uuid\":\"p1\"}");

        SyncService.PullCollections c = SyncService.collectPulls(
                List.of(song, src, pl), "dev-a", this::parse);

        assertEquals(1, c.songPayloads().size());
        assertEquals("/a.mp3", c.songPayloads().get(0).path("source_ref").asText());
        assertEquals(Set.of("s1"), c.sourceUuids());
        assertEquals(Set.of("p1"), c.playlistUuids());
        assertEquals(Set.of("p1"), c.playstateUuids());
    }

    private SyncEvent event(String type, String device, String payload) {
        SyncEvent e = new SyncEvent();
        e.setType(type);
        e.setDeviceClientId(device);
        e.setPayload(payload);
        return e;
    }

    private JsonNode parse(String payload) {
        try {
            return payload == null ? mapper.createObjectNode() : mapper.readTree(payload);
        } catch (Exception e) {
            return mapper.createObjectNode();
        }
    }
}
