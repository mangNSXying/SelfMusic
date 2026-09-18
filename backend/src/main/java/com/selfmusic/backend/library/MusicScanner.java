package com.selfmusic.backend.library;

import com.selfmusic.backend.common.MusicSource;
import com.selfmusic.backend.domain.entity.Album;
import com.selfmusic.backend.domain.entity.ScanTask;
import com.selfmusic.backend.domain.entity.Song;
import com.selfmusic.backend.domain.repository.AlbumRepository;
import com.selfmusic.backend.domain.repository.ScanTaskRepository;
import com.selfmusic.backend.domain.repository.SongRepository;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.jaudiotagger.audio.AudioFile;
import org.jaudiotagger.audio.AudioFileIO;
import org.jaudiotagger.tag.FieldKey;
import org.jaudiotagger.tag.Tag;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.scheduling.annotation.EnableScheduling;
import org.springframework.stereotype.Service;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.attribute.BasicFileAttributes;
import java.time.LocalDateTime;
import java.time.ZoneId;
import java.time.ZonedDateTime;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.Base64;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.regex.Pattern;

@Slf4j
@Service
@RequiredArgsConstructor
@EnableScheduling
public class MusicScanner {

    private static final Pattern AUDIO_EXT =
            Pattern.compile("\\.(mp3|flac|m4a|aac|ogg|wav)$", Pattern.CASE_INSENSITIVE);

    /** 进程级共享客户端，带连接/请求超时，避免远端慢或无响应时无限阻塞 */
    private static final java.net.http.HttpClient HTTP_CLIENT =
            java.net.http.HttpClient.newBuilder()
                    .connectTimeout(java.time.Duration.ofSeconds(15))
                    .build();

    private final SongRepository songRepository;
    private final AlbumRepository albumRepository;
    private final ScanTaskRepository scanTaskRepository;

    @Value("${selfmusic.local.root:}")
    private String localRoot;

    @Value("${selfmusic.webdav.base-url:}")
    private String webdavBaseUrl;

    @Value("${selfmusic.webdav.username:}")
    private String webdavUsername;

    @Value("${selfmusic.webdav.password:}")
    private String webdavPassword;

    /** 每个音频最多读取的头部字节数（标签解析只需头部，避免大文件整下载）。 */
    @Value("${selfmusic.scan.head-bytes:65536}")
    private int headBytes;

    /** 标签探测并发池大小（网络/IO 密集，远小于全量顺序探测）。 */
    @Value("${selfmusic.scan.probe-pool:4}")
    private int probePool;

    /** 是否启用定时增量扫描。 */
    @Value("${selfmusic.scan.scheduling-enabled:true}")
    private boolean schedulingEnabled;

    /** 手动扫描入口（ScanController 调用）。 */
    public ScanTask scan() {
        return scan(ScanTask.TriggerType.manual);
    }

    /** 定时增量扫描：指纹（size+mtime）未变直接跳过，不读标签、不写库。 */
    @org.springframework.scheduling.annotation.Scheduled(
            fixedDelayString = "${selfmusic.scan.interval-ms:21600000}")
    public void scheduledScan() {
        if (!schedulingEnabled) return;
        try {
            log.info("scheduled incremental scan start");
            scan(ScanTask.TriggerType.scheduled);
        } catch (Exception e) {
            log.error("scheduled scan failed", e.getMessage(), e);
        }
    }

