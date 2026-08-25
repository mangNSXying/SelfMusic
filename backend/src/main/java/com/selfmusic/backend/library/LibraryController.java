package com.selfmusic.backend.library;

import com.selfmusic.backend.common.ApiResponse;
import com.selfmusic.backend.common.BizException;
import com.selfmusic.backend.domain.entity.Album;
import com.selfmusic.backend.domain.entity.Song;
import com.selfmusic.backend.domain.repository.AlbumRepository;
import com.selfmusic.backend.domain.repository.SongRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.PageRequest;
import org.springframework.web.bind.annotation.*;

import java.util.List;
import java.util.Map;

@RestController
@RequestMapping("/api/v1/library")
@RequiredArgsConstructor
public class LibraryController {

    private final SongRepository songRepository;
    private final AlbumRepository albumRepository;

    @GetMapping("/songs")
    public ApiResponse<?> songs(
            @RequestParam(required = false) String q,
            @RequestParam(required = false) String artist,
            @RequestParam(required = false) String source,
            @RequestParam(required = false) Boolean favorite,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size) {

        PageRequest pr = PageRequest.of(page - 1, Math.min(size, 500));
        Page<Song> result;

        if (q != null && !q.isBlank()) {
            result = songRepository.search(q, pr);
        } else if (artist != null) {
            result = songRepository.findByArtistAndHiddenFalse(artist, pr);
        } else if (Boolean.TRUE.equals(favorite)) {
            result = songRepository.findByFavoriteTrueAndHiddenFalse()
                    .stream()
                    .collect(java.util.stream.Collectors.collectingAndThen(
                            java.util.stream.Collectors.toList(),
                            list -> new org.springframework.data.domain.PageImpl<>(list, pr, list.size())
                    ));
        } else {
            result = songRepository.findByHiddenFalse(pr);
        }
        return ApiResponse.ok(result);
    }

    @GetMapping("/songs/{id}")
    public ApiResponse<Song> song(@PathVariable Long id) {
        return ApiResponse.ok(songRepository.findById(id)
                .orElseThrow(() -> new BizException(40401, "song not found")));
    }

    @GetMapping("/albums")
    public ApiResponse<Page<Album>> albums(
            @RequestParam(required = false) String q,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size) {
        PageRequest pr = PageRequest.of(page - 1, Math.min(size, 500));
        if (q != null && !q.isBlank()) {
            return ApiResponse.ok(albumRepository.findByArtistContainingIgnoreCase(q, pr));
        }
        return ApiResponse.ok(albumRepository.findAll(pr));
    }

    @GetMapping("/albums/{id}")
    public ApiResponse<Map<String, Object>> albumDetail(@PathVariable Long id) {
        Album a = albumRepository.findById(id)
                .orElseThrow(() -> new BizException(40401, "album not found"));
        return ApiResponse.ok(Map.of("album", a, "songs", a.getSongs()));
    }

    @GetMapping("/favorites")
    public ApiResponse<List<Song>> favorites() {
        return ApiResponse.ok(songRepository.findByFavoriteTrueAndHiddenFalse());
    }
}
