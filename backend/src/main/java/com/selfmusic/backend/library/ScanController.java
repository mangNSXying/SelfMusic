package com.selfmusic.backend.library;

import com.selfmusic.backend.common.ApiResponse;
import com.selfmusic.backend.domain.entity.ScanTask;
import com.selfmusic.backend.domain.repository.ScanTaskRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.web.bind.annotation.*;

import java.util.List;

@RestController
@RequestMapping("/api/v1/scan")
@RequiredArgsConstructor
public class ScanController {

    private final MusicScanner musicScanner;
    private final ScanTaskRepository scanTaskRepository;

    @PostMapping
    public ApiResponse<ScanTask> trigger() {
        // 阶段一：同步扫描。文件量小时足够；后续可改异步 + 前端轮询。
        return ApiResponse.ok(musicScanner.scan());
    }

    @GetMapping
    public ApiResponse<List<ScanTask>> history() {
        return ApiResponse.ok(scanTaskRepository.findTop10ByOrderByStartedAtDesc());
    }
}
