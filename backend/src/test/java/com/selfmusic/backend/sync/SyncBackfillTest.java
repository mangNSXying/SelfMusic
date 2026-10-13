package com.selfmusic.backend.sync;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.selfmusic.backend.domain.entity.Playlist;
import com.selfmusic.backend.domain.entity.PlaylistItem;
import com.selfmusic.backend.domain.entity.SongState;
import com.selfmusic.backend.domain.entity.SyncSource;
import com.selfmusic.backend.domain.repository.DeviceRepository;
import com.selfmusic.backend.domain.repository.PlayStateRepository;
import com.selfmusic.backend.domain.repository.PlaylistItemRepository;
import com.selfmusic.backend.domain.repository.PlaylistRepository;
import com.selfmusic.backend.domain.repository.SongStateRepository;
import com.selfmusic.backend.domain.repository.SyncEventRepository;
import com.selfmusic.backend.domain.repository.SyncSourceRepository;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.List;
import java.util.Map;
import java.util.Optional;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

/**
 * 补录事件（backfill:true，配对前存量补推）“只建行、不赢现行行”：
 * 首配空库照常建；重配旧设备不再冲掉现行数据，判输回 correction 自纠。
 * 另覆盖 push/pull 回包的 `server_time`（客户端时钟校准用）。
 */
class SyncBackfillTest {

    private final ObjectMapper mapper = new ObjectMapper();
    private final SyncEventRepository syncEvents = mock(SyncEventRepository.class);
    private final SongStateRepository songStates = mock(SongStateRepository.class);
    private final SyncSourceRepository syncSources = mock(SyncSourceRepository.class);
    private final PlaylistRepository playlists = mock(PlaylistRepository.class);
    private final PlaylistItemRepository items = mock(PlaylistItemRepository.class);
    private final PlayStateRepository playStates = mock(PlayStateRepository.class);
    private final DeviceRepository devices = mock(DeviceRepository.class);

    private SyncService service() {
        when(syncEvents.findByEventUuid(any())).thenReturn(Optional.empty());
        when(devices.findByClientId(any())).thenReturn(Optional.empty());
        return new SyncService(syncEvents, songStates, syncSources, playlists,
                items, playStates, devices, mapper);
    }

    private static final LocalDateTime T1 = LocalDateTime.of(2026, 1, 1, 0, 0, 0);
    private static final LocalDateTime T2 = LocalDateTime.of(2026, 6, 1, 0, 0, 0);
    private static final LocalDateTime T3 = LocalDateTime.of(2026, 10, 1, 0, 0, 0);

    private PushEvent event(String uuid, String type, LocalDateTime at, ObjectNode payload) {
        return new PushEvent(uuid, "dev-a", type, at, payload);
    }

    private ObjectNode songPayload(boolean backfill) {
        ObjectNode p = mapper.createObjectNode();
        if (backfill) p.put("backfill", true);
        p.put("source_id", "u1");
        p.put("source", "webdav");
        p.put("source_ref", "/a.mp3");
        p.put("like_streak", 0);
        p.put("dislike_streak", 0);
        p.put("weight", 1.5);
        p.put("frozen", false);
        p.put("is_favorite", true);
        p.put("play_sec", 600);
        return p;
    }

    private static SongState songRow(LocalDateTime lastEventAt) {
        SongState s = new SongState();
        s.setSourceId("u1");
        s.setSource("webdav");
        s.setSourceRef("/a.mp3");
        s.setLikeStreak(0);
        s.setDislikeStreak(0);
        s.setWeight(BigDecimal.ONE);
        s.setFrozen(false);
        s.setFavorite(false);
        s.setPlaySec(100);
        s.setLastEventAt(lastEventAt);
        return s;
    }

    @Test
    void isBackfillFlag() {
        assertFalse(SyncService.isBackfill(null));
        assertFalse(SyncService.isBackfill(mapper.createObjectNode()));
        ObjectNode p = mapper.createObjectNode();
        p.put("backfill", true);
        assertTrue(SyncService.isBackfill(p));
    }