    private ScanTask scan(ScanTask.TriggerType trigger) {
        ScanTask task = new ScanTask();
        task.setTriggerType(trigger);
        task.setStatus(ScanTask.TaskStatus.running);
        task.setStartedAt(LocalDateTime.now());
        task.setTotalCount(0);
        task.setAddedCount(0);
        task.setUpdatedCount(0);
        task.setMissingCount(0);
        scanTaskRepository.save(task);

        int added = 0, updated = 0, unchanged = 0;
        List<ScannedFile> all = new ArrayList<>();
        try {
            all.addAll(scanLocal());
            all.addAll(scanWebdav());
            task.setTotalCount(all.size());

            // 指纹表：一次性载入，避免逐条 N+1 查询。
            Map<String, Song> known = new HashMap<>();
            for (Song s : songRepository.findAll()) {
                known.put(mapKey(s.getSource(), s.getSourceRef()), s);
            }

            // 1) 增量：size + mtime 与库中一致 → 跳过（不读标签、零音频下载）。
            List<ScannedFile> toProbe = new ArrayList<>();
            for (ScannedFile f : all) {
                Song ex = known.get(mapKey(f.source, f.sourceRef));
                if (ex != null && ex.getFileSize() != null && ex.getFileSize() > 0 && f.size > 0
                        && ex.getFileSize().equals(f.size)
                        && ex.getFileMtime() != null && f.mtime != null
                        && ex.getFileMtime().equals(f.mtime)) {
                    unchanged++;
                    continue;
                }
                toProbe.add(f);
            }
            log.info("scan: total={}, unchanged(skip)={}, probe={}",
                    all.size(), unchanged, toProbe.size());

            // 2) 并发探测标签（每个文件只读 headBytes）。
            ExecutorService pool = Executors.newFixedThreadPool(
                    Math.max(1, Math.min(Math.max(probePool, 1), Math.max(toProbe.size(), 1))));
            try {
                List<Future<Meta>> futures = new ArrayList<>();
                for (ScannedFile f : toProbe) {
                    futures.add(pool.submit(() -> readMeta(f)));
                }
                Map<String, Album> albumCache = new HashMap<>();
                for (int i = 0; i < toProbe.size(); i++) {
                    ScannedFile f = toProbe.get(i);
                    Meta meta = futures.get(i).get();
                    if (meta == null) continue; // 无标签：跳过（fallback 由 readMeta 兜底文件名，不会为 null）
                    UpsertStatus st = upsert(f, meta, known, albumCache);
                    if (st == UpsertStatus.ADDED) added++;
                    else if (st == UpsertStatus.UPDATED) updated++;
                }
            } finally {
                pool.shutdown();
            }

            recomputeAlbums();

            task.setAddedCount(added);
            task.setUpdatedCount(updated);
            task.setMissingCount(0);
            task.setStatus(ScanTask.TaskStatus.done);
        } catch (Exception e) {
            log.error("scan failed", e);
            task.setStatus(ScanTask.TaskStatus.failed);
            task.setErrorMsg(String.valueOf(e.getMessage() != null ? e.getMessage() : e.getClass().getSimpleName()));
            task.setTotalCount(all.size());
            task.setAddedCount(added);
            task.setUpdatedCount(updated);
        } finally {
            task.setFinishedAt(LocalDateTime.now());
            scanTaskRepository.save(task);
        }
        return task;
    }

    private static String mapKey(MusicSource src, String ref) {
        return src.name() + "\u0000" + ref;
    }

    // ---------- local ----------

    private List<ScannedFile> scanLocal() {
        List<ScannedFile> out = new ArrayList<>();
        if (localRoot == null || localRoot.isBlank()) {
            log.info("local music root not configured, skip");
            return out;
        }
        Path root = Path.of(localRoot).toAbsolutePath().normalize();
        if (!Files.isDirectory(root)) {
            log.warn("local music root not a dir: {}", root);
            return out;
        }
        try (var stream = Files.walk(root)) {
            stream.filter(Files::isRegularFile)
                  .filter(p -> AUDIO_EXT.matcher(p.getFileName().toString()).find())
                  .forEach(p -> {
                      String ref = root.relativize(p).toString().replace('\\', '/');
                      try {
                          BasicFileAttributes attr = Files.readAttributes(p, BasicFileAttributes.class);
                          ScannedFile f = new ScannedFile();
                          f.source = MusicSource.local;
                          f.sourceRef = ref;
                          f.ext = extOf(ref);
                          f.size = Files.size(p);
                          f.mtime = LocalDateTime.ofInstant(attr.lastModifiedTime().toInstant(),
                                  ZoneId.systemDefault());
                          out.add(f);
                      } catch (IOException e) {
                          log.warn("skip {}: {}", p, e.getMessage());
                      }
                  });
        } catch (IOException e) {
            log.error("walk local failed {}", root, e);
        }
        return out;
    }

    // ---------- webdav ----------

    private List<ScannedFile> scanWebdav() {
        List<ScannedFile> out = new ArrayList<>();
        if (webdavBaseUrl == null || webdavBaseUrl.isBlank()) {
            log.info("webdav base-url not configured, skip");
            return out;
        }
        try {
            walkWebdav(webdavBaseUrl, out);
        } catch (Exception e) {
            log.warn("webdav scan failed: {}", e.getMessage(), e);
        }
        return out;
    }

