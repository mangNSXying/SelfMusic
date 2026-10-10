package com.selfmusic.backend.meta;

import com.selfmusic.backend.common.ApiResponse;
import com.selfmusic.backend.domain.repository.DeviceRepository;
import com.selfmusic.backend.domain.repository.SyncEventRepository;
import com.selfmusic.backend.transcode.TranscodeService;
import org.junit.jupiter.api.Test;

import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

/**
 * GET /api/v1/meta/server：版本/ffmpeg/并发水位/设备数/cursor。
 */
class MetaControllerTest {

    @Test
    void returnsServerMeta() {
        TranscodeService transcode = mock(TranscodeService.class);
        when(transcode.isFfmpegAvailable()).thenReturn(true);
        when(transcode.getMaxConcurrency()).thenReturn(2);
        when(transcode.activeCount()).thenReturn(1);
        DeviceRepository devices = mock(DeviceRepository.class);
        when(devices.count()).thenReturn(3L);
        SyncEventRepository events = mock(SyncEventRepository.class);
        when(events.maxSeq()).thenReturn(42L);

        MetaController c = new MetaController(transcode, devices, events);
        ApiResponse<Map<String, Object>> resp = c.server();
        assertEquals(0, resp.getCode());
        Map<String, Object> d = resp.getData();
        assertEquals(true, d.get("ffmpegAvailable"));
        assertEquals(2, d.get("transcodeMaxConcurrency"));
        assertEquals(1, d.get("transcodeActive"));
        assertEquals(3L, d.get("deviceCount"));
        assertEquals(42L, d.get("eventCursor"));
        assertNotNull(d.get("version"));
    }
}