    @Test
    @SuppressWarnings("unchecked")
    void backfillSongStateLosesToExistingRow() {
        // 现行行（别机 T2 新操作）vs 补录旧值（occurred fillable T3 最新也判输）。
        when(songStates.findBySourceIdAndSourceRef("u1", "/a.mp3"))
                .thenReturn(Optional.of(songRow(T2)));
        Map<String, Object> out = service().push("dev-a",
                List.of(event("e1", SyncEventTypes.SONG_STATE, T3, songPayload(true))));

        assertEquals(List.of("e1"), out.get("applied"));
        Map<String, Object> corrections = (Map<String, Object>) out.get("corrections");
        assertTrue(corrections.containsKey("e1"), "补录判输应回现行快照自纠");
        Map<String, Object> snap = (Map<String, Object>) corrections.get("e1");
        assertEquals(false, snap.get("is_favorite"), "快照是现行行（未被旧值覆盖）");
        // 行未被碰过：连 play_sec 的 max 合并都不该发生。
        verify(songStates, never()).save(any(SongState.class));
    }

    @Test
    @SuppressWarnings("unchecked")
    void backfillSongStateBuildsMissingRow() {
        // 首配空库：行不存在 → 正常建行（provision），无 correction。
        when(songStates.findBySourceIdAndSourceRef(any(), any()))
                .thenReturn(Optional.empty());
        when(songStates.save(any(SongState.class)))
                .thenAnswer(i -> i.getArgument(0));
        Map<String, Object> out = service().push("dev-a",
                List.of(event("e1", SyncEventTypes.SONG_STATE, T3, songPayload(true))));

        assertEquals(List.of("e1"), out.get("applied"));
        assertTrue(((Map<String, Object>) out.get("corrections")).isEmpty());
    }

    @Test
    @SuppressWarnings("unchecked")
    void normalSongStateStillWinsByLww() {
        // 对照组：非补录事件仍走 LWW（T3 > T2 胜出，无 correction）。
        SongState row = songRow(T2);
        when(songStates.findBySourceIdAndSourceRef("u1", "/a.mp3"))
                .thenReturn(Optional.of(row));
        when(songStates.save(any(SongState.class)))
                .thenAnswer(i -> i.getArgument(0));
        Map<String, Object> out = service().push("dev-a",
                List.of(event("e1", SyncEventTypes.SONG_STATE, T3, songPayload(false))));

        assertEquals(List.of("e1"), out.get("applied"));
        assertTrue(((Map<String, Object>) out.get("corrections")).isEmpty());
        assertTrue(row.isFavorite(), "LWW 胜出应落库");
    }

    private static Playlist playlistRow() {
        Playlist pl = new Playlist();
        pl.setId(7L);
        pl.setClientUuid("p-1");
        pl.setName("现行名");
        pl.setDeleted(false);
        pl.setLastEventAt(T2);
        return pl;
    }

    @Test
    @SuppressWarnings("unchecked")
    void backfillPlaylistCreateLosesToExisting() {
        when(playlists.findByClientUuid("p-1"))
                .thenReturn(Optional.of(playlistRow()));
        when(items.findByPlaylistIdOrderBySortOrderAsc(7L)).thenReturn(List.of());
        ObjectNode p = mapper.createObjectNode();
        p.put("backfill", true);
        p.put("client_uuid", "p-1");
        p.put("name", "旧名");
        Map<String, Object> out = service().push("dev-a",
                List.of(event("e1", SyncEventTypes.PLAYLIST_CREATE, T3, p)));

        assertEquals(List.of("e1"), out.get("applied"));
        Map<String, Object> corrections = (Map<String, Object>) out.get("corrections");
        Map<String, Object> snap = (Map<String, Object>) corrections.get("e1");
        assertNotNull(snap, "补录 create 撞现行歌单应判输回快照");
        assertEquals("现行名", snap.get("name"));
        verify(playlists, never()).save(any(Playlist.class));
    }