    private void walkWebdav(String url, List<ScannedFile> out) throws IOException {
        String xml = propfind(url);
        if (xml == null) return;
        String base = webdavBaseUrl.endsWith("/") ? webdavBaseUrl : webdavBaseUrl + "/";
        // 当前目录的路径形式（如 /dav/），用于在下级响应里跳过目录自身引用。
        String selfPath = pathOf(url);
        for (String resp : splitResponses(xml)) {
            String href = propFindHref(resp);
            if (href == null) continue;
            String h = href.trim();
            if (pathOf(h).equals(selfPath)) continue;
            String rel = toRelative(h, base);
            boolean isDir = h.endsWith("/") || COLLECTION.matcher(resp).find();
            if (isDir) {
                walkWebdav(resolveUrl(h), out);
            } else {
                String name = rel.substring(rel.lastIndexOf('/') + 1);
                if (AUDIO_EXT.matcher(name).find()) {
                    ScannedFile f = new ScannedFile();
                    f.source = MusicSource.webdav;
                    f.sourceRef = rel;
                    f.ext = extOf(rel);
                    f.size = parseSize(resp);
                    // getlastmodified 增量指纹：同一文件的 size+mtime 未变则跳过读头。
                    f.mtime = parseMtime(resp);
                    out.add(f);
                }
            }
        }
    }

    /** 返回 URL 或路径的"路径"部分：https://h/dav/ → /dav/；/dav/sub/ → /dav/sub/；用于比较并跳过目录自身。 */
    private static String pathOf(String urlOrPath) {
        int i = urlOrPath.indexOf("://");
        if (i > 0) {
            String rest = urlOrPath.substring(i + 3);
            int slash = rest.indexOf('/');
            return slash >= 0 ? rest.substring(slash) : "/";
        }
        return urlOrPath;
    }

    private String toRelative(String href, String base) {
        // 取出 base 里的路径部分（如 /dav/）作为前缀基线
        String basePath;
        try {
            var u = java.net.URI.create(base);
            String p = u.getPath() != null ? u.getPath() : "/";
            basePath = p.endsWith("/") ? p : p + "/";
        } catch (Exception e) {
            basePath = "/";
        }
        String h = href;
        // 若是完整 URL，先转成路径形式
        int scheme = h.indexOf("://");
        if (scheme > 0) {
            String pathAndHost = h.substring(scheme + 3);
            int slash = pathAndHost.indexOf('/');
            h = slash >= 0 ? pathAndHost.substring(slash) : "/";
        }
        if (h.startsWith(basePath)) {
            h = h.substring(basePath.length());
        }
        return h.startsWith("/") ? h.substring(1) : h;
    }

    /** 把服务器根相对 href（如 /dav/sub/）解析为完整 URL（复用 webdavBaseUrl 的协议+host） */
    private String resolveUrl(String href) {
        try {
            var base = java.net.URI.create(webdavBaseUrl);
            String scheme = base.getScheme();
            String host = base.getHost();
            int port = base.getPort();
            String h = href;
            if (h.indexOf("://") > 0) return h; // 已是完整 URL
            String origin = scheme + "://" + host + (port > 0 ? ":" + port : "");
            return origin + (h.startsWith("/") ? h : "/" + h);
        } catch (Exception e) {
            return href;
        }
    }

    private String propfind(String url) throws IOException {
        java.net.http.HttpRequest.Builder builder;
        try {
            builder = java.net.http.HttpRequest.newBuilder()
                    .uri(java.net.URI.create(url))
                    .timeout(java.time.Duration.ofSeconds(30))
                    .method("PROPFIND", java.net.http.HttpRequest.BodyPublishers.noBody())
                    .header("Depth", "1");
        } catch (IllegalArgumentException e) {
            log.warn("invalid webdav url {}", url);
            return null;
        }
        auth(builder);
        try {
            java.net.http.HttpResponse<byte[]> resp = HTTP_CLIENT.send(builder.build(),
                    java.net.http.HttpResponse.BodyHandlers.ofByteArray());
            if (resp.statusCode() != 207 && resp.statusCode() != 200) {
                log.warn("webdav PROPFIND {} -> HTTP {}", url, resp.statusCode());
                return null;
            }
            return new String(resp.body(), StandardCharsets.UTF_8);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return null;
        }
    }

    private void auth(java.net.http.HttpRequest.Builder builder) {
        if (webdavUsername != null && !webdavUsername.isBlank()) {
            String cred = Base64.getEncoder().encodeToString(
                    (webdavUsername + ":" + webdavPassword).getBytes(StandardCharsets.UTF_8));
            builder.header("Authorization", "Basic " + cred);
        }
    }

    private static final Pattern RESPONSE_BLOCK = Pattern.compile(
            "<[A-Za-z0-9]*:?response\\b.*?</[A-Za-z0-9]*:?response\\b>",
            Pattern.CASE_INSENSITIVE | Pattern.DOTALL);

