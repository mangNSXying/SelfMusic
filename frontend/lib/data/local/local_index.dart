import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../models/song.dart';

/// 直连模式本地轻量索引（DESIGN §6.4）。///
/// SQLite 存放：已配置的直连源（[DirectSourceRow]）、索引歌曲（[Song]）、
/// 离线缓存（[CachedFile]）。扫描时按 `(sourceKey, ref)` 的 mtime/size 三元组做增量。
class LocalIndex {
  Database? _db;
  String? _dir;

  Future<void> open() async {
    if (_db != null) return;
    final support = await getApplicationSupportDirectory();
    _dir = p.join(support.path, 'selfmusic');
    Directory(_dir!).createSync(recursive: true);
    final dbPath = p.join(_dir!, 'selfmusic.db');
    _db = sqlite3.open(dbPath);
    _db!.execute('PRAGMA journal_mode=WAL;');
    _db!.execute('''
      CREATE TABLE IF NOT EXISTS sources (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        key TEXT NOT NULL UNIQUE,
        kind TEXT NOT NULL,
        name TEXT NOT NULL,
        config TEXT NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        status TEXT NOT NULL DEFAULT '',
        last_scan_at TEXT
      );
    ''');
    _db!.execute('''
      CREATE TABLE IF NOT EXISTS idx_songs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        source_key TEXT NOT NULL,
        ref TEXT NOT NULL,
        title TEXT NOT NULL,
        artist TEXT,
        album TEXT,
        track_no INTEGER,
        year INTEGER,
        genre TEXT,
        duration INTEGER,
        format TEXT,
        size INTEGER NOT NULL DEFAULT 0,
        mtime INTEGER NOT NULL DEFAULT 0,
        cover_path TEXT,
        is_favorite INTEGER NOT NULL DEFAULT 0,
        missing INTEGER NOT NULL DEFAULT 0,
        UNIQUE(source_key, ref)
      );
    ''');
    _db!.execute('''
      CREATE TABLE IF NOT EXISTS cache (
        cache_key TEXT PRIMARY KEY,
        path TEXT NOT NULL,
        size INTEGER NOT NULL DEFAULT 0
      );
    ''');
    // 阶段 2：歌曲播放元数据 / 歌单 / 应用设置 / 断点（DESIGN §7，stage2.md §1）。
    _db!.execute('''
      CREATE TABLE IF NOT EXISTS play_meta (
        source_key   TEXT NOT NULL,
        song_ref     TEXT NOT NULL,
        like_streak   INTEGER NOT NULL DEFAULT 0,
        dislike_streak INTEGER NOT NULL DEFAULT 0,
        factor        REAL NOT NULL DEFAULT 1.0,
        frozen        INTEGER NOT NULL DEFAULT 0,
        is_favorite   INTEGER NOT NULL DEFAULT 0,
        song_json     TEXT,
        PRIMARY KEY (source_key, song_ref)
      );
    ''');
    _db!.execute('''
      CREATE TABLE IF NOT EXISTS playlists (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        name        TEXT NOT NULL,
        description TEXT,
        created_at  TEXT NOT NULL
      );
    ''');
    _db!.execute('''
      CREATE TABLE IF NOT EXISTS playlist_items (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        playlist_id INTEGER NOT NULL,
        source_key  TEXT NOT NULL,
        song_ref    TEXT NOT NULL,
        title       TEXT NOT NULL,
        artist      TEXT,
        album       TEXT,
        cover_path  TEXT,
        sort_order  INTEGER NOT NULL DEFAULT 0,
        added_at    TEXT NOT NULL,
        UNIQUE (playlist_id, source_key, song_ref)
      );
    ''');
    _db!.execute('''
      CREATE TABLE IF NOT EXISTS app_settings (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
    ''');
    _db!.execute('''
      CREATE TABLE IF NOT EXISTS play_state (
        id          INTEGER PRIMARY KEY CHECK (id = 1),
        queue_json  TEXT NOT NULL,
        idx         INTEGER NOT NULL,
        position_ms INTEGER NOT NULL,
        updated_at  TEXT NOT NULL
      );
    ''');
    final cacheCols = _db!
        .select('PRAGMA table_info(cache)')
        .map((r) => r['name'] as String)
        .toSet();
    if (!cacheCols.contains('cached_at')) {
      _db!.execute('ALTER TABLE cache ADD COLUMN cached_at TEXT');
    }
    if (!cacheCols.contains('last_accessed_at')) {
      _db!.execute('ALTER TABLE cache ADD COLUMN last_accessed_at TEXT');
    }
    // play_meta 为既有 DB 时可能缺 song_json 快照列。
    final metaCols = _db!
        .select('PRAGMA table_info(play_meta)')
        .map((r) => r['name'] as String)
        .toSet();
    if (!metaCols.contains('song_json')) {
      _db!.execute('ALTER TABLE play_meta ADD COLUMN song_json TEXT');
    }
    // 收藏一次性回填迁移：idx_songs.is_favorite → play_meta，此后以 play_meta 为准。
    _db!.execute('''
      INSERT OR IGNORE INTO play_meta(source_key, song_ref, is_favorite)
      SELECT source_key, ref, is_favorite FROM idx_songs WHERE is_favorite = 1
    ''');
    _db!.execute('''
      CREATE INDEX IF NOT EXISTS pli_playlist ON playlist_items(playlist_id);
    ''');
    _db!.execute('''
      CREATE INDEX IF NOT EXISTS idx_songs_source ON idx_songs(source_key);
    ''');
  }

