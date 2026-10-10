package com.selfmusic.backend.meta;

import com.selfmusic.backend.common.ApiResponse;
import com.selfmusic.backend.domain.repository.DeviceRepository;
import com.selfmusic.backend.domain.repository.SyncEventRepository;
import com.selfmusic.backend.transcode.TranscodeService;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * 服务端元信息（阶段6，DESIGN §4.1）：
 * {@code GET /api/v1/meta/server} —— 版本、ffmpeg 可用性、转码并发水位、
 * 设备数与事件 cursor。需认证。
 */
@RestController
@RequestMapping("/api/v1/meta")
public class MetaController {

    private final TranscodeService transcodeService;
    private final DeviceRepository deviceRepository;
    private final SyncEventRepository syncEventRepository;

    public MetaController(TranscodeService transcodeService,
                          DeviceRepository deviceRepository,
                          SyncEventRepository syncEventRepository) {
        this.transcodeService = transcodeService;
        this.deviceRepository = deviceRepository;
        this.syncEventRepository = syncEventRepository;
    }

    @GetMapping("/server")
    public ApiResponse<Map<String, Object>> server() {
        Map<String, Object> data = new LinkedHashMap<>();
        data.put("version", appVersion());
        data.put("ffmpegAvailable", transcodeService.isFfmpegAvailable());
        data.put("transcodeMaxConcurrency", transcodeService.getMaxConcurrency());
        data.put("transcodeActive", transcodeService.activeCount());
        data.put("deviceCount", deviceRepository.count());
        data.put("eventCursor", syncEventRepository.maxSeq());
        return ApiResponse.ok(data);
    }

    private static String appVersion() {
        String v = MetaController.class.getPackage().getImplementationVersion();
        return v != null ? v : "dev";
    }
}