    @Test
    @SuppressWarnings("unchecked")
    void backfillItemAddSkipsExistingEntry() {
        Playlist pl = playlistRow();
        when(playlists.findByClientUuid("p-1")).thenReturn(Optional.of(pl));
        PlaylistItem existing = new PlaylistItem();
        existing.setPlaylist(pl);
        when(items.findByPlaylistIdAndSourceIdAndSourceRef(any(), any(), any()))
                .thenReturn(Optional.of(existing));
        ObjectNode p = mapper.createObjectNode();
        p.put("backfill", true);
        p.put("playlist_uuid", "p-1");
        p.put("source_id", "u1");
        p.put("source", "webdav");
        p.put("source_ref", "/a.mp3");
        p.put("title", "旧标题");
        Map<String, Object> out = service().push("dev-a",
                List.of(event("e1", SyncEventTypes.PLAYLIST_ITEM_ADD, T3, p)));

        assertEquals(List.of("e1"), out.get("applied"));
        assertTrue(((Map<String, Object>) out.get("corrections")).isEmpty());
        // 已存在条目不覆快照：连版本号都不推进。
        verify(items, never()).save(any(PlaylistItem.class));
        verify(playlists, never()).save(any(Playlist.class));
    }

    @Test
    void normalItemAddStillUpserts() {
        Playlist pl = playlistRow();
        when(playlists.findByClientUuid("p-1")).thenReturn(Optional.of(pl));
        when(items.findByPlaylistIdAndSourceIdAndSourceRef(any(), any(), any()))
                .thenReturn(Optional.empty());
        ObjectNode p = mapper.createObjectNode();
        p.put("playlist_uuid", "p-1");
        p.put("source_id", "u1");
        p.put("source", "webdav");
        p.put("source_ref", "/a.mp3");
        p.put("title", "新标题");
        Map<String, Object> out = service().push("dev-a",
                List.of(event("e1", SyncEventTypes.PLAYLIST_ITEM_ADD, T3, p)));

        assertEquals(List.of("e1"), out.get("applied"));
        verify(items).save(any(PlaylistItem.class));
    }

    @Test
    @SuppressWarnings("unchecked")
    void backfillSourceCreateLosesToSameAddress() {
        when(syncSources.findByClientUuid("src-new")).thenReturn(Optional.empty());
        SyncSource same = new SyncSource();
        same.setClientUuid("src-old");
        same.setKind("webdav");
        same.setAddress("https://x/dav");
        same.setName("现行源");
        same.setLastEventAt(T2);
        when(syncSources.findByKindAndAddress("webdav", "https://x/dav"))
                .thenReturn(Optional.of(same));
        ObjectNode p = mapper.createObjectNode();
        p.put("backfill", true);
        p.put("client_uuid", "src-new");
        p.put("kind", "webdav");
        p.put("name", "旧源名");
        p.put("address", "https://x/dav");
        Map<String, Object> out = service().push("dev-a",
                List.of(event("e1", SyncEventTypes.SOURCE_CREATE, T3, p)));

        assertEquals(List.of("e1"), out.get("applied"));
        Map<String, Object> corrections = (Map<String, Object>) out.get("corrections");
        Map<String, Object> snap = (Map<String, Object>) corrections.get("e1");
        assertNotNull(snap, "补录 source 撞同址行应判输回现行快照");
        assertEquals("src-old", snap.get("client_uuid"));
        verify(syncSources, never()).save(any(SyncSource.class));
    }

    @Test
    void pushAndPullCarryServerTime() {
        when(syncEvents.maxSeq()).thenReturn(0L);
        Map<String, Object> pushOut =
                service().push("dev-a", List.of());
        assertServerTime(pushOut);

        when(syncEvents.findTop2000BySeqGreaterThanOrderBySeqAsc(any()))
                .thenReturn(List.of());
        when(devices.minActivePullCursor()).thenReturn(null);
        Map<String, Object> pullOut = service().pull("dev-a", 0L);
        assertServerTime(pullOut);
    }

    private static void assertServerTime(Map<String, Object> out) {
        Object v = out.get("server_time");
        assertInstanceOf(String.class, v, "回包应带 server_time（客户端时钟校准用）");
        // 客户端 DateTime.parse 可读的 ISO-8601。
        assertDoesNotThrow(() -> LocalDateTime.parse((String) v));
    }

    @Test
    void serverTimeNowIsIso8601() {
        assertDoesNotThrow(() -> LocalDateTime.parse(SyncService.serverTimeNow()));
    }
}