  void close() {
    _db?.dispose();
    _db = null;
  }

  String get dir => _dir ?? '';

  // ---------- sources ----------

  List<DirectSourceRow> listSources() {
    final rs = _db!.select(
        'SELECT key, kind, name, config, enabled, status, last_scan_at FROM sources ORDER BY id');
    return rs.map(_rowToSource).toList();
  }

  DirectSourceRow? getSource(String key) {
    final rs = _db!.select(
        'SELECT key, kind, name, config, enabled, status, last_scan_at FROM sources WHERE key=?',
        [key]);
    if (rs.isEmpty) return null;
    return _rowToSource(rs.first);
  }

  void upsertSource(String key, String kind, String name, String config) {
    _db!.execute('''
      INSERT INTO sources(key, kind, name, config) VALUES(?,?,?,?)
      ON CONFLICT(key) DO UPDATE SET name=excluded.name, config=excluded.config, kind=excluded.kind
    ''', [key, kind, name, config]);
  }

  void updateSourceScan(String key, String status) {
    _db!.execute('UPDATE sources SET status=?, last_scan_at=? WHERE key=?',
        [status, DateTime.now().toIso8601String(), key]);
  }

  void deleteSource(String key) {
    _db!.execute('DELETE FROM sources WHERE key=?', [key]);
    _db!.execute('DELETE FROM idx_songs WHERE source_key=?', [key]);
  }

  DirectSourceRow _rowToSource(Row r) => DirectSourceRow(
        key: r['key'] as String,
        kind: r['kind'] as String,
        name: r['name'] as String,
        config: r['config'] as String,
        enabled: (r['enabled'] as int) == 1,
        status: r['status'] as String,
        lastScanAt: r['last_scan_at'] as String?,
      );

  // ---------- indexed songs ----------

  void upsertSong(DirectSongRow s) {
    _db!.execute('''
      INSERT INTO idx_songs(source_key, ref, title, artist, album, track_no, year,
        genre, duration, format, size, mtime, cover_path, is_favorite, missing)
      VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,0,0)
      ON CONFLICT(source_key, ref) DO UPDATE SET
        title=excluded.title, artist=excluded.artist, album=excluded.album,
        track_no=excluded.track_no, year=excluded.year, genre=excluded.genre,
        duration=excluded.duration, format=excluded.format, size=excluded.size,
        mtime=excluded.mtime,
        cover_path=COALESCE(excluded.cover_path, idx_songs.cover_path),
        missing=0
    ''', [
      s.sourceKey,
      s.ref,
      s.title,
      s.artist,
      s.album,
      s.trackNo,
      s.year,
      s.genre,
      s.duration,
      s.format,
      s.size,
      s.mtime,
      s.coverPath,
    ]);
  }

