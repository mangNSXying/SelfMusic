package com.selfmusic.backend.stream;

import com.selfmusic.backend.common.BizException;
import com.selfmusic.backend.common.MusicSource;
import com.selfmusic.backend.domain.entity.Song;
import com.selfmusic.backend.domain.repository.SongRepository;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import lombok.RequiredArgsConstructor;
import org.springframework.core.io.FileSystemResource;
import org.springframework.core.io.InputStreamResource;
import org.springframework.core.io.Resource;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpRange;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.io.*;
import java.nio.file.*;
import java.time.LocalDateTime;

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

        // 更新播放统计
        song.setPlayCount(song.getPlayCount() + 1);
        song.setLastPlayedAt(LocalDateTime.now());
        songRepository.save(song);

        long fileSize = sourceProxy.getFileSize(song);
        String ct = sourceProxy.getContentType(song);

        response.setContentType(ct);

        // Range 请求处理
        String rangeHeader = request.getHeader("Range");
        if (rangeHeader != null && rangeHeader.startsWith("bytes=")) {
            HttpRange range = HttpRange.parseRanges(rangeHeader).get(0);
            long start = range.getRangeStart(0);
            long end   = range.getRangeEnd(fileSize - 1);
            long len   = end - start + 1;

            response.setStatus(206);
            response.setHeader("Content-Range",
                    "bytes " + start + "-" + end + "/" + fileSize);
            response.setHeader("Content-Length", String.valueOf(len));

            try (InputStream in = sourceProxy.open(song, start, len);
                 OutputStream out = response.getOutputStream()) {
                in.transferTo(out);
            }
        } else {
            response.setHeader("Content-Length", String.valueOf(fileSize));
            response.setHeader("Accept-Ranges", "bytes");

            try (InputStream in = sourceProxy.open(song, 0, fileSize);
                 OutputStream out = response.getOutputStream()) {
                in.transferTo(out);
            }
        }
    }

    @RequestMapping(value = "/{id}", method = RequestMethod.HEAD)
    public ResponseEntity<Void> head(@PathVariable Long id) {
        Song song = songRepository.findById(id)
                .orElseThrow(() -> new BizException(40401, "song not found"));
        long size = sourceProxy.getFileSize(song);
        return ResponseEntity.ok()
                .header("Accept-Ranges", "bytes")
                .header("Content-Length", String.valueOf(size))
                .header("Content-Type", sourceProxy.getContentType(song))
                .build();
    }
}
