package com.selfmusic.backend.playlist;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.selfmusic.backend.common.ApiResponse;
import com.selfmusic.backend.domain.entity.PlayState;
import com.selfmusic.backend.domain.entity.Playlist;
import com.selfmusic.backend.domain.repository.PlaylistRepository;
import com.selfmusic.backend.domain.repository.PlayStateRepository;
import com.selfmusic.backend.sync.SyncService;
import org.junit.jupiter.api.Test;

import java.time.LocalDateTime;
import java.util.Map;
import java.util.Optional;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

/**
 * GET /api/v1/playstates/latest（DEVELOPER.md「播放算法与同步协议」 断点快路径）：
 * 返回全局最新一行 play_state 的快照；空表 / 歌单缺失 / 已删 / 无 client_uuid
 * 一律 data=null（客户端静默回退到 pull）。
 */
class PlayStateControllerTest {

    private final PlaylistRepository playlistRepository = mock(PlaylistRepository.class);
    private final PlayStateRepository playStateRepository = mock(PlayStateRepository.class);
    private final SyncService syncService = mock(SyncService.class);

    private PlayStateController controller() {
        return new PlayStateController(playlistRepository, playStateRepository,
                syncService, new ObjectMapper());
    }

    private static PlayState state(long playlistId, int positionMs) {
        PlayState st = new PlayState();
        st.setPlaylistId(playlistId);
        st.setSourceId("webdav:NAS");
        st.setSource("webdav");
        st.setSourceRef("dav:/a.mp3");
        st.setDeviceClientId("dev-a");
        st.setPositionMs(positionMs);
        st.setUpdatedAt(LocalDateTime.of(2026, 10, 9, 12, 0, 0));
        return st;
    }

    private static Playlist playlist(String clientUuid, boolean deleted) {
        Playlist p = new Playlist();
        p.setName("歌单");
        p.setClientUuid(clientUuid);
        p.setDeleted(deleted);
        return p;
    }

    @SuppressWarnings("unchecked")
    private Map<String, Object> latest() {
        ApiResponse<Map<String, Object>> resp = controller().latest();
        return resp.getData();
    }

    @Test
    void returnsLatestPlaystateSnapshot() {
        when(playStateRepository.findTopByOrderByUpdatedAtDescPlaylistIdDesc())
                .thenReturn(Optional.of(state(7, 42000)));
        when(playlistRepository.findById(7L))
                .thenReturn(Optional.of(playlist("pl-uuid", false)));

        Map<String, Object> data = latest();
        assertNotNull(data);
        assertEquals("pl-uuid", data.get("client_uuid"));
        assertEquals(42000, data.get("position_ms"));
        assertEquals("dav:/a.mp3", data.get("source_ref"));
        assertEquals("2026-10-09T12:00", data.get("updated_at"));
    }

    @Test
    void returnsNullWhenNoRows() {
        when(playStateRepository.findTopByOrderByUpdatedAtDescPlaylistIdDesc())
                .thenReturn(Optional.empty());
        assertNull(latest());
    }

    @Test
    void returnsNullWhenPlaylistMissing() {
        when(playStateRepository.findTopByOrderByUpdatedAtDescPlaylistIdDesc())
                .thenReturn(Optional.of(state(7, 42000)));
        when(playlistRepository.findById(7L)).thenReturn(Optional.empty());
        assertNull(latest());
    }

    @Test
    void returnsNullWhenPlaylistDeleted() {
        when(playStateRepository.findTopByOrderByUpdatedAtDescPlaylistIdDesc())
                .thenReturn(Optional.of(state(7, 42000)));
        when(playlistRepository.findById(7L))
                .thenReturn(Optional.of(playlist("pl-uuid", true)));
        assertNull(latest());
    }

    @Test
    void returnsNullWhenPlaylistNotSyncable() {
        when(playStateRepository.findTopByOrderByUpdatedAtDescPlaylistIdDesc())
                .thenReturn(Optional.of(state(7, 42000)));
        when(playlistRepository.findById(7L))
                .thenReturn(Optional.of(playlist(null, false)));
        assertNull(latest());
    }
}