  /// 扫描结束后把不再存在的条目标记 missing（DESIGN §6.4 增量）。
  void markMissingExcept(String sourceKey, List<String> aliveRefs) {
    final stmt = _db!.prepare(
        'UPDATE idx_songs SET missing=1 WHERE source_key=? AND ref NOT IN (SELECT value FROM json_each(?))');
    try {
      stmt.execute([sourceKey, '[${aliveRefs.map((e) => '"$e"').join(',')}]']);
    } finally {
      stmt.dispose();
    }
  }

  void clearMissing(String sourceKey) {
    // 收藏歌曲以 play_meta.is_favorite 为准，收藏中的缺失歌不清理（等待源恢复）。
    _db!.execute('''
      DELETE FROM idx_songs WHERE source_key=? AND missing=1
        AND COALESCE((SELECT p.is_favorite FROM play_meta p
                      WHERE p.source_key = idx_songs.source_key
                        AND p.song_ref = idx_songs.ref), 0) = 0
    ''', [sourceKey]);
  }

  List<Song> searchSongs({
    required String sourceKey,
    String? query,
    int page = 1,
    int size = 200,
  }) {
    final q = query?.trim().toLowerCase() ?? '';
    final like = q.isEmpty ? '%' : '%$q%';
    final limit = size;
    final offset = (page - 1) * size;
    final rows = _db!.select('''
      SELECT i.id, i.source_key, i.ref, i.title, i.artist, i.album, i.track_no,
             i.year, i.genre, i.duration, i.format, i.size, i.cover_path, i.missing,
             COALESCE(p.is_favorite, 0) AS favorite
      FROM idx_songs i
      LEFT JOIN play_meta p ON p.source_key = i.source_key AND p.song_ref = i.ref
      WHERE i.source_key=? AND i.missing=0
        AND (i.title LIKE ? OR COALESCE(i.artist,'') LIKE ? OR COALESCE(i.album,'') LIKE ?)
      ORDER BY i.artist, i.album, i.track_no, i.title
      LIMIT ? OFFSET ?
    ''', [sourceKey, like, like, like, limit, offset]);
    return rows.map(_rowToSong).toList();
  }

  int countSongs(String sourceKey) {
    final rs = _db!.select(
        'SELECT COUNT(*) c FROM idx_songs WHERE source_key=? AND missing=0',
        [sourceKey]);
    return (rs.first['c'] as int);
  }

  /// 收藏状态统一存 play_meta（直连 + 服务器一致，stage2.md §1.1）。
  /// [songJson] 为该歌快照（收藏服务器歌曲时写入，供「喜欢」列表离线渲染），可空。
  void setFavorite(String sourceKey, String songRef, bool fav, {String? songJson}) {
    final cur = playMetaOf(sourceKey, songRef);
    _db!.execute('''
      INSERT INTO play_meta(source_key, song_ref, like_streak, dislike_streak,
        factor, frozen, is_favorite, song_json)
      VALUES(?,?,?,?,?,?,?,?)
      ON CONFLICT(source_key, song_ref) DO UPDATE SET
        is_favorite = excluded.is_favorite,
        song_json = COALESCE(excluded.song_json, play_meta.song_json)
    ''', [sourceKey, songRef, cur.likeStreak, cur.dislikeStreak, cur.factor,
        cur.frozen ? 1 : 0, fav ? 1 : 0, songJson]);
  }

  /// 「喜欢」列表：play_meta 中已收藏歌曲（含服务器歌快照；迁移回填的直连歌查 idx_songs 补全）。
  List<Song> likedSongs() {
    final rows = _db!.select(
        'SELECT source_key, song_ref, song_json FROM play_meta WHERE is_favorite=1');
    final out = <Song>[];
    for (final r in rows) {
      final srcKey = r['source_key'] as String;
      final ref = r['song_ref'] as String;
      final json = r['song_json'] as String?;
      if (json != null && json.isNotEmpty) {
        try {
          out.add(Song.fromJson(jsonDecode(json) as Map<String, dynamic>));
          continue;
        } catch (_) {}
      }
      final s = _songByRef(srcKey, ref);
      if (s != null) out.add(s);
    }
    return out;
  }