    private List<String> splitResponses(String xml) {
        List<String> out = new ArrayList<>();
        var m = RESPONSE_BLOCK.matcher(xml);
        while (m.find()) out.add(m.group());
        return out;
    }

    private static final Pattern COLLECTION = Pattern.compile(
            "<[A-Za-z0-9]*:?collection\\b", Pattern.CASE_INSENSITIVE);

    private String propFindHref(String resp) {
        var m = Pattern.compile("<[^:>]*:?href>([^<]*)</[^:>]*:?href>",
                Pattern.CASE_INSENSITIVE).matcher(resp);
        return m.find() ? m.group(1) : null;
    }

    private long parseSize(String resp) {
        var m = Pattern.compile("<[^:>]*:?getcontentlength>([0-9]+)</[^:>]*:?getcontentlength>",
                Pattern.CASE_INSENSITIVE).matcher(resp);
        try {
            return m.find() ? Long.parseLong(m.group(1)) : 0;
        } catch (NumberFormatException e) {
            return 0;
        }
    }

    private static final DateTimeFormatter RFC1123 = DateTimeFormatter.RFC_1123_DATE_TIME;

    /** 解析 PROPFIND 的 getlastmodified（RFC1123，如 "Wed, 18 Sep 2026 10:00:00 GMT"）。
     *  与 local 侧一致转回本时区的 LocalDateTime，保证增量指纹可对。 */
    private LocalDateTime parseMtime(String resp) {
        var m = Pattern.compile(
                "<[^:>]*:?getlastmodified>([^<]+)</[^:>]*:?getlastmodified>",
                Pattern.CASE_INSENSITIVE).matcher(resp);
        if (!m.find()) return null;
        try {
            ZonedDateTime zdt = ZonedDateTime.parse(m.group(1).trim(), RFC1123);
            return zdt.withZoneSameInstant(ZoneId.systemDefault()).toLocalDateTime();
        } catch (Exception e) {
            return null;
        }
    }

    // ---------- 元数据读取与落库 ----------

    private enum UpsertStatus { ADDED, UPDATED, UNCHANGED }

    private UpsertStatus upsert(ScannedFile f, Meta meta,
                                Map<String, Song> known, Map<String, Album> albumCache) {
        Song song = known.get(mapKey(f.source, f.sourceRef));
        boolean isNew = song == null;
        if (song == null) song = new Song();

        song.setSource(f.source);
        song.setSourceRef(f.sourceRef);
        song.setTitle(meta.title);
        song.setArtist(blankToNull(meta.artist));
        song.setTrackNo(meta.trackNo);
        song.setYear(meta.year);
        song.setGenre(blankToNull(meta.genre));
        song.setDuration(meta.duration);
        song.setFormat(f.ext);
        song.setFileSize(f.size != 0 ? f.size : song.getFileSize());
        song.setFileMtime(f.mtime != null ? f.mtime
                : song.getFileMtime() != null ? song.getFileMtime() : LocalDateTime.now());
        song.setHidden(false);
        attachAlbum(song, meta, albumCache);

        songRepository.save(song);
        return isNew ? UpsertStatus.ADDED : UpsertStatus.UPDATED;
    }

    private Meta readMeta(ScannedFile f) {
        try {
            Path tmp = Files.createTempFile("selfmusic-scan-", "." + f.ext);
            try {
                byte[] head;
                if (f.source == MusicSource.local) {
                    Path p = Path.of(localRoot).toAbsolutePath().normalize().resolve(f.sourceRef).normalize();
                    head = readHead(Files.newInputStream(p));
                } else {
                    head = webdavGetHead(f.sourceRef);
                    if (head == null || head.length == 0) return null;
                }
                Files.write(tmp, head);
                AudioFile af = AudioFileIO.read(tmp.toFile());
                Tag tag = af.getTag();
                Meta m = new Meta();
                m.duration = af.getAudioHeader() != null ? af.getAudioHeader().getTrackLength() : null;
                if (tag != null) {
                    m.title = trim(first(tag, FieldKey.TITLE));
                    m.artist = trim(first(tag, FieldKey.ARTIST));
                    m.albumName = trim(first(tag, FieldKey.ALBUM));
                    m.genre = trim(first(tag, FieldKey.GENRE));
                    m.year = shortOrNull(first(tag, FieldKey.YEAR));
                    m.trackNo = shortOrNull(first(tag, FieldKey.TRACK));
                }
                if (m.title == null || m.title.isBlank()) m.title = fallbackTitle(f.sourceRef);
                return m;
            } finally {
                Files.deleteIfExists(tmp);
            }
        } catch (Exception e) {
            log.debug("no tags for {}: {}", f.sourceRef, e.getMessage());
            return null;
        }
    }

