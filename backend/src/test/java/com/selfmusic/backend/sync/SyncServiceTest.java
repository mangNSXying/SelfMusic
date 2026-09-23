package com.selfmusic.backend.sync;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.selfmusic.backend.common.BizException;
import com.selfmusic.backend.domain.entity.SongState;
import com.selfmusic.backend.domain.entity.SyncEvent;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.LocalDateTime;

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
}
