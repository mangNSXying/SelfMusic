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
    _db!.execute(
        'DELETE FROM idx_songs WHERE source_key=? AND missing=1 AND is_favorite=0',
        [sourceKey]);
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
      SELECT id, source_key, ref, title, artist, album, track_no, year, genre,
             duration, format, size, cover_path, is_favorite, missing
      FROM idx_songs
      WHERE source_key=? AND missing=0
        AND (title LIKE ? OR COALESCE(artist,'') LIKE ? OR COALESCE(album,'') LIKE ?)
      ORDER BY artist, album, track_no, title
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

  void setFavorite(String sourceKey, String ref, bool fav) {
    _db!.execute('UPDATE idx_songs SET is_favorite=? WHERE source_key=? AND ref=?',
        [fav ? 1 : 0, sourceKey, ref]);
  }

  List<Song> favorites(String sourceKey) {
    final rows = _db!.select('''
      SELECT id, source_key, ref, title, artist, album, track_no, year, genre,
             duration, format, size, cover_path, is_favorite, missing
      FROM idx_songs WHERE source_key=? AND missing=0 AND is_favorite=1
      ORDER BY artist, album, track_no
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
    File(cachePathForKey(cacheKey)).writeAsBytesSync(bytes, flush: true);
    _db!.execute(
        'INSERT INTO cache(cache_key, path, size) VALUES(?,?,?) ON CONFLICT(cache_key) DO UPDATE SET size=excluded.size',
        [cacheKey, cachePathForKey(cacheKey), bytes.length]);
  }

  /// 把下载好的临时文件移入缓存目录并登记（流式缓存，避免整文件常驻内存）。
  void cacheCommit(String cacheKey, String tmpFilePath, int size) {
    final dst = cachePathForKey(cacheKey);
    if (File(dst).existsSync()) File(dst).deleteSync();
    File(tmpFilePath).renameSync(dst);
    _db!.execute(
        'INSERT INTO cache(cache_key, path, size) VALUES(?,?,?) ON CONFLICT(cache_key) DO UPDATE SET size=excluded.size',
        [cacheKey, dst, size]);
  }

  String? cachedPath(String cacheKey) {
    if (!isCached(cacheKey)) return null;
    return cachePathForKey(cacheKey);
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