  Song? _songByRef(String sourceKey, String ref) {
    final rows = _db!.select('''
      SELECT i.id, i.source_key, i.ref, i.title, i.artist, i.album, i.track_no,
             i.year, i.genre, i.duration, i.format, i.size, i.cover_path, i.missing,
             COALESCE(p.is_favorite, 0) AS favorite
      FROM idx_songs i
      LEFT JOIN play_meta p ON p.source_key = i.source_key AND p.song_ref = i.ref
      WHERE i.source_key=? AND i.ref=?
    ''', [sourceKey, ref]);
    return rows.isEmpty ? null : _rowToSong(rows.first);
  }

  List<Song> favorites(String sourceKey) {
    final rows = _db!.select('''
      SELECT i.id, i.source_key, i.ref, i.title, i.artist, i.album, i.track_no,
             i.year, i.genre, i.duration, i.format, i.size, i.cover_path, i.missing,
             COALESCE(p.is_favorite, 0) AS favorite
      FROM idx_songs i
      LEFT JOIN play_meta p ON p.source_key = i.source_key AND p.song_ref = i.ref
      WHERE i.source_key=? AND i.missing=0 AND COALESCE(p.is_favorite, 0) = 1
      ORDER BY i.artist, i.album, i.track_no
    ''', [sourceKey]);
    return rows.map(_rowToSong).toList();
  }

  Song _rowToSong(Row r) => Song.direct(
        id: r['id'] as int,
        sourceKey: r['source_key'] as String,
        title: r['title'] as String,
        artist: r['artist'] as String?,
        albumName: r['album'] as String?,
        trackNo: r['track_no'] as int?,
        year: r['year'] as int?,
        genre: r['genre'] as String?,
        duration: r['duration'] as int?,
        source: _sourceOf(r['source_key'] as String),
        sourceRef: r['ref'] as String,
        fileSize: r['size'] as int,
        format: r['format'] as String?,
        favorite: r['is_favorite'] == 1,
        coverPath: r['cover_path'] as String?,
      );

  /// 从 source_key（'webdav:name'）取协议名（'webdav'）。
  String _sourceOf(String key) {
    final i = key.indexOf(':');
    return i > 0 ? key.substring(0, i) : key;
  }

  // ---------- offline cache ----------

  String get _cacheDir {
    final d = p.join(_dir!, 'cache');
    Directory(d).createSync(recursive: true);
    return d;
  }

  String cachePathForKey(String cacheKey) => p.join(_cacheDir, '$cacheKey.dat');

  bool isCached(String cacheKey) {
    final file = File(cachePathForKey(cacheKey));
    return file.existsSync();
  }

  void cacheSave(String cacheKey, List<int> bytes) {
    final now = DateTime.now().toIso8601String();
    File(cachePathForKey(cacheKey)).writeAsBytesSync(bytes, flush: true);
    _db!.execute(
        'INSERT INTO cache(cache_key, path, size, cached_at, last_accessed_at) '
        'VALUES(?,?,?,?,?) ON CONFLICT(cache_key) DO UPDATE SET size=excluded.size, cached_at=COALESCE(excluded.cached_at, cache.cached_at)',
        [cacheKey, cachePathForKey(cacheKey), bytes.length, now, now]);
  }

  /// 把下载好的临时文件移入缓存目录并登记（流式缓存，避免整文件常驻内存）。
  void cacheCommit(String cacheKey, String tmpFilePath, int size) {
    final dst = cachePathForKey(cacheKey);
    if (File(dst).existsSync()) File(dst).deleteSync();
    File(tmpFilePath).renameSync(dst);
    final now = DateTime.now().toIso8601String();
    _db!.execute(
        'INSERT INTO cache(cache_key, path, size, cached_at, last_accessed_at) '
        'VALUES(?,?,?,?,?) ON CONFLICT(cache_key) DO UPDATE SET size=excluded.size',
        [cacheKey, dst, size, now, now]);
  }

