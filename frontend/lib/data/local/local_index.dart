import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../models/song.dart';
import '../sources/webdav_url.dart';

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
    // idx_songs 增量指纹：getetag（WebDAV）列，mtime/size 已在建表时定义。
    final songCols = _db!
        .select('PRAGMA table_info(idx_songs)')
        .map((r) => r['name'] as String)
        .toSet();
    if (!songCols.contains('etag')) {
      _db!.execute('ALTER TABLE idx_songs ADD COLUMN etag TEXT');
    }
    if (!songCols.contains('url')) {
      _db!.execute('ALTER TABLE idx_songs ADD COLUMN url TEXT');
    }
    // 用户手动改过元数据的行：扫描不再覆盖其标题/歌手/专辑。
    if (!songCols.contains('user_edited')) {
      _db!.execute(
          'ALTER TABLE idx_songs ADD COLUMN user_edited INTEGER NOT NULL DEFAULT 0');
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

  /// 源改名：源 key 由名称派生，改名时同步迁移所有引用该 key 的数据，
  /// 保证已索引歌曲、收藏、歌单条目在改名后仍然有效。
  void renameSource(String oldKey, String newKey) {
    if (oldKey == newKey) return;
    _db!.execute('UPDATE OR REPLACE sources SET key=? WHERE key=?',
        [newKey, oldKey]);
    _db!.execute('UPDATE OR REPLACE idx_songs SET source_key=? WHERE source_key=?',
        [newKey, oldKey]);
    _db!.execute('UPDATE OR REPLACE play_meta SET source_key=? WHERE source_key=?',
        [newKey, oldKey]);
    _db!.execute(
        'UPDATE OR REPLACE playlist_items SET source_key=? WHERE source_key=?',
        [newKey, oldKey]);
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

  /// 该源已有歌曲的增量指纹表：`ref → (size, mtime, etag)`。
  /// 扫描 worker 比对该表，未变化则跳过读头（增量扫描，零音频下载）。
  Map<String, ScanFingerprint> scanFingerprint(String sourceKey) {
    final rs = _db!.select(
        'SELECT ref, size, mtime, etag FROM idx_songs WHERE source_key=?',
        [sourceKey]);
    return {
      for (final r in rs)
        r['ref'] as String: ScanFingerprint(
          size: r['size'] as int,
          mtime: r['mtime'] as int,
          etag: r['etag'] as String?,
        ),
    };
  }

  /// 批量落库（单事务），供扫描结束一次性写入，避免逐行 autocommit。
  ///
  /// 用户手动改过元数据的行（user_edited=1）：标题/歌手/专辑不再被扫描覆盖。
  void upsertSongs(List<DirectSongRow> songs) {
    if (songs.isEmpty) return;
    _db!.execute('BEGIN');
    try {
      final stmt = _db!.prepare('''
        INSERT INTO idx_songs(source_key, ref, title, artist, album, track_no, year,
          genre, duration, format, size, mtime, etag, cover_path, is_favorite, missing, url)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,0,0,?)
        ON CONFLICT(source_key, ref) DO UPDATE SET
          title=CASE WHEN idx_songs.user_edited=1 THEN idx_songs.title ELSE excluded.title END,
          artist=CASE WHEN idx_songs.user_edited=1 THEN idx_songs.artist ELSE excluded.artist END,
          album=CASE WHEN idx_songs.user_edited=1 THEN idx_songs.album ELSE excluded.album END,
          track_no=excluded.track_no, year=excluded.year, genre=excluded.genre,
          duration=excluded.duration, format=excluded.format, size=excluded.size,
          mtime=excluded.mtime,
          etag=COALESCE(excluded.etag, idx_songs.etag),
          cover_path=COALESCE(excluded.cover_path, idx_songs.cover_path),
          url=COALESCE(excluded.url, idx_songs.url),
          missing=0
      ''');
      try {
        for (final s in songs) {
          stmt.execute([
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
            s.etag,
            s.coverPath,
            s.url,
          ]);
        }
      } finally {
        stmt.dispose();
      }
      _db!.execute('COMMIT');
    } catch (_) {
      _db!.execute('ROLLBACK');
      rethrow;
    }
  }

  /// 播放懒补全：把播放时解析出的额外元数据（时长/流派/曲目/年份/封面）回填。
  void enrichSong(String sourceKey, String songRef,
      {int? duration, String? genre, int? trackNo, int? year, String? coverPath}) {
    _db!.execute('''
      UPDATE idx_songs SET
        duration=COALESCE(?, duration),
        genre=COALESCE(?, genre),
        track_no=COALESCE(?, track_no),
        year=COALESCE(?, year),
        cover_path=COALESCE(?, cover_path)
      WHERE source_key=? AND ref=?
    ''', [duration, genre, trackNo, year, coverPath, sourceKey, songRef]);
  }

  /// 用户手动修改歌曲元数据：标题/歌手/专辑落库并标记 user_edited=1（扫描不再覆盖），
  /// 同时同步 play_meta 歌曲快照中的对应字段（喜欢列表/断点恢复用快照渲染）。
  void updateSongUserMeta(String sourceKey, String songRef,
      {String? title, String? artist, String? album}) {
    _db!.execute('''
      UPDATE idx_songs SET
        title=COALESCE(?, title),
        artist=COALESCE(?, artist),
        album=COALESCE(?, album),
        user_edited=1
      WHERE source_key=? AND ref=?
    ''', [title, artist, album, sourceKey, songRef]);
    final rows = _db!.select(
        'SELECT song_json FROM play_meta WHERE source_key=? AND song_ref=?',
        [sourceKey, songRef]);
    if (rows.isEmpty) return;
    final raw = rows.first['song_json'] as String?;
    if (raw == null || raw.isEmpty) return;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      if (title != null) j['title'] = title;
      if (artist != null) {
        j['artist'] = artist;
      }
      if (album != null) j['albumName'] = album;
      _db!.execute(
          'UPDATE play_meta SET song_json=? WHERE source_key=? AND song_ref=?',
          [jsonEncode(j), sourceKey, songRef]);
    } catch (_) {
      // 快照损坏则忽略（下次收藏时重写）。
    }
  }

  /// 把嵌入封面包装成可跨源复用的落盘（`covers/<md5(ref)>.jpg`），返回路径或 null。
  String? persistCover(Uint8List cover, String ref) {
    if (cover.isEmpty) return null;
    try {
      final dir = p.join(_dir!, 'covers');
      Directory(dir).createSync(recursive: true);
      final h = md5.convert(utf8.encode(ref)).toString();
      final filePath = p.join(dir, '$h.jpg');
      File(filePath).writeAsBytesSync(cover, flush: true);
      return filePath;
    } catch (_) {
      return null;
    }
  }

  /// 扫描结束后把不再存在的条目标记 missing（DESIGN §6.4 增量）。
  void markMissingExcept(String sourceKey, List<String> aliveRefs) {
    final stmt = _db!.prepare(
        'UPDATE idx_songs SET missing=1 WHERE source_key=? AND ref NOT IN (SELECT value FROM json_each(?))');
    try {
      // 用 jsonEncode 生成合法 JSON 数组，避免 ref 含引号/反斜杠时破坏 json_each。
      stmt.execute([sourceKey, jsonEncode(aliveRefs)]);
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
    int? size,
  }) {
    final q = query?.trim().toLowerCase() ?? '';
    final like = q.isEmpty ? '%' : '%$q%';
    // size==null 时不设 LIMIT（返回全部，供列表无限滚动 / 全选）。
    final limitSql = size == null ? '' : 'LIMIT ? OFFSET ?';
    final args = <Object?>[sourceKey, like, like, like];
    if (size != null) {
      args.add(size);
      args.add((page - 1) * size);
    }
    final rows = _db!.select('''
      SELECT i.id, i.source_key, i.ref, i.title, i.artist, i.album, i.track_no,
             i.year, i.genre, i.duration, i.format, i.size, i.cover_path, i.url, i.missing,
             COALESCE(p.is_favorite, 0) AS favorite
      FROM idx_songs i
      LEFT JOIN play_meta p ON p.source_key = i.source_key AND p.song_ref = i.ref
      WHERE i.source_key=? AND i.missing=0
        AND (i.title LIKE ? OR COALESCE(i.artist,'') LIKE ? OR COALESCE(i.album,'') LIKE ?)
      ORDER BY i.artist, i.album, i.track_no, i.title
      $limitSql
    ''', args);
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
    _migrateMetaRef(sourceKey, songRef);
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

  /// 按 ref 回查歌曲：兼容新旧两种入库形态（解码态 / 历史 ENCODE 文本）。
  Song? songByRef(String sourceKey, String ref) => _songByRef(sourceKey, ref);

  Song? _songByRef(String sourceKey, String ref) {
    const sql = '''
      SELECT i.id, i.source_key, i.ref, i.title, i.artist, i.album, i.track_no,
             i.year, i.genre, i.duration, i.format, i.size, i.cover_path, i.url, i.missing,
             COALESCE(p.is_favorite, 0) AS favorite
      FROM idx_songs i
      LEFT JOIN play_meta p ON p.source_key = i.source_key AND p.song_ref = i.ref
      WHERE i.source_key=? AND i.ref=?
    ''';
    for (final variant in webdavRefVariants(ref)) {
      final rows = _db!.select(sql, [sourceKey, variant]);
      if (rows.isNotEmpty) return _rowToSong(rows.first);
    }
    return null;
  }

  List<Song> favorites(String sourceKey) {
    final rows = _db!.select('''
      SELECT i.id, i.source_key, i.ref, i.title, i.artist, i.album, i.track_no,
             i.year, i.genre, i.duration, i.format, i.size, i.cover_path, i.url, i.missing,
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
        favorite: r['favorite'] == 1,
        coverPath: r['cover_path'] as String?,
        sourceUrl: r['url'] as String?,
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

  /// 把历史 ENCODE 形态的旧行迁移到当前 ref（幂等）。
  ///
  /// 历史版本曾在 play_meta.song_ref 里存 ENCODE 文本；新扫描入库的 ref 为解码态。
  /// 若不合并，同一首歌会分裂成两行：旧收藏态读不到、新写行与旧行并存导致
  /// 「取消喜欢后喜欢列表仍在」。迁移保留最有价值的一行（收藏 > 有快照）。
  void _migrateMetaRef(String sourceKey, String songRef) {
    final alts =
        webdavRefVariants(songRef).where((v) => v != songRef).toList();
    if (alts.isEmpty) return;
    final ph = alts.map((_) => '?').join(',');
    final rows = _db!.select(
        'SELECT song_ref, like_streak, dislike_streak, factor, frozen, is_favorite, song_json '
        'FROM play_meta WHERE source_key=? AND song_ref IN ($ph)',
        [sourceKey, ...alts]);
    if (rows.isEmpty) return;
    // 挑选保留行：已收藏优先，其次有歌曲快照，最后取 factor 偏离 1.0 最多。
    Row best = rows.first;
    int score(Row r) =>
        ((r['is_favorite'] as int) == 1 ? 4 : 0) +
        (((r['song_json'] as String?)?.isNotEmpty ?? false) ? 2 : 0) +
        ((((r['factor'] as num).toDouble() - 1.0).abs() > 0.01) ? 1 : 0);
    for (final r in rows.skip(1)) {
      if (score(r) > score(best)) best = r;
    }
    _db!.execute(
        'DELETE FROM play_meta WHERE source_key=? AND song_ref IN ($ph)',
        [sourceKey, ...alts]);
    _db!.execute(
        'INSERT OR IGNORE INTO play_meta(source_key, song_ref, like_streak, dislike_streak, '
        'factor, frozen, is_favorite, song_json) VALUES(?,?,?,?,?,?,?,?)',
        [
          sourceKey,
          songRef,
          best['like_streak'],
          best['dislike_streak'],
          best['factor'],
          best['frozen'],
          best['is_favorite'],
          best['song_json']
        ]);
  }

  PlayMetaRow playMetaOf(String sourceKey, String songRef) {
    // 读前迁移：旧编码行的收藏/权重态对新 ref 可见（图标、喜欢列表正确）。
    _migrateMetaRef(sourceKey, songRef);
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
  ///
  /// NOTE：play_meta 各列为 NOT NULL，INSERT 时用 COALESCE(?, 默认值) 兜底；
  /// ON CONFLICT 仍用原值（excluded 为 null），避免无关注册意外覆盖收藏等状态。
  void upsertPlayMeta(String sourceKey, String songRef,
      {int? likeStreak, int? dislikeStreak, double? factor, bool? frozen,
      bool? favorite, String? songJson}) {
    _migrateMetaRef(sourceKey, songRef);
    _db!.execute('''
      INSERT INTO play_meta(source_key, song_ref, like_streak, dislike_streak,
        factor, frozen, is_favorite, song_json)
      VALUES(?,?,COALESCE(?,0),COALESCE(?,0),COALESCE(?,1.0),COALESCE(?,0),COALESCE(?,0),?)
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

  // ---------- 应用设置（settings.md §3） ----------

  String? settingsGet(String key) {
    final rs = _db!.select('SELECT value FROM app_settings WHERE key=?', [key]);
    return rs.isEmpty ? null : rs.first['value'] as String;
  }

  void settingsSet(String key, String value) {
    _db!.execute(
        'INSERT INTO app_settings(key, value) VALUES(?,?) '
        'ON CONFLICT(key) DO UPDATE SET value=excluded.value', [key, value]);
  }

  /// 全部已存设置键值（供设置导入导出，settings.md §3.5）。
  Map<String, String> settingsAll() {
    final rs = _db!.select('SELECT key, value FROM app_settings');
    return {
      for (final r in rs) r['key'] as String: r['value'] as String,
    };
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
  final String? url;
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
  final String? etag;
  final String? coverPath;
  DirectSongRow({
    required this.sourceKey,
    required this.ref,
    this.url,
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
    this.etag,
    this.coverPath,
  });
}

/// 增量指纹：远端 `(size, mtime, etag)` 与库中相同则扫描跳过读头。
class ScanFingerprint {
  final int size;
  final int mtime;
  final String? etag;
  const ScanFingerprint({required this.size, required this.mtime, this.etag});

  bool same(int otherSize, int otherMtime, String? otherEtag) {
    if (size != otherSize) return false;
    if (mtime != otherMtime) return false;
    if (etag != null && otherEtag != null && etag != otherEtag) return false;
    return true;
  }
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