    private byte[] readHead(InputStream in) throws IOException {
        try (in) {
            var buf = new java.io.ByteArrayOutputStream();
            byte[] chunk = new byte[8192];
            int total = 0;
            int n;
            while (total < headBytes && (n = in.read(chunk)) != -1) {
                int take = Math.min(n, headBytes - total);
                buf.write(chunk, 0, take);
                total += take;
            }
            return buf.toByteArray();
        }
    }

    private byte[] webdavGetHead(String sourceRef) throws IOException {
        String base = (webdavBaseUrl.endsWith("/") ? webdavBaseUrl : webdavBaseUrl + "/");
        String url = base + sourceRef;
        java.net.http.HttpRequest.Builder builder;
        try {
            builder = java.net.http.HttpRequest.newBuilder()
                    .uri(java.net.URI.create(url))
                    .timeout(java.time.Duration.ofSeconds(30))
                    .header("Range", "bytes=0-" + (headBytes - 1))
                    .GET();
        } catch (IllegalArgumentException e) {
            return null;
        }
        auth(builder);
        try {
            java.net.http.HttpResponse<byte[]> resp = HTTP_CLIENT.send(
                    builder.build(), java.net.http.HttpResponse.BodyHandlers.ofByteArray());
            // 服务端可能忽略 Range 返回完整 200；也可能只回左 206（右边界可能被忽略）
            if (resp.statusCode() != 200 && resp.statusCode() != 206) {
                log.warn("webdav GET {} -> HTTP {}", url, resp.statusCode());
                return null;
            }
            return resp.body();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return null;
        }
    }

    private void attachAlbum(Song song, Meta meta, Map<String, Album> albumCache) {
        String artist = blankToNull(meta.artist) != null ? meta.artist : "Unknown Artist";
        String albumName = blankToNull(meta.albumName) != null ? meta.albumName : "Unknown Album";
        String cacheKey = artist + "\u0000" + albumName;
        Album album = albumCache.get(cacheKey);
        if (album == null) {
            album = albumRepository.findByArtistAndAlbum(artist, albumName)
                    .orElseGet(() -> {
                        Album a = new Album();
                        a.setArtist(artist);
                        a.setAlbum(albumName);
                        a.setYear(meta.year);
                        a.setGenre(blankToNull(meta.genre));
                        return albumRepository.save(a);
                    });
            albumCache.put(cacheKey, album);
        }
        if (album.getYear() == null && meta.year != null) {
            album.setYear(meta.year);
            albumRepository.save(album);
        }
        song.setAlbum(album);
    }

    private void recomputeAlbums() {
        for (Album a : albumRepository.findAll()) {
            List<Song> songs = songRepository.findByAlbumId(a.getId());
            long dur = 0;
            for (Song s : songs) if (s.getDuration() != null) dur += s.getDuration();
            a.setTrackCount(songs.size());
            a.setTotalDuration((int) dur);
            albumRepository.save(a);
        }
    }

    // ---------- helpers ----------

    private String first(Tag tag, FieldKey key) {
        String v = tag.getFirst(key);
        return v == null ? "" : v.trim();
    }

    private String trim(String v) {
        return (v == null || v.isBlank()) ? null : v.trim();
    }

    private Short shortOrNull(String v) {
        if (v == null) return null;
        var m = Pattern.compile("\\d+").matcher(v);
        if (!m.find()) return null;
        try { return Short.parseShort(m.group()); } catch (NumberFormatException e) { return null; }
    }

    private String blankToNull(String v) {
        return (v == null || v.isBlank()) ? null : v.trim();
    }

    private String fallbackTitle(String ref) {
        String name = ref.substring(ref.lastIndexOf('/') + 1);
        int dot = name.lastIndexOf('.');
        return dot > 0 ? name.substring(0, dot) : name;
    }

    private static String extOf(String ref) {
        int i = ref.lastIndexOf('.');
        return i >= 0 ? ref.substring(i + 1).toLowerCase() : "";
    }

    private static class ScannedFile {
        MusicSource source;
        String sourceRef;
        String ext;
        long size;
        LocalDateTime mtime;
        boolean isDirectory;
    }

    private static class Meta {
        String title;
        String artist;
        String albumName;
        String genre;
        Short year;
        Short trackNo;
        Integer duration;
    }
}