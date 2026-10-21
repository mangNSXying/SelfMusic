package com.selfmusic.backend.sync;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.selfmusic.backend.domain.entity.PlayState;
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
import com.selfmusic.backend.domain.service.SettingService;
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
    private final SettingService settings = mock(SettingService.class);

    private SyncService service() {
        when(syncEvents.findByEventUuid(any())).thenReturn(Optional.empty());
        when(devices.findByClientId(any())).thenReturn(Optional.empty());
        when(settings.get("sync.server_epoch", "")).thenReturn("test-epoch");
        return new SyncService(syncEvents, songStates, syncSources, playlists,
                items, playStates, devices, settings, mapper);
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
    @SuppressWarnings("unchecked")
    void breakpointAppendMergesServerBranchEvenWhenEventIsOlder() {
        Playlist pl = playlistRow();
        PlayState st = new PlayState();
        st.setPlaylistId(7L);
        st.setSource("webdav");
        st.setSourceRef("/b.mp3");
        st.setDeviceClientId("dev-b");
        st.setPositionMs(1000);
        st.setLastEventAt(T2);
        st.setDeepListJson(deepJson("/a.mp3", "/b.mp3", "/s.mp3"));
        when(playlists.findByClientUuid("p-1")).thenReturn(Optional.of(pl));
        when(playStates.findById(7L)).thenReturn(Optional.of(st));
        when(items.countByPlaylistId(7L)).thenReturn(4L);
        when(playStates.save(any(PlayState.class))).thenAnswer(i -> i.getArgument(0));

        ObjectNode p = mapper.createObjectNode();
        p.put("playlist_uuid", "p-1");
        p.put("source", "webdav");
        p.put("source_ref", "/d.mp3");
        p.put("position_ms", 42000);
        p.set("deep_list", deepArray("/a.mp3", "/b.mp3", "/d.mp3"));
        p.set("deep_added", deepArray("/d.mp3"));
        // 事件时间早于服务端（离线设备后同步）：深层列表仍必须合并，不丢分支。
        Map<String, Object> out = service().push("dev-a",
                List.of(event("e1", SyncEventTypes.BREAKPOINT_SET, T1, p)));

        assertEquals(List.of("e1"), out.get("applied"));
        assertEquals(List.of("/a.mp3", "/b.mp3", "/s.mp3", "/d.mp3"),
                deepRefs(st.getDeepListJson()));
        assertTrue(st.getLastEventAt().isAfter(T2), "合并时钟不得小于两边");
        Map<String, Object> merged = (Map<String, Object>) out.get("merged");
        assertNotNull(merged.get("e1"), "服务端分支变化应回 merged 快照");
        Map<String, Object> snap = (Map<String, Object>) merged.get("e1");
        assertEquals(42000, snap.get("position_ms"));
    }

    @Test
    @SuppressWarnings("unchecked")
    void breakpointBaseMergeKeepsBothBranchesAndDeviceTail() {
        Playlist pl = playlistRow();
        PlayState st = new PlayState();
        st.setPlaylistId(7L);
        st.setSourceRef("/b.mp3");
        st.setLastEventAt(T2);
        st.setDeepListJson(deepJson("/a.mp3", "/b.mp3", "/s.mp3"));
        when(playlists.findByClientUuid("p-1")).thenReturn(Optional.of(pl));
        when(playStates.findById(7L)).thenReturn(Optional.of(st));
        when(items.countByPlaylistId(7L)).thenReturn(10L);
        when(playStates.save(any(PlayState.class))).thenAnswer(i -> i.getArgument(0));

        ObjectNode p = mapper.createObjectNode();
        p.put("playlist_uuid", "p-1");
        p.put("source", "webdav");
        p.put("source_ref", "/d.mp3");
        p.put("position_ms", 5000);
        p.set("base_deep_list", deepArray("/a.mp3", "/b.mp3"));
        p.set("deep_list", deepArray("/a.mp3", "/b.mp3", "/d.mp3"));
        Map<String, Object> out = service().push("dev-a",
                List.of(event("e1", SyncEventTypes.BREAKPOINT_SET, T1, p)));

        assertEquals(List.of("e1"), out.get("applied"));
        assertEquals(List.of("/a.mp3", "/b.mp3", "/s.mp3", "/d.mp3"),
                deepRefs(st.getDeepListJson()));
        Map<String, Object> merged = (Map<String, Object>) out.get("merged");
        assertNotNull(merged.get("e1"));
    }

    @Test
    @SuppressWarnings("unchecked")
    void breakpointPositionOnlyKeepsServerHistoryAndUsesLww() {
        Playlist pl = playlistRow();
        PlayState st = new PlayState();
        st.setPlaylistId(7L);
        st.setSourceRef("/b.mp3");
        st.setLastEventAt(T2);
        st.setDeepListJson(deepJson("/a.mp3", "/b.mp3"));
        when(playlists.findByClientUuid("p-1")).thenReturn(Optional.of(pl));
        when(playStates.findById(7L)).thenReturn(Optional.of(st));
        when(items.countByPlaylistId(7L)).thenReturn(10L);
        when(playStates.save(any(PlayState.class))).thenAnswer(i -> i.getArgument(0));

        ObjectNode p = mapper.createObjectNode();
        p.put("playlist_uuid", "p-1");
        p.put("source", "webdav");
        p.put("source_ref", "/stale.mp3");
        p.put("position_ms", 1);
        p.set("deep_list", deepArray("/a.mp3", "/stale.mp3"));
        p.set("deep_added", mapper.createArrayNode());
        Map<String, Object> out = service().push("dev-a",
                List.of(event("e1", SyncEventTypes.BREAKPOINT_SET, T1, p)));

        assertEquals(List.of("e1"), out.get("applied"));
        assertEquals(List.of("/a.mp3", "/b.mp3"), deepRefs(st.getDeepListJson()),
                "空后缀只更新位置，不得用落后的全量覆盖服务端历史");
        assertTrue(((Map<String, Object>) out.get("corrections")).containsKey("e1"));
        assertTrue(((Map<String, Object>) out.get("merged")).isEmpty());
    }

    @Test
    void breakpointAppendUnchangedKeepsClockMonotonic() {
        Playlist pl = playlistRow();
        PlayState st = new PlayState();
        st.setPlaylistId(7L);
        st.setSourceRef("/b.mp3");
        st.setLastEventAt(T2);
        st.setDeepListJson(deepJson("/a.mp3", "/b.mp3"));
        when(playlists.findByClientUuid("p-1")).thenReturn(Optional.of(pl));
        when(playStates.findById(7L)).thenReturn(Optional.of(st));
        when(items.countByPlaylistId(7L)).thenReturn(10L);
        when(playStates.save(any(PlayState.class))).thenAnswer(i -> i.getArgument(0));

        ObjectNode p = mapper.createObjectNode();
        p.put("playlist_uuid", "p-1");
        p.put("source", "webdav");
        p.put("source_ref", "/b.mp3");
        p.put("position_ms", 6000);
        p.set("deep_list", deepArray("/a.mp3", "/b.mp3"));
        p.set("deep_added", deepArray("/b.mp3"));
        // 离线旧事件、历史结果与来件相同：仍接受当前曲/进度，但时钟不能回退。
        Map<String, Object> out = service().push("dev-a",
                List.of(event("e1", SyncEventTypes.BREAKPOINT_SET, T1, p)));

        assertEquals(List.of("e1"), out.get("applied"));
        assertEquals(List.of("/a.mp3", "/b.mp3"), deepRefs(st.getDeepListJson()));
        assertEquals(6000, st.getPositionMs());
        assertTrue(st.getLastEventAt().isAfter(T2), "历史未变也不能把 last_event_at 回退");
        assertTrue(((Map<String, Object>) out.get("merged")).isEmpty());
    }

    @Test
    @SuppressWarnings("unchecked")
    void breakpointPositionOnlyWinsReturnsMergedWhenServerHasOtherBranch() {
        Playlist pl = playlistRow();
        PlayState st = new PlayState();
        st.setPlaylistId(7L);
        st.setSourceRef("/b.mp3");
        st.setLastEventAt(T1);
        st.setDeepListJson(deepJson("/a.mp3", "/b.mp3", "/s.mp3"));
        when(playlists.findByClientUuid("p-1")).thenReturn(Optional.of(pl));
        when(playStates.findById(7L)).thenReturn(Optional.of(st));
        when(items.countByPlaylistId(7L)).thenReturn(10L);
        when(playStates.save(any(PlayState.class))).thenAnswer(i -> i.getArgument(0));

        ObjectNode p = mapper.createObjectNode();
        p.put("playlist_uuid", "p-1");
        p.put("source", "webdav");
        p.put("source_ref", "/b.mp3");
        p.put("position_ms", 7777);
        p.set("deep_list", deepArray("/a.mp3", "/b.mp3"));
        p.set("deep_added", mapper.createArrayNode());
        Map<String, Object> out = service().push("dev-a",
                List.of(event("e1", SyncEventTypes.BREAKPOINT_SET, T3, p)));

        assertEquals(List.of("e1"), out.get("applied"));
        assertEquals(List.of("/a.mp3", "/b.mp3", "/s.mp3"),
                deepRefs(st.getDeepListJson()), "位置更新不得覆盖服务端历史");
        assertEquals(7777, st.getPositionMs());
        assertTrue(((Map<String, Object>) out.get("corrections")).isEmpty());
        Map<String, Object> merged = (Map<String, Object>) out.get("merged");
        assertNotNull(merged.get("e1"), "服务端有另一分支时应回 merged，设备才能补齐历史");
        Map<String, Object> snap = (Map<String, Object>) merged.get("e1");
        assertEquals(7777, snap.get("position_ms"));
    }

    private ObjectNode v2Payload(String ref, String intent, String clock,
                                 String session, int pos, boolean playing,
                                 ArrayNode base, ArrayNode deep) {
        ObjectNode p = mapper.createObjectNode();
        p.put("protocol", 2);
        p.put("playlist_uuid", "p-1");
        p.put("op_id", "op-" + clock);
        p.put("op_clock", clock);
        p.put("intent", intent);
        p.put("source", "webdav");
        p.put("source_ref", ref);
        p.put("position_ms", pos);
        ObjectNode head = mapper.createObjectNode();
        head.put("source", "webdav");
        head.put("source_ref", ref);
        head.put("position_ms", pos);
        head.put("playing", playing);
        if (session != null) head.put("session_id", session);
        p.set("head", head);
        p.put("deep_list", deep);
        p.put("base_deep_list", base);
        return p;
    }

    @Test
    @SuppressWarnings("unchecked")
    void breakpointV2NewerPlayWinsAndHistoryMerges() {
        Playlist pl = playlistRow();
        PlayState st = new PlayState();
        st.setPlaylistId(7L);
        st.setSourceRef("/b.mp3");
        st.setDeviceClientId("dev-b");
        st.setHeadDevice("dev-b");
        st.setHeadSession("s-b");
        st.setHeadClock("1000-0");
        st.setHeadRev(1L);
        st.setHistoryRev(1L);
        st.setHeadPlaying(true);
        st.setDeepListJson(deepJson("/a.mp3", "/b.mp3"));
        when(playlists.findByClientUuid("p-1")).thenReturn(Optional.of(pl));
        when(playStates.findById(7L)).thenReturn(Optional.of(st));
        when(items.countByPlaylistId(7L)).thenReturn(10L);
        when(playStates.save(any(PlayState.class))).thenAnswer(i -> i.getArgument(0));

        ObjectNode p = v2Payload("/c.mp3", "play_track", "2000-0", "s-a", 9000,
                true, deepArray("/a.mp3", "/b.mp3"),
                deepArray("/a.mp3", "/b.mp3", "/c.mp3"));
        Map<String, Object> out = service().push("dev-a",
                List.of(event("e1", SyncEventTypes.BREAKPOINT_SET, T1, p)));

        assertEquals(List.of("e1"), out.get("applied"));
        assertEquals("/c.mp3", st.getSourceRef(), "最后一次真实播放操作赢");
        assertEquals("dev-a", st.getHeadDevice());
        assertEquals("s-a", st.getHeadSession());
        assertEquals(2L, st.getHeadRev());
        assertEquals(List.of("/a.mp3", "/b.mp3", "/c.mp3"),
                deepRefs(st.getDeepListJson()));
        assertTrue(((Map<String, Object>) out.get("corrections")).isEmpty());
        Map<String, Object> bps = (Map<String, Object>) out.get("breakpoints");
        assertNotNull(bps.get("p-1"), "v2 回执按 playlist 回权威快照");
        Map<String, Object> snap = (Map<String, Object>) bps.get("p-1");
        assertEquals("/c.mp3", snap.get("source_ref"));
        assertEquals(2L, snap.get("head_rev"));
    }

    @Test
    @SuppressWarnings("unchecked")
    void breakpointV2OlderPauseLosesButHistoryStillMerges() {
        Playlist pl = playlistRow();
        PlayState st = new PlayState();
        st.setPlaylistId(7L);
        st.setSourceRef("/b.mp3");
        st.setDeviceClientId("dev-b");
        st.setHeadDevice("dev-b");
        st.setHeadSession("s-b");
        st.setHeadClock("3000-0");
        st.setHeadRev(4L);
        st.setHistoryRev(2L);
        st.setHeadPlaying(true);
        st.setPositionMs(1000);
        st.setDeepListJson(deepJson("/a.mp3", "/b.mp3", "/s.mp3"));
        when(playlists.findByClientUuid("p-1")).thenReturn(Optional.of(pl));
        when(playStates.findById(7L)).thenReturn(Optional.of(st));
        when(items.countByPlaylistId(7L)).thenReturn(10L);
        when(playStates.save(any(PlayState.class))).thenAnswer(i -> i.getArgument(0));

        // 离线设备后到：head 很旧，但它听过的 /d.mp3 不能丢。
        ObjectNode p = v2Payload("/d.mp3", "play_track", "1000-0", "s-a", 42000,
                true, deepArray("/a.mp3", "/b.mp3"),
                deepArray("/a.mp3", "/b.mp3", "/d.mp3"));
        Map<String, Object> out = service().push("dev-a",
                List.of(event("e1", SyncEventTypes.BREAKPOINT_SET, T2, p)));

        assertEquals("/b.mp3", st.getSourceRef(), "旧 head 不能覆盖新 head");
        assertEquals("dev-b", st.getHeadDevice());
        assertEquals(4L, st.getHeadRev(), "head 判输不递增 head_rev");
        assertEquals(List.of("/a.mp3", "/b.mp3", "/s.mp3", "/d.mp3"),
                deepRefs(st.getDeepListJson()), "对端历史仍必须并入");
        assertTrue(st.getHistoryRev() > 2L);
        Map<String, Object> snap = (Map<String, Object>)
                ((Map<String, Object>) out.get("breakpoints")).get("p-1");
        assertEquals("/b.mp3", snap.get("source_ref"));
        assertEquals(4L, snap.get("head_rev"));
    }

    @Test
    @SuppressWarnings("unchecked")
    void breakpointV2ProgressFromNonHeadDeviceIsIgnored() {
        Playlist pl = playlistRow();
        PlayState st = new PlayState();
        st.setPlaylistId(7L);
        st.setSourceRef("/b.mp3");
        st.setDeviceClientId("dev-b");
        st.setHeadDevice("dev-b");
        st.setHeadSession("s-b");
        st.setHeadClock("1000-0");
        st.setHeadRev(2L);
        st.setHistoryRev(2L);
        st.setPositionMs(1000);
        st.setDeepListJson(deepJson("/a.mp3", "/b.mp3"));
        when(playlists.findByClientUuid("p-1")).thenReturn(Optional.of(pl));
        when(playStates.findById(7L)).thenReturn(Optional.of(st));
        when(items.countByPlaylistId(7L)).thenReturn(10L);
        when(playStates.save(any(PlayState.class))).thenAnswer(i -> i.getArgument(0));

        ObjectNode p = v2Payload("/b.mp3", "progress", "9999-0", "s-b", 8000,
                true, deepArray("/a.mp3", "/b.mp3"),
                deepArray("/a.mp3", "/b.mp3"));
        service().push("dev-a",
                List.of(event("e1", SyncEventTypes.BREAKPOINT_SET, T3, p)));

        assertEquals(1000, st.getPositionMs(), "跟随端/非 head 设备的 progress 不能改进度");
        assertEquals(2L, st.getHeadRev());
    }

    @Test
    @SuppressWarnings("unchecked")
    void breakpointV2ProgressDoesNotAdvanceHeadClock() {
        Playlist pl = playlistRow();
        PlayState st = new PlayState();
        st.setPlaylistId(7L);
        st.setSourceRef("/b.mp3");
        st.setDeviceClientId("dev-a");
        st.setHeadDevice("dev-a");
        st.setHeadSession("s-a");
        st.setHeadClock("1000-0");
        st.setHeadOpId("op-play-a");
        st.setHeadRev(2L);
        st.setHistoryRev(2L);
        st.setPositionMs(1000);
        st.setDeepListJson(deepJson("/a.mp3", "/b.mp3"));
        when(playlists.findByClientUuid("p-1")).thenReturn(Optional.of(pl));
        when(playStates.findById(7L)).thenReturn(Optional.of(st));
        when(items.countByPlaylistId(7L)).thenReturn(10L);
        when(playStates.save(any(PlayState.class))).thenAnswer(i -> i.getArgument(0));

        ObjectNode progress = v2Payload("/b.mp3", "progress", "5000-0", "s-a", 5000,
                true, deepArray("/a.mp3", "/b.mp3"),
                deepArray("/a.mp3", "/b.mp3"));
        service().push("dev-a",
                List.of(event("e1", SyncEventTypes.BREAKPOINT_SET, T1, progress)));
        assertEquals(5000, st.getPositionMs());
        assertEquals("1000-0", st.getHeadClock(), "progress 不得把 head 操作时钟推高");
        assertEquals("op-play-a", st.getHeadOpId());

        // 另一台设备在「原 play 之后、心跳之前」的真实操作：时钟 3000 仍应胜出。
        ObjectNode play = v2Payload("/c.mp3", "play_track", "3000-0", "s-b", 0,
                true, deepArray("/a.mp3", "/b.mp3"),
                deepArray("/a.mp3", "/b.mp3", "/c.mp3"));
        PushEvent playEvent = new PushEvent("e2", "dev-b",
                SyncEventTypes.BREAKPOINT_SET, T2, play);
        service().push("dev-b", List.of(playEvent));
        assertEquals("/c.mp3", st.getSourceRef(), "心跳不能让稍早的真实操作误判为旧");
        assertEquals(4L, st.getHeadRev());
    }

    @Test
    @SuppressWarnings("unchecked")
    void breakpointV2PauseOnHeadSessionAccepted() {
        Playlist pl = playlistRow();
        PlayState st = new PlayState();
        st.setPlaylistId(7L);
        st.setSourceRef("/b.mp3");
        st.setDeviceClientId("dev-a");
        st.setHeadDevice("dev-a");
        st.setHeadSession("s-a");
        st.setHeadClock("1000-0");
        st.setHeadRev(2L);
        st.setHistoryRev(2L);
        st.setHeadPlaying(true);
        st.setDeepListJson(deepJson("/a.mp3", "/b.mp3"));
        when(playlists.findByClientUuid("p-1")).thenReturn(Optional.of(pl));
        when(playStates.findById(7L)).thenReturn(Optional.of(st));
        when(items.countByPlaylistId(7L)).thenReturn(10L);
        when(playStates.save(any(PlayState.class))).thenAnswer(i -> i.getArgument(0));

        ObjectNode p = v2Payload("/b.mp3", "pause", "2000-0", "s-a", 5500,
                false, deepArray("/a.mp3", "/b.mp3"),
                deepArray("/a.mp3", "/b.mp3"));
        service().push("dev-a",
                List.of(event("e1", SyncEventTypes.BREAKPOINT_SET, T2, p)));

        assertEquals(5500, st.getPositionMs());
        assertEquals(false, st.getHeadPlaying());
        assertEquals(3L, st.getHeadRev());
        assertEquals("s-a", st.getHeadSession());
    }

    private ArrayNode deepArray(String... refs) {
        ArrayNode arr = mapper.createArrayNode();
        for (String ref : refs) {
            ObjectNode e = mapper.createObjectNode();
            e.put("source", "webdav");
            e.put("source_ref", ref);
            arr.add(e);
        }
        return arr;
    }

    private String deepJson(String... refs) {
        return deepArray(refs).toString();
    }

    private static List<String> deepRefs(String json) {
        return SyncService.parseDeepNodes(json).stream()
                .map(SyncService::deepRef).toList();
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