  String? cachedPath(String cacheKey) {
    if (!isCached(cacheKey)) return null;
    return cachePathForKey(cacheKey);
  }

  /// 播放/访问缓存时刷新最后访问时间（LRU 依据）。
  void touchCache(String cacheKey) {
    _db!.execute(
        'UPDATE cache SET last_accessed_at=? WHERE cache_key=?',
        [DateTime.now().toIso8601String(), cacheKey]);
  }

  /// 全部缓存行（供 LRU 淘汰与统计）。
  List<CachedRow> listCache() {
    final rs = _db!.select(
        'SELECT cache_key, path, size, cached_at, last_accessed_at FROM cache');
    return rs.map((r) => CachedRow(
          cacheKey: r['cache_key'] as String,
          path: r['path'] as String,
          size: r['size'] as int,
          cachedAt: r['cached_at'] as String?,
          lastAccessedAt: r['last_accessed_at'] as String?,
        )).toList();
  }

  void deleteCache(String cacheKey) {
    _db!.execute('DELETE FROM cache WHERE cache_key=?', [cacheKey]);
    final f = File(cachePathForKey(cacheKey));
    if (f.existsSync()) f.deleteSync();
  }

  // ---------- play_meta（阶段 2：权重 / 收藏，stage2.md §1.1） ----------

  PlayMetaRow playMetaOf(String sourceKey, String songRef) {
    final rs = _db!.select(
        'SELECT source_key, song_ref, like_streak, dislike_streak, factor, frozen, is_favorite, song_json '
        'FROM play_meta WHERE source_key=? AND song_ref=?', [sourceKey, songRef]);
    if (rs.isEmpty) {
      return PlayMetaRow(
        sourceKey: sourceKey,
        songRef: songRef,
        likeStreak: 0,
        dislikeStreak: 0,
        factor: 1.0,
        frozen: false,
        favorite: false,
      );
    }
    final r = rs.first;
    return PlayMetaRow(
      sourceKey: r['source_key'] as String,
      songRef: r['song_ref'] as String,
      likeStreak: r['like_streak'] as int,
      dislikeStreak: r['dislike_streak'] as int,
      factor: (r['factor'] as num).toDouble(),
      frozen: (r['frozen'] as int) == 1,
      favorite: (r['is_favorite'] as int) == 1,
      songJson: r['song_json'] as String?,
    );
  }

  bool isFavoriteOf(String sourceKey, String songRef) =>
      playMetaOf(sourceKey, songRef).favorite;

  /// 全量更新一首歌的权重元数据（null 保持原值）。
  void upsertPlayMeta(String sourceKey, String songRef,
      {int? likeStreak, int? dislikeStreak, double? factor, bool? frozen,
      bool? favorite, String? songJson}) {
    _db!.execute('''
      INSERT INTO play_meta(source_key, song_ref, like_streak, dislike_streak,
        factor, frozen, is_favorite, song_json)
      VALUES(?,?,?,?,?,?,?,?)
      ON CONFLICT(source_key, song_ref) DO UPDATE SET
        like_streak = COALESCE(excluded.like_streak, play_meta.like_streak),
        dislike_streak = COALESCE(excluded.dislike_streak, play_meta.dislike_streak),
        factor = COALESCE(excluded.factor, play_meta.factor),
        frozen = COALESCE(excluded.frozen, play_meta.frozen),
        is_favorite = COALESCE(excluded.is_favorite, play_meta.is_favorite),
        song_json = COALESCE(excluded.song_json, play_meta.song_json)
    ''', [sourceKey, songRef, likeStreak, dislikeStreak, factor,
        frozen == null ? null : (frozen ? 1 : 0),
        favorite == null ? null : (favorite ? 1 : 0), songJson]);
  }

  // ---------- 歌单（stage2.md §1.2） ----------

