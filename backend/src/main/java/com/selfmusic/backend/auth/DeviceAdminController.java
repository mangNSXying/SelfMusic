package com.selfmusic.backend.auth;

import com.selfmusic.backend.common.ApiResponse;
import com.selfmusic.backend.common.BizException;
import com.selfmusic.backend.domain.entity.Device;
import com.selfmusic.backend.domain.repository.DeviceRepository;
import com.selfmusic.backend.sync.BreakpointPushHub;
import org.springframework.web.bind.annotation.*;

import java.util.List;
import java.util.Map;

@RestController
@RequestMapping("/api/v1/admin/devices")
public class DeviceAdminController {

    private final DeviceRepository deviceRepository;
    private final BreakpointPushHub pushHub;

    public DeviceAdminController(DeviceRepository deviceRepository,
                                 BreakpointPushHub pushHub) {
        this.deviceRepository = deviceRepository;
        this.pushHub = pushHub;
    }

    @GetMapping
    public ApiResponse<List<Device>> list() {
        return ApiResponse.ok(deviceRepository.findAll());
    }

    @PutMapping("/{id}")
    public ApiResponse<Void> rename(@PathVariable Long id, @RequestBody Map<String, String> body) {
        Device d = deviceRepository.findById(id)
                .orElseThrow(() -> new BizException(40401, "device not found"));
        d.setName(body.getOrDefault("name", d.getName()));
        deviceRepository.save(d);
        return ApiResponse.ok();
    }

    @DeleteMapping("/{id}")
    public ApiResponse<Void> revoke(@PathVariable Long id) {
        Device d = deviceRepository.findById(id)
                .orElseThrow(() -> new BizException(40401, "device not found"));
        d.setRevoked(true);
        deviceRepository.save(d);
        // 已吊销设备不再接收断点推送。
        pushHub.disconnect(d.getClientId());
        return ApiResponse.ok();
    }

    /**
     * 永久删除设备记录：仅允许删除已吊销设备。
     *
     * <p>吊销保留记录用于同步水位等计算；硬删除只清理已失效条目。
     * 未吊销设备直接删除会抹掉其令牌，故要求先走 {@link #revoke(Long)}。</p>
     */
    @DeleteMapping("/{id}/purge")
    public ApiResponse<Void> purge(@PathVariable Long id) {
        Device d = deviceRepository.findById(id)
                .orElseThrow(() -> new BizException(40401, "device not found"));
        if (!d.isRevoked()) {
            throw new BizException(40901, "device must be revoked before purge");
        }
        deviceRepository.delete(d);
        return ApiResponse.ok();
    }
}
