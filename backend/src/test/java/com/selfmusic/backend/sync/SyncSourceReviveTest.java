package com.selfmusic.backend.sync;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
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
import org.junit.jupiter.api.Test;

import java.time.LocalDateTime;
import java.util.List;
import java.util.Map;
import java.util.Optional;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

/**
 * 源墓碑复用：客户端「删除播放源 → 再加回同一地址」时，新 uuid 会撞上服务端
 * 的同址墓碑行（sync_sources.deleted=1）。复用该行时必须把 deleted 清回 false，
 * 否则该源在服务端永远不可见：删源的那台设备本地能留住（client_uuid 不匹配 +
 * deleted 分支 no-op），其它设备却再也收不到这个源。
 */
class SyncSourceReviveTest {

    private final ObjectMapper mapper = new ObjectMapper();
    private final SyncEventRepository syncEvents = mock(SyncEventRepository.class);
    private final SongStateRepository songStates = mock(SongStateRepository.class);
    private final SyncSourceRepository syncSources = mock(SyncSourceRepository.class);
    private final PlaylistRepository playlists = mock(PlaylistRepository.class);
    private final PlaylistItemRepository items = mock(PlaylistItemRepository.class);
    private final PlayStateRepository playStates = mock(PlayStateRepository.class);
    private final DeviceRepository devices = mock(DeviceRepository.class);
    private final SettingService settings = mock(SettingService.class);

    private static final String ADDRESS = "https://dav.example.com/music";
    private static final LocalDateTime T1 = LocalDateTime.of(2026, 1, 1, 0, 0, 0);
    private static final LocalDateTime T2 = LocalDateTime.of(2026, 6, 1, 0, 0, 0);
    private static final LocalDateTime T3 = LocalDateTime.of(2026, 10, 1, 0, 0, 0);

    private SyncService service() {
        when(syncEvents.findByEventUuid(any())).thenReturn(Optional.empty());
        when(devices.findByClientId(any())).thenReturn(Optional.empty());
        when(syncSources.save(any(SyncSource.class))).thenAnswer(i -> i.getArgument(0));
        return new SyncService(syncEvents, songStates, syncSources, playlists,
                items, playStates, devices, settings, mapper);
    }

    private ObjectNode sourcePayload(String uuid, String name) {
        ObjectNode p = mapper.createObjectNode();
        p.put("client_uuid", uuid);
        p.put("kind", "webdav");
        p.put("name", name);
        p.put("address", ADDRESS);
        p.put("enabled", true);
        return p;
    }

    private PushEvent event(String uuid, String type, LocalDateTime at, String clientUuid) {
        return new PushEvent(uuid, "dev-a", type, at,
                sourcePayload(clientUuid, clientUuid + "-name"));
    }

    /** 服务端已存在的源行（未删除，最后一次事件在 T1）。 */
    private static SyncSource liveRow() {
        SyncSource s = new SyncSource();
        s.setId(9L);
        s.setClientUuid("u-old");
        s.setKind("webdav");
        s.setName("NAS");
        s.setAddress(ADDRESS);
        s.setEnabled(true);
        s.setDeleted(false);
        s.setLastEventAt(T1);
        s.setSyncVer(1L);
        return s;
    }

    @Test
    @SuppressWarnings("unchecked")
    void sourceCreateAfterDeleteRevivesTombstone() {
        SyncService svc = service();
        SyncSource row = liveRow();
        when(syncSources.findByClientUuid("u-old")).thenReturn(Optional.of(row));
        when(syncSources.findByClientUuid("u-new")).thenReturn(Optional.empty());
        when(syncSources.findByKindAndAddress("webdav", ADDRESS)).thenReturn(Optional.of(row));

        // 1) 删除：软删打墓碑。
        svc.push("dev-a", List.of(event("e1", SyncEventTypes.SOURCE_DELETE, T2, "u-old")));
        assertTrue(row.isDeleted(), "source.delete 应软删源行");

        // 2) 同址重新添加（新 uuid）：复用墓碑行时必须复活。
        Map<String, Object> out = svc.push("dev-a",
                List.of(event("e2", SyncEventTypes.SOURCE_CREATE, T3, "u-new")));
        assertEquals(List.of("e2"), out.get("applied"));
        assertFalse(row.isDeleted(), "同址重加必须清掉墓碑标记，否则其它设备收不到该源回来");
        assertEquals(T3, row.getLastEventAt());
        // 回执快照的 client_uuid 是服务端权威 uuid（客户端据此重绑本地源标识）。
        Map<String, Object> corrections = (Map<String, Object>) out.get("corrections");
        Map<String, Object> snap = (Map<String, Object>) corrections.get("e2");
        assertNotNull(snap, "复用旧行应收 correction 让事件方重绑 uuid");
        assertEquals("u-old", snap.get("client_uuid"));
        assertEquals(false, snap.get("deleted"));
    }

    @Test
    void deleteStaysIdempotent() {
        SyncService svc = service();
        SyncSource row = liveRow();
        row.setDeleted(true);
        row.setLastEventAt(T2);
        when(syncSources.findByClientUuid("u-old")).thenReturn(Optional.of(row));

        Map<String, Object> out = svc.push("dev-a",
                List.of(event("e1", SyncEventTypes.SOURCE_DELETE, T3, "u-old")));

        assertEquals(List.of("e1"), out.get("applied"));
        // 重复删除幂等 no-op：不递增 sync_ver、不回 correction。
        assertEquals(1L, row.getSyncVer());
        assertEquals(T2, row.getLastEventAt());
        assertTrue(((Map<?, ?>) out.get("corrections")).isEmpty());
    }
}