  int createPlaylist(String name, {String? description}) {
    _db!.execute(
        'INSERT INTO playlists(name, description, created_at) VALUES(?,?,?)',
        [name, description, DateTime.now().toIso8601String()]);
    return _db!.lastInsertRowId;
  }

  void renamePlaylist(int id, String name) {
    _db!.execute('UPDATE playlists SET name=? WHERE id=?', [name, id]);
  }

  void deletePlaylist(int id) {
    _db!.execute('DELETE FROM playlist_items WHERE playlist_id=?', [id]);
    _db!.execute('DELETE FROM playlists WHERE id=?', [id]);
  }

  List<PlaylistRow> listPlaylists() {
    final rs = _db!.select(
        'SELECT id, name, description, created_at FROM playlists ORDER BY id');
    return rs.map((r) => PlaylistRow(
          id: r['id'] as int,
          name: r['name'] as String,
          description: r['description'] as String?,
          createdAt: r['created_at'] as String,
        )).toList();
  }

  void addPlaylistItem(int playlistId,
      {required String sourceKey, required String songRef,
      required String title, String? artist, String? album, String? coverPath}) {
    final max = _db!
        .select('SELECT COALESCE(MAX(sort_order),0) m FROM playlist_items WHERE playlist_id=?',
            [playlistId])
        .first['m'] as int;
    final now = DateTime.now().toIso8601String();
    _db!.execute('''
      INSERT INTO playlist_items(playlist_id, source_key, song_ref, title, artist,
        album, cover_path, sort_order, added_at)
      VALUES(?,?,?,?,?,?,?,?,?)
      ON CONFLICT(playlist_id, source_key, song_ref) DO NOTHING
    ''', [playlistId, sourceKey, songRef, title, artist, album, coverPath, max + 1, now]);
  }

  void removePlaylistItem(int playlistId, String sourceKey, String songRef) {
    _db!.execute(
        'DELETE FROM playlist_items WHERE playlist_id=? AND source_key=? AND song_ref=?',
        [playlistId, sourceKey, songRef]);
  }

  List<PlaylistItemRow> playlistItems(int playlistId) {
    final rs = _db!.select('''
      SELECT id, playlist_id, source_key, song_ref, title, artist, album,
             cover_path, sort_order
      FROM playlist_items WHERE playlist_id=?
      ORDER BY sort_order, id
    ''', [playlistId]);
    return rs.map((r) => PlaylistItemRow(
          id: r['id'] as int,
          playlistId: r['playlist_id'] as int,
          sourceKey: r['source_key'] as String,
          songRef: r['song_ref'] as String,
          title: r['title'] as String,
          artist: r['artist'] as String?,
          album: r['album'] as String?,
          coverPath: r['cover_path'] as String?,
          sortOrder: r['sort_order'] as int,
        )).toList();
  }

  /// 上移/下移歌单内条目（交换相邻 sort_order）。
  void movePlaylistItem(int playlistId, int itemId, int delta) {
    final items = playlistItems(playlistId);
    final i = items.indexWhere((x) => x.id == itemId);
    final j = i + delta;
    if (i < 0 || j < 0 || j >= items.length) return;
    _db!.execute(
        'UPDATE playlist_items SET sort_order=? WHERE id=?',
        [items[j].sortOrder, items[i].id]);
    _db!.execute(
        'UPDATE playlist_items SET sort_order=? WHERE id=?',
        [items[i].sortOrder, items[j].id]);
  }

  // ---------- 应用设置（stage2.md §1.4） ----------

  String? settingsGet(String key) {
    final rs = _db!.select('SELECT value FROM app_settings WHERE key=?', [key]);
    return rs.isEmpty ? null : rs.first['value'] as String;
  }

  void settingsSet(String key, String value) {
    _db!.execute(
        'INSERT INTO app_settings(key, value) VALUES(?,?) '
        'ON CONFLICT(key) DO UPDATE SET value=excluded.value', [key, value]);
  }

  // ---------- 断点（stage2.md §1.4） ----------

