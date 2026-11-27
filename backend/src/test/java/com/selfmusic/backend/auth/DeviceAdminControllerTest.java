package com.selfmusic.backend.auth;

import com.selfmusic.backend.common.BizException;
import com.selfmusic.backend.domain.entity.Device;
import com.selfmusic.backend.domain.repository.DeviceRepository;
import com.selfmusic.backend.sync.BreakpointPushHub;
import org.junit.jupiter.api.Test;

import java.util.Optional;

import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

/**
 * DELETE /api/v1/admin/devices/{id}/purge：只允许永久删除已吊销设备。
 */
class DeviceAdminControllerTest {

    private final DeviceRepository repo = mock(DeviceRepository.class);

    private DeviceAdminController controller() {
        return new DeviceAdminController(repo, mock(BreakpointPushHub.class));
    }

    private static Device device(boolean revoked) {
        Device d = new Device();
        d.setId(7L);
        d.setName("test");
        d.setRevoked(revoked);
        return d;
    }

    @Test
    void purgeDeletesRevokedDevice() {
        Device d = device(true);
        when(repo.findById(7L)).thenReturn(Optional.of(d));

        controller().purge(7L);

        verify(repo).delete(d);
    }

    @Test
    void purgeRejectsActiveDevice() {
        Device d = device(false);
        when(repo.findById(7L)).thenReturn(Optional.of(d));

        assertThrows(BizException.class, () -> controller().purge(7L));
        verify(repo, never()).delete(any());
    }

    @Test
    void purgeRejectsMissingDevice() {
        when(repo.findById(7L)).thenReturn(Optional.empty());

        assertThrows(BizException.class, () -> controller().purge(7L));
        verify(repo, never()).delete(any());
    }
}
