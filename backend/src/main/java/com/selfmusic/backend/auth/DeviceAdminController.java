package com.selfmusic.backend.auth;

import com.selfmusic.backend.common.ApiResponse;
import com.selfmusic.backend.common.BizException;
import com.selfmusic.backend.domain.entity.Device;
import com.selfmusic.backend.domain.repository.DeviceRepository;
import org.springframework.web.bind.annotation.*;

import java.util.List;
import java.util.Map;

@RestController
@RequestMapping("/api/v1/admin/devices")
public class DeviceAdminController {

    private final DeviceRepository deviceRepository;

    public DeviceAdminController(DeviceRepository deviceRepository) {
        this.deviceRepository = deviceRepository;
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
        return ApiResponse.ok();
    }
}