  void savePlayState(String queueJson, int idx, int positionMs) {
    _db!.execute(
        'INSERT INTO play_state(id, queue_json, idx, position_ms, updated_at) '
        'VALUES(1,?,?,?,?) ON CONFLICT(id) DO UPDATE SET '
        'queue_json=excluded.queue_json, idx=excluded.idx, '
        'position_ms=excluded.position_ms, updated_at=excluded.updated_at',
        [queueJson, idx, positionMs, DateTime.now().toIso8601String()]);
  }

  PlayStateRow? getPlayState() {
    final rs = _db!.select(
        'SELECT queue_json, idx, position_ms, updated_at FROM play_state WHERE id=1');
    if (rs.isEmpty) return null;
    final r = rs.first;
    return PlayStateRow(
      queueJson: r['queue_json'] as String,
      idx: r['idx'] as int,
      positionMs: r['position_ms'] as int,
      updatedAt: r['updated_at'] as String,
    );
  }

  void clearPlayState() {
    _db!.execute('DELETE FROM play_state WHERE id=1');
  }
}

/// 一张已配置的直连源记录。
class DirectSourceRow {
  final String key;
  final String kind;
  final String name;
  final String config;
  final bool enabled;
  final String status;
  final String? lastScanAt;
  DirectSourceRow({
    required this.key,
    required this.kind,
    required this.name,
    required this.config,
    required this.enabled,
    required this.status,
    this.lastScanAt,
  });
}

/// 扫描所得的一条歌曲行（尚未落库）。
class DirectSongRow {
  final String sourceKey;
  final String ref;
  final String title;
  final String? artist;
  final String? album;
  final int? trackNo;
  final int? year;
  final String? genre;
  final int? duration;
  final String? format;
  final int size;
  final int mtime;
  final String? coverPath;
  DirectSongRow({
    required this.sourceKey,
    required this.ref,
    required this.title,
    this.artist,
    this.album,
    this.trackNo,
    this.year,
    this.genre,
    this.duration,
    this.format,
    required this.size,
    required this.mtime,
    this.coverPath,
  });
}

/// 一首歌的播放元数据（权重/收藏，stage2.md §1.1）。
class PlayMetaRow {
  final String sourceKey;
  final String songRef;
  final int likeStreak;
  final int dislikeStreak;
  final double factor;
  final bool frozen;
  final bool favorite;
  final String? songJson;
  const PlayMetaRow({
    required this.sourceKey,
    required this.songRef,
    required this.likeStreak,
    required this.dislikeStreak,
    required this.factor,
    required this.frozen,
    required this.favorite,
    this.songJson,
  });
}

/// 歌单行（stage2.md §1.2）。
class PlaylistRow {
  final int id;
  final String name;
  final String? description;
  final String createdAt;
  const PlaylistRow({
    required this.id,
    required this.name,
    this.description,
    required this.createdAt,
  });
}

/// 歌单条目行（含歌曲快照字段，离线或源失效仍可展示）。
class PlaylistItemRow {
  final int id;
  final int playlistId;
  final String sourceKey;
  final String songRef;
  final String title;
  final String? artist;
  final String? album;
  final String? coverPath;
  final int sortOrder;
  const PlaylistItemRow({
    required this.id,
    required this.playlistId,
    required this.sourceKey,
    required this.songRef,
    required this.title,
    this.artist,
    this.album,
    this.coverPath,
    required this.sortOrder,
  });
}

/// 缓存行（LRU：按 last_accessed_at 淘汰）。
class CachedRow {
  final String cacheKey;
  final String path;
  final int size;
  final String? cachedAt;
  final String? lastAccessedAt;
  const CachedRow({
    required this.cacheKey,
    required this.path,
    required this.size,
    this.cachedAt,
    this.lastAccessedAt,
  });
}

/// 断点（杀 App 重开恢复）。
class PlayStateRow {
  final String queueJson;
  final int idx;
  final int positionMs;
  final String updatedAt;
  const PlayStateRow({
    required this.queueJson,
    required this.idx,
    required this.positionMs,
    required this.updatedAt,
  });
}
