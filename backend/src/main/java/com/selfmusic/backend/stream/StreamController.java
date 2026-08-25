package com.selfmusic.backend.stream;

import com.selfmusic.backend.common.BizException;
import com.selfmusic.backend.domain.entity.Song;
import com.selfmusic.backend.domain.repository.SongRepository;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpRange;
import org.springframework.web.bind.annotation.*;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.List;

@RestController
@RequestMapping("/api/v1/stream")
@RequiredArgsConstructor
public class StreamController {

    private final SongRepository songRepository;
    private final MusicSourceProxy sourceProxy;

    @GetMapping("/{id}")
    public void stream(@PathVariable Long id,
                       HttpServletRequest request,
                       HttpServletResponse response) throws IOException {
        Song song = songRepository.findById(id)
                .orElseThrow(() -> new BizException(40401, "song not found"));

        // 注意：播放次数/last_played 不在此处更新——一次播放会产生多个 Range 分段请求，
        // 在流接口里计数会严重灌水。统计由阶段 2 的播放事件上报 API（complete/skip）驱动。

        long fileSize = sourceProxy.getFileSize(song);
        response.setContentType(sourceProxy.getContentType(song));
        response.setHeader("Accept-Ranges", "bytes");

        long start = 0;
        long end = fileSize - 1;
        boolean isPartial = false;

        String rangeHeader = request.getHeader("Range");
        if (rangeHeader != null && !rangeHeader.isBlank()) {
            List<HttpRange> ranges;
            try {
                ranges = HttpRange.parseRanges(rangeHeader);
            } catch (IllegalArgumentException e) {
                send416(response, fileSize);
                return;
            }
            if (ranges.isEmpty()) {
                send416(response, fileSize);
                return;
            }
            HttpRange range = ranges.get(0); // 多段 Range 只取第一段（音频场景足够）
            start = range.getRangeStart(0);
            if (start >= fileSize) {
                send416(response, fileSize);
                return;
            }
            end = Math.min(range.getRangeEnd(fileSize - 1), fileSize - 1);
            isPartial = true;
        }

        long len = end - start + 1;
        if (isPartial) {
            response.setStatus(206);
            response.setHeader("Content-Range", "bytes " + start + "-" + end + "/" + fileSize);
        }
        response.setHeader("Content-Length", String.valueOf(len));

        try (InputStream in = sourceProxy.open(song, start, len);
             OutputStream out = response.getOutputStream()) {
            in.transferTo(out);
        }
    }

    private void send416(HttpServletResponse response, long fileSize) throws IOException {
        response.setStatus(416);
        response.setHeader("Content-Range", "bytes */" + fileSize);
    }
}
