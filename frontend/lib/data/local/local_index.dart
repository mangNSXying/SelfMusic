import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../models/song.dart';
import '../sources/webdav_url.dart';
import 'audio_metadata.dart';

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
        album_artist TEXT,
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
    // 服务端歌曲元数据本地覆盖（后端只读，无改元数据接口）：标题/歌手/专辑按需覆盖。
    _db!.execute('''
      CREATE TABLE IF NOT EXISTS song_meta_override (
        source_key TEXT NOT NULL,
        song_ref   TEXT NOT NULL,
        title      TEXT,
        artist     TEXT,
        album      TEXT,
        album_artist TEXT,
        PRIMARY KEY (source_key, song_ref)
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
    // 是否已读取过文件元数据（播放时补读/后台扫描用，N1）。
    if (!songCols.contains('meta_read')) {
      _db!.execute(
          'ALTER TABLE idx_songs ADD COLUMN meta_read INTEGER NOT NULL DEFAULT 0');
    }
    // 专辑歌手（mp3 TPE2 / flac ALBUMARTIST）。
    if (!songCols.contains('album_artist')) {
      _db!.execute('ALTER TABLE idx_songs ADD COLUMN album_artist TEXT');
    }
    // 服务端歌曲覆盖层同样支持专辑歌手。
    final overrideCols = _db!
        .select('PRAGMA table_info(song_meta_override)')
        .map((r) => r['name'] as String)
        .toSet();
    if (!overrideCols.contains('album_artist')) {
      _db!.execute(
          'ALTER TABLE song_meta_override ADD COLUMN album_artist TEXT');
    }
    // 歌词（内嵌标签 / 同目录 .lrc 原文）：独立表存储，歌曲列表查询不加载大文本。
    _db!.execute('''
      CREATE TABLE IF NOT EXISTS song_lyrics (
        source_key TEXT NOT NULL,
        ref        TEXT NOT NULL,
        content    TEXT NOT NULL,
        updated_at INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (source_key, ref)
      );
    ''');
    // 阶段5 同步：本地变更流水（weight_outbox）+ 远端断点镜像（breakpoint_mirror）。
    _db!.execute('''
      CREATE TABLE IF NOT EXISTS weight_outbox (
        event_uuid  TEXT PRIMARY KEY,
        type        TEXT NOT NULL,
        payload     TEXT NOT NULL,
        occurred_at TEXT NOT NULL,
        acked       INTEGER NOT NULL DEFAULT 0,
        created_at  TEXT NOT NULL
      );
    ''');
    _db!.execute('''
      CREATE TABLE IF NOT EXISTS breakpoint_mirror (
        playlist_uuid TEXT PRIMARY KEY,
        song_id       INTEGER,
        source        TEXT,
        source_ref    TEXT,
        position_ms   INTEGER NOT NULL DEFAULT 0,
        updated_at    TEXT NOT NULL,
        device_id     TEXT
      );
    ''');
    // 歌单跨设备全局标识 + 删除墓碑（本地删除仍硬删，墓碑只活在服务端）。
    final playlistCols = _db!
        .select('PRAGMA table_info(playlists)')
        .map((r) => r['name'] as String)
        .toSet();
    if (!playlistCols.contains('client_uuid')) {
      _db!.execute('ALTER TABLE playlists ADD COLUMN client_uuid TEXT');
      _db!.execute(
          'CREATE UNIQUE INDEX IF NOT EXISTS idx_playlists_uuid ON playlists(client_uuid)');
    }
    if (!playlistCols.contains('deleted')) {
      _db!.execute(
          'ALTER TABLE playlists ADD COLUMN deleted INTEGER NOT NULL DEFAULT 0');
    }
    // 条目归属源（local/smb/webdav）：同步条目事件解析服务端 song_id 用。
    // 既有行留空（NULL），仅新写入行携带。
    final itemCols = _db!
        .select('PRAGMA table_info(playlist_items)')
        .map((r) => r['name'] as String)
        .toSet();
    if (!itemCols.contains('source')) {
      _db!.execute('ALTER TABLE playlist_items ADD COLUMN source TEXT');
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
    _db!.execute('''
      CREATE INDEX IF NOT EXISTS idx_songs_ref ON idx_songs(ref);
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
        INSERT INTO idx_songs(source_key, ref, title, artist, album, album_artist, track_no, year,
          genre, duration, format, size, mtime, etag, cover_path, is_favorite, missing, url, meta_read)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,0,0,?,CASE WHEN ? IS NOT NULL THEN 1 ELSE 0 END)
        ON CONFLICT(source_key, ref) DO UPDATE SET
          title=CASE WHEN idx_songs.user_edited=1 THEN idx_songs.title ELSE excluded.title END,
          artist=CASE WHEN idx_songs.user_edited=1 THEN idx_songs.artist ELSE excluded.artist END,
          album=CASE WHEN idx_songs.user_edited=1 THEN idx_songs.album ELSE excluded.album END,
          album_artist=CASE WHEN idx_songs.user_edited=1 THEN idx_songs.album_artist ELSE excluded.album_artist END,
          track_no=excluded.track_no, year=excluded.year, genre=excluded.genre,
          duration=excluded.duration, format=excluded.format, size=excluded.size,
          mtime=excluded.mtime,
          etag=COALESCE(excluded.etag, idx_songs.etag),
          cover_path=COALESCE(excluded.cover_path, idx_songs.cover_path),
          url=COALESCE(excluded.url, idx_songs.url),
          meta_read=CASE WHEN idx_songs.meta_read=1 THEN 1 WHEN excluded.duration IS NOT NULL THEN 1 ELSE 0 END,
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
            s.albumArtist,
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
            s.duration,
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

  /// 播放懒补全：把播放时解析出的额外元数据（标题/歌手/专辑/专辑歌手/时长/流派/
  /// 曲目/年份/封面）回填，并标记已读（后台不再重复扫描）。
  /// 用户手改过的行（user_edited=1）不回写文本字段，只补技术字段。
  void enrichSong(String sourceKey, String songRef,
      {String? title,
      String? artist,
      String? album,
      String? albumArtist,
      int? duration,
      String? genre,
      int? trackNo,
      int? year,
      String? coverPath}) {
    _db!.execute('''
      UPDATE idx_songs SET
        title=CASE WHEN user_edited=1 THEN title ELSE COALESCE(NULLIF(?, ''), title) END,
        artist=CASE WHEN user_edited=1 THEN artist ELSE COALESCE(NULLIF(?, ''), artist) END,
        album=CASE WHEN user_edited=1 THEN album ELSE COALESCE(NULLIF(?, ''), album) END,
        album_artist=CASE WHEN user_edited=1 THEN album_artist ELSE COALESCE(NULLIF(?, ''), album_artist) END,
        duration=COALESCE(?, duration),
        genre=COALESCE(?, genre),
        track_no=COALESCE(?, track_no),
        year=COALESCE(?, year),
        cover_path=COALESCE(?, cover_path),
        meta_read=1
      WHERE source_key=? AND ref=?
    ''', [
      title,
      artist,
      album,
      albumArtist,
      duration,
      genre,
      trackNo,
      year,
      coverPath,
      sourceKey,
      songRef,
    ]);
  }

  /// 大内嵌封面回填补读（旧版头部采样截断缺陷修复）：把已标已读、但没有封面的
  /// mp3/flac 行重置为未读，交给后台补读用加深的封面读取（coverReadHint）重取。
  /// 返回重置行数。
  int resetMetaReadForMissingCovers() {
    _db!.execute(
        "UPDATE idx_songs SET meta_read=0 "
        "WHERE meta_read=1 AND cover_path IS NULL AND format IN ('mp3','flac')");
    return _db!.updatedRows;
  }

  /// 块序异常元数据回填补读（旧版解析遇大封面/PICTURE 在 VORBIS_COMMENT
  /// 之前时提前中断，已标已读却没有歌手等信息）：把始终没有歌手的行重置为
  /// 未读，交给后台补读用「从头完整读取」重取。[sourceKeys] 限定直连源
  /// （服务端代理行不参与本地补读）；所有格式统一。
  /// 返回重置行数。
  int resetMetaReadForMissingArtist(List<String> sourceKeys) {
    if (sourceKeys.isEmpty) return 0;
    final marks = List.filled(sourceKeys.length, '?').join(',');
    _db!.execute(
        'UPDATE idx_songs SET meta_read=0 '
        'WHERE meta_read=1 AND artist IS NULL AND source_key IN ($marks)',
        sourceKeys);
    return _db!.updatedRows;
  }

  /// 指定源尚未读取过元数据的歌曲（后台补读用，missing=0）。
  /// [excludeRef] 用于跳过正在播放的歌（播放链路自己会重读，避免重复读流）。
  /// [afterId] 游标：只取 id 更大的行，供后台补读跳过无法解析的批次继续前进。
  List<Song> unreadSongs(String sourceKey, int limit,
      {String? excludeRef, int? afterId}) {
    final excludeCond = excludeRef == null ? '' : ' AND i.ref != ?';
    final cursorCond = afterId == null ? '' : ' AND i.id > ?';
    final params = <Object?>[
      sourceKey,
      if (excludeRef != null) excludeRef,
      if (afterId != null) afterId,
      limit,
    ];
    final rows = _db!.select('''
      SELECT i.id, i.source_key, i.ref, i.title, i.artist, i.album, i.album_artist, i.track_no,
             i.year, i.genre, i.duration, i.format, i.size, i.cover_path, i.url, i.missing,
             i.meta_read, COALESCE(p.is_favorite, 0) AS favorite
      FROM idx_songs i
      LEFT JOIN play_meta p ON p.source_key = i.source_key AND p.song_ref = i.ref
      WHERE i.source_key=? AND i.missing=0 AND COALESCE(i.meta_read, 0)=0$excludeCond$cursorCond
      ORDER BY i.id
      LIMIT ?
    ''', params);
    return rows.map(_rowToSong).toList();
  }

  /// 用户手动修改歌曲元数据：标题/歌手/专辑落库并标记 user_edited=1（扫描不再覆盖），
  /// 同时同步 play_meta 歌曲快照中的对应字段（喜欢列表/断点恢复用快照渲染）。
  /// 字段语义：null=不修改；''=清空（置 NULL，UI 显示为未知）。
  void updateSongUserMeta(String sourceKey, String songRef,
      {String? title, String? artist, String? album, String? albumArtist}) {
    _db!.execute('''
      UPDATE idx_songs SET
        title=CASE WHEN ? IS NULL THEN title ELSE NULLIF(?, '') END,
        artist=CASE WHEN ? IS NULL THEN artist ELSE NULLIF(?, '') END,
        album=CASE WHEN ? IS NULL THEN album ELSE NULLIF(?, '') END,
        album_artist=CASE WHEN ? IS NULL THEN album_artist ELSE NULLIF(?, '') END,
        user_edited=1
      WHERE source_key=? AND ref=?
    ''', [
      title,
      title,
      artist,
      artist,
      album,
      album,
      albumArtist,
      albumArtist,
      sourceKey,
      songRef,
    ]);
    syncMetaSnapshot(sourceKey, songRef,
        title: title, artist: artist, album: album, albumArtist: albumArtist);
  }

  /// 同步 play_meta 歌曲快照中的标题/歌手/专辑/专辑歌手（直连改库 / 服务端覆盖层共用）。
  /// '' 表示清空为未知（写 null）。
  void syncMetaSnapshot(String sourceKey, String songRef,
      {String? title, String? artist, String? album, String? albumArtist}) {
    final rows = _db!.select(
        'SELECT song_json FROM play_meta WHERE source_key=? AND song_ref=?',
        [sourceKey, songRef]);
    if (rows.isEmpty) return;
    final raw = rows.first['song_json'] as String?;
    if (raw == null || raw.isEmpty) return;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      if (title != null) j['title'] = title.isEmpty ? null : title;
      if (artist != null) j['artist'] = artist.isEmpty ? null : artist;
      if (album != null) j['albumName'] = album.isEmpty ? null : album;
      if (albumArtist != null) {
        j['albumArtist'] = albumArtist.isEmpty ? null : albumArtist;
      }
      _db!.execute(
          'UPDATE play_meta SET song_json=? WHERE source_key=? AND song_ref=?',
          [jsonEncode(j), sourceKey, songRef]);
    } catch (_) {
      // 快照损坏则忽略（下次收藏时重写）。
    }
  }

  /// 服务端歌曲元数据本地覆盖（null=不覆盖；''=显式清空为未知）。
  void setMetaOverride(String sourceKey, String songRef,
      {String? title, String? artist, String? album, String? albumArtist}) {
    _db!.execute('''
      INSERT INTO song_meta_override(source_key, song_ref, title, artist, album, album_artist)
      VALUES(?,?,?,?,?,?)
      ON CONFLICT(source_key, song_ref) DO UPDATE SET
        title=CASE WHEN excluded.title IS NULL THEN song_meta_override.title ELSE excluded.title END,
        artist=CASE WHEN excluded.artist IS NULL THEN song_meta_override.artist ELSE excluded.artist END,
        album=CASE WHEN excluded.album IS NULL THEN song_meta_override.album ELSE excluded.album END,
        album_artist=CASE WHEN excluded.album_artist IS NULL THEN song_meta_override.album_artist ELSE excluded.album_artist END
    ''', [sourceKey, songRef, title, artist, album, albumArtist]);
  }

  /// 读取本地覆盖（无则返回 null）。
  MetaOverride? metaOverrideOf(String sourceKey, String songRef) {
    final rows = _db!.select(
        'SELECT title, artist, album, album_artist FROM song_meta_override WHERE source_key=? AND song_ref=?',
        [sourceKey, songRef]);
    if (rows.isEmpty) return null;
    final r = rows.first;
    return MetaOverride(
      title: r['title'] as String?,
      artist: r['artist'] as String?,
      album: r['album'] as String?,
      albumArtist: r['album_artist'] as String?,
    );
  }

  /// 把嵌入封面包装成可跨源复用的落盘（`covers/<md5(ref)>.jpg`），返回路径或 null。
  /// 仅接受图片签名通过的字节（防止描述残留/URL 等脏数据落盘致解码报错）。
  String? persistCover(Uint8List cover, String ref) {
    if (cover.isEmpty || !looksLikeImageBytes(cover)) return null;
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

  /// 清理历史无效封面（旧解析缺陷曾把描述残留/URL 写盘，Android 解码器会刷错误日志）：
  /// 删除签名不符的封面文件，并把引用它们的歌标为未读，让补读用修复后的解析重取。
  /// 分块让出事件循环，避免大封面目录一次性阻塞 UI。
  Future<int> cleanupInvalidCovers() async {
    final root = _dir;
    if (root == null || _db == null) return 0;
    final dir = Directory(p.join(root, 'covers'));
    if (!dir.existsSync()) return 0;
    var cleaned = 0;
    var processed = 0;
    final now = DateTime.now();
    for (final f in dir.listSync()) {
      if (f is! File) continue;
      try {
        // 跳过刚落盘的文件，避免与正在进行的扫描/补读写盘竞争。
        if (now.difference(f.statSync().modified).inMinutes < 5) continue;
        final raf = f.openSync();
        final sig = raf.readSync(16);
        raf.closeSync();
        if (!looksLikeImageBytes(sig)) {
          f.deleteSync();
          _db!.execute(
              'UPDATE idx_songs SET cover_path=NULL, meta_read=0 WHERE cover_path=?',
              [f.path]);
          cleaned++;
        }
      } catch (_) {
        // 单文件失败忽略，继续清理其余。
      }
      if (++processed % 50 == 0) await Future.delayed(Duration.zero);
    }
    return cleaned;
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

  /// 读取歌曲歌词原文。三态语义：
  /// - null：从未查过（播放时尝试内嵌标签 / 同目录 .lrc）；
  /// - ''：查过但无歌词（避免每次播放重复请求）；
  /// - 其他：歌词原文（可能是带时间轴的 LRC）。
  String? lyricsOf(String sourceKey, String ref) {
    for (final variant in webdavRefVariants(ref)) {
      final rows = _db!.select(
          'SELECT content FROM song_lyrics WHERE source_key=? AND ref=?',
          [sourceKey, variant]);
      if (rows.isNotEmpty) return rows.first['content'] as String;
    }
    return null;
  }

  /// 写入歌词原文（内嵌标签 / 同目录 .lrc / 用户编辑）。
  void setLyrics(String sourceKey, String ref, String content) {
    _db!.execute('''
      INSERT INTO song_lyrics(source_key, ref, content, updated_at)
      VALUES(?,?,?,?)
      ON CONFLICT(source_key, ref) DO UPDATE SET
        content=excluded.content, updated_at=excluded.updated_at
    ''', [sourceKey, ref, content, DateTime.now().millisecondsSinceEpoch]);
  }

  /// 标记「已查过但无歌词」：仅在没有记录时写入空串，
  /// 不覆盖并发补读写回的内嵌歌词。
  void markLyricsMissing(String sourceKey, String ref) {
    _db!.execute('''
      INSERT INTO song_lyrics(source_key, ref, content, updated_at)
      VALUES(?,?,'',?)
      ON CONFLICT(source_key, ref) DO NOTHING
    ''', [sourceKey, ref, DateTime.now().millisecondsSinceEpoch]);
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
      SELECT i.id, i.source_key, i.ref, i.title, i.artist, i.album, i.album_artist, i.track_no,
             i.year, i.genre, i.duration, i.format, i.size, i.cover_path, i.url, i.missing,
             i.meta_read, COALESCE(p.is_favorite, 0) AS favorite
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
  /// 直连歌优先现查索引，保证后台补读/编辑元数据后喜欢页即时反映最新封面与专辑信息。
  List<Song> likedSongs() {
    final rows = _db!.select(
        'SELECT source_key, song_ref, song_json FROM play_meta WHERE is_favorite=1');
    final out = <Song>[];
    for (final r in rows) {
      final srcKey = r['source_key'] as String;
      final ref = r['song_ref'] as String;
      final live = srcKey == 'server' ? null : _songByRef(srcKey, ref);
      if (live != null) {
        out.add(live);
        continue;
      }
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
      SELECT i.id, i.source_key, i.ref, i.title, i.artist, i.album, i.album_artist, i.track_no,
             i.year, i.genre, i.duration, i.format, i.size, i.cover_path, i.url, i.missing,
             i.meta_read, COALESCE(p.is_favorite, 0) AS favorite
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
      SELECT i.id, i.source_key, i.ref, i.title, i.artist, i.album, i.album_artist, i.track_no,
             i.year, i.genre, i.duration, i.format, i.size, i.cover_path, i.url, i.missing,
             i.meta_read, COALESCE(p.is_favorite, 0) AS favorite
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
        albumArtist: r['album_artist'] as String?,
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
        metaRead: (r['meta_read'] as int? ?? 0) == 1,
      );

  /// 从 source_key（'webdav:name'）取协议名（'webdav'）。
  String _sourceOf(String key) {
    final i = key.indexOf(':');
    return i > 0 ? key.substring(0, i) : key;
  }

  // ---------- offline cache ----------

  /// 自定义缓存目录（空=默认应用目录下 cache；机器相关，不进导出白名单）。
  static const String kCacheDirCustom = 'cache_dir_custom';

  String? get customCacheDir {
    final v = settingsGet(kCacheDirCustom);
    return (v == null || v.isEmpty) ? null : v;
  }

  String get _cacheDir {
    final custom = customCacheDir;
    final d = (custom != null && Directory(custom).existsSync())
        ? custom
        : p.join(_dir!, 'cache');
    Directory(d).createSync(recursive: true);
    return d;
  }

  /// 缓存目录（设置页展示用）。
  String get cacheDir => _cacheDir;

  /// 当前缓存占用（字节）与文件数（设置页展示用）。
  int cacheTotalBytes() {
    var total = 0;
    for (final r in listCache()) {
      total += r.size;
    }
    return total;
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

  /// 迁移缓存目录：建新目录（含可写校验）→ 逐个移动 .dat 并更新 path 列 →
  /// 切换设置。返回迁移文件数；失败抛异常（调用方 toast），可重试继续。
  Future<int> migrateCacheDir(String newDir) async {
    final target = Directory(newDir);
    target.createSync(recursive: true);
    final probe = File(p.join(target.path, '.writetest'));
    probe.writeAsStringSync('ok');
    probe.deleteSync();
    final oldDir = cacheDir;
    if (p.normalize(oldDir) == p.normalize(target.path)) return 0;
    var moved = 0;
    for (final r in listCache()) {
      final src = File(cachePathForKey(r.cacheKey));
      if (!src.existsSync()) continue;
      final dstPath = p.join(target.path, '${r.cacheKey}.dat');
      src.renameSync(dstPath);
      _db!.execute('UPDATE cache SET path=? WHERE cache_key=?',
          [dstPath, r.cacheKey]);
      moved++;
    }
    settingsSet(kCacheDirCustom, target.path);
    return moved;
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
  /// NOTE：play_meta 各列为 NOT NULL，且 ON CONFLICT 需区分「未传（保持原值）」
  /// 与「传 0（清零）」。VALUES 里用 COALESCE(?,0) 会把「未传」也变成 0，
  /// 导致 excluded 行覆盖掉刚写入的收藏等状态；因此先读当前行在 Dart 侧合并，
  /// 再写入全非 null 值，CONFLICT 时直接用 excluded 覆盖。
  void upsertPlayMeta(String sourceKey, String songRef,
      {int? likeStreak, int? dislikeStreak, double? factor, bool? frozen,
      bool? favorite, String? songJson}) {
    final cur = playMetaOf(sourceKey, songRef);
    _db!.execute('''
      INSERT INTO play_meta(source_key, song_ref, like_streak, dislike_streak,
        factor, frozen, is_favorite, song_json)
      VALUES(?,?,?,?,?,?,?,?)
      ON CONFLICT(source_key, song_ref) DO UPDATE SET
        like_streak = excluded.like_streak,
        dislike_streak = excluded.dislike_streak,
        factor = excluded.factor,
        frozen = excluded.frozen,
        is_favorite = excluded.is_favorite,
        song_json = COALESCE(excluded.song_json, play_meta.song_json)
    ''', [
      sourceKey,
      songRef,
      likeStreak ?? cur.likeStreak,
      dislikeStreak ?? cur.dislikeStreak,
      factor ?? cur.factor,
      (frozen ?? cur.frozen) ? 1 : 0,
      (favorite ?? cur.favorite) ? 1 : 0,
      songJson ?? cur.songJson,
    ]);
  }

  // ---------- 歌单（stage2.md §1.2） ----------

  int createPlaylist(String name, {String? description}) {
    _db!.execute(
        'INSERT INTO playlists(name, description, created_at, client_uuid, deleted) '
        'VALUES(?,?,?,?,0)',
        [name, description, DateTime.now().toIso8601String(), newEventUuid()]);
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
        'SELECT id, name, description, created_at, client_uuid FROM playlists ORDER BY id');
    return rs.map((r) => PlaylistRow(
          id: r['id'] as int,
          name: r['name'] as String,
          description: r['description'] as String?,
          createdAt: r['created_at'] as String,
          clientUuid: r['client_uuid'] as String?,
        )).toList();
  }

  void addPlaylistItem(int playlistId,
      {required String sourceKey, required String songRef,
      required String title, String? artist, String? album, String? coverPath,
      String? source}) {
    final max = _db!
        .select('SELECT COALESCE(MAX(sort_order),0) m FROM playlist_items WHERE playlist_id=?',
            [playlistId])
        .first['m'] as int;
    final now = DateTime.now().toIso8601String();
    _db!.execute('''
      INSERT INTO playlist_items(playlist_id, source_key, song_ref, title, artist,
        album, cover_path, sort_order, added_at, source)
      VALUES(?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(playlist_id, source_key, song_ref) DO NOTHING
    ''', [playlistId, sourceKey, songRef, title, artist, album, coverPath, max + 1, now, source]);
  }

  void removePlaylistItem(int playlistId, String sourceKey, String songRef) {
    // 兼容历史 ENCODE/Unicode ref 形态：逐一删除。
    for (final variant in webdavRefVariants(songRef)) {
      _db!.execute(
          'DELETE FROM playlist_items WHERE playlist_id=? AND source_key=? AND song_ref=?',
          [playlistId, sourceKey, variant]);
    }
  }

  /// 该歌已在哪些歌单中（兼容 WebDAV 历史 ENCODE/Unicode 两种 ref 形态）。
  Set<int> playlistIdsContaining(String sourceKey, String songRef) {
    final out = <int>{};
    for (final variant in webdavRefVariants(songRef)) {
      final rs = _db!.select(
          'SELECT DISTINCT playlist_id FROM playlist_items WHERE source_key=? AND song_ref=?',
          [sourceKey, variant]);
      for (final r in rs) {
        out.add(r['playlist_id'] as int);
      }
    }
    return out;
  }

  List<PlaylistItemRow> playlistItems(int playlistId) {
    final rs = _db!.select('''
      SELECT id, playlist_id, source_key, song_ref, title, artist, album,
             cover_path, sort_order, source
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
          source: r['source'] as String?,
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

  // ---------- 多设备同步 outbox（阶段5，DESIGN §7.2） ----------

  /// 事件 uuid（服务端 event_uuid 幂等键；36 列内唯一即可，不需标准 UUID 形态）。
  static String newEventUuid() {
    final r = Random.secure();
    final tail = List.generate(3,
            (_) => r.nextInt(0xffffffff).toRadixString(16).padLeft(8, '0'))
        .join();
    return '${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}-${tail.substring(0, 12)}';
  }

  /// 本地变更入队（同步方法，供权重/歌单/断点写路径直接调用；调用方负责按身份与服务器可达性过滤）。
  /// 返回 event_uuid。
  String enqueueOutbox(String type, Map<String, dynamic> payload) {
    final uuid = newEventUuid();
    final now = DateTime.now().toIso8601String();
    _db!.execute(
        'INSERT INTO weight_outbox(event_uuid, type, payload, occurred_at, acked, created_at) '
        'VALUES(?,?,?,?,0,?)',
        [uuid, type, jsonEncode(payload), now, now]);
    return uuid;
  }

  /// 未确认事件（SyncEngine 上推用，按入队序）。
  List<OutboxRow> pendingOutbox({int limit = 500}) {
    final rs = _db!.select(
        'SELECT event_uuid, type, payload, occurred_at FROM weight_outbox '
        'WHERE acked=0 ORDER BY rowid LIMIT ?',
        [limit]);
    return [
      for (final r in rs)
        OutboxRow(
          eventUuid: r['event_uuid'] as String,
          type: r['type'] as String,
          payload: r['payload'] as String,
          occurredAt: r['occurred_at'] as String,
        )
    ];
  }

  int pendingOutboxCount() {
    return _db!
        .select('SELECT COUNT(*) c FROM weight_outbox WHERE acked=0')
        .first['c'] as int;
  }

  /// 已被服务端接受（含去重命中）：删队，避免表无限增长。
  void deleteOutbox(Iterable<String> uuids) {
    for (final uuid in uuids) {
      _db!.execute('DELETE FROM weight_outbox WHERE event_uuid=?', [uuid]);
    }
  }

  /// 服务端明确拒绝（游离引用等）：进死信，不再重试，避免毒丸循环。
  void deadLetterOutbox(Iterable<String> uuids) {
    for (final uuid in uuids) {
      _db!.execute(
          'UPDATE weight_outbox SET acked=2 WHERE event_uuid=?', [uuid]);
    }
  }

  /// 歌单跨设备标识： legacy 行按需补发；新建行在 [createPlaylist] 已直接写入。
  String ensurePlaylistUuid(int id) {
    final rs = _db!
        .select('SELECT client_uuid FROM playlists WHERE id=?', [id]);
    if (rs.isEmpty) throw StateError('playlist not found: $id');
    var uuid = rs.first['client_uuid'] as String?;
    if (uuid == null || uuid.isEmpty) {
      uuid = newEventUuid();
      _db!.execute(
          'UPDATE playlists SET client_uuid=? WHERE id=?', [uuid, id]);
    }
    return uuid;
  }

  String? playlistUuidOf(int id) {
    final rs = _db!
        .select('SELECT client_uuid FROM playlists WHERE id=?', [id]);
    if (rs.isEmpty) return null;
    return rs.first['client_uuid'] as String?;
  }

  int? playlistIdOfUuid(String uuid) {
    final rs = _db!
        .select('SELECT id FROM playlists WHERE client_uuid=?', [uuid]);
    if (rs.isEmpty) return null;
    return rs.first['id'] as int;
  }

  /// pull 歌单快照落库（deleted=true 则本地硬删）。
  /// 条目只替换服务端歌曲行（source_key='server'）：本地直连歌曲行保留，
  /// 由本机 push 事件与服务端收敛（直连歌曲同样参与同步，见 DESIGN §7.2）。
  void applyPlaylistSnapshot({
    required String uuid,
    required String name,
    String? description,
    required bool deleted,
    required List<SyncedItem> items,
  }) {
    final id = playlistIdOfUuid(uuid);
    if (deleted) {
      if (id != null) deletePlaylist(id);
      return;
    }
    final int pid;
    if (id == null) {
      _db!.execute(
          'INSERT INTO playlists(name, description, created_at, client_uuid, deleted) '
          'VALUES(?,?,?,?,0)',
          [name, description, DateTime.now().toIso8601String(), uuid]);
      pid = _db!.lastInsertRowId;
    } else {
      _db!.execute('UPDATE playlists SET name=?, description=? WHERE id=?',
          [name, description, id]);
      pid = id;
    }
    _db!.execute(
        'DELETE FROM playlist_items WHERE playlist_id=? AND source_key=?',
        [pid, 'server']);
    for (final it in items) {
      _db!.execute('''
        INSERT INTO playlist_items(playlist_id, source_key, song_ref, title, artist,
          album, cover_path, sort_order, added_at, source)
        VALUES(?,?,?,?,?,?,?,?,?,?)
      ''', [
        pid,
        'server',
        it.songRef,
        it.title,
        it.artist,
        it.album,
        null,
        it.sortOrder,
        DateTime.now().toIso8601String(),
        it.source,
      ]);
    }
  }

  /// 元数据读取情况汇总（侧边栏「信息」页，改进 B6-4）。
  /// 口径：total=全部行；missing=失效行；其余维度按有效行（missing=0）统计
  /// 非空即"已获取"。码率无独立列，用"大小+时长齐全可估算"近似。
  Map<String, int> metaStats() {
    int bit(dynamic v) => (v as num?)?.toInt() ?? 0;
    final r = _db!.select('''
      SELECT COUNT(*) total,
        COALESCE(SUM(i.missing),0) missing,
        COALESCE(SUM(CASE WHEN i.missing=0 AND COALESCE(i.meta_read,0)=1 THEN 1 ELSE 0 END),0) meta_read,
        COALESCE(SUM(CASE WHEN i.missing=0 AND i.artist IS NOT NULL AND i.artist<>'' THEN 1 ELSE 0 END),0) artist,
        COALESCE(SUM(CASE WHEN i.missing=0 AND i.album IS NOT NULL AND i.album<>'' THEN 1 ELSE 0 END),0) album,
        COALESCE(SUM(CASE WHEN i.missing=0 AND i.album_artist IS NOT NULL AND i.album_artist<>'' THEN 1 ELSE 0 END),0) album_artist,
        COALESCE(SUM(CASE WHEN i.missing=0 AND i.genre IS NOT NULL AND i.genre<>'' THEN 1 ELSE 0 END),0) genre,
        COALESCE(SUM(CASE WHEN i.missing=0 AND i.track_no IS NOT NULL THEN 1 ELSE 0 END),0) track_no,
        COALESCE(SUM(CASE WHEN i.missing=0 AND i.year IS NOT NULL THEN 1 ELSE 0 END),0) year,
        COALESCE(SUM(CASE WHEN i.missing=0 AND i.duration IS NOT NULL AND i.duration>0 THEN 1 ELSE 0 END),0) duration,
        COALESCE(SUM(CASE WHEN i.missing=0 AND i.cover_path IS NOT NULL AND i.cover_path<>'' THEN 1 ELSE 0 END),0) cover,
        COALESCE(SUM(CASE WHEN i.missing=0 AND l.content IS NOT NULL AND l.content<>'' THEN 1 ELSE 0 END),0) lyrics,
        COALESCE(SUM(CASE WHEN i.missing=0 AND i.format IS NOT NULL AND i.format<>'' THEN 1 ELSE 0 END),0) format,
        COALESCE(SUM(CASE WHEN i.missing=0 AND i.size>0 AND i.duration>0 THEN 1 ELSE 0 END),0) bitrate
      FROM idx_songs i LEFT JOIN song_lyrics l
        ON l.source_key=i.source_key AND l.ref=i.ref
    ''').first;
    return {
      for (final k in [
        'total', 'missing', 'meta_read', 'artist', 'album', 'album_artist',
        'genre', 'track_no', 'year', 'duration', 'cover', 'lyrics', 'format',
        'bitrate',
      ])
        k: bit(r[k]),
    };
  }

  /// 按格式分组计数（有效行，信息页用）。
  Map<String, int> formatStats() {
    final rs = _db!.select('''
      SELECT COALESCE(NULLIF(format,''),'未知') f, COUNT(*) c
      FROM idx_songs WHERE missing=0 GROUP BY f ORDER BY c DESC
    ''');
    return {for (final r in rs) (r['f'] as String): (r['c'] as int)};
  }

  /// pull 歌曲权重快照落 play_meta：先写 ('server', ref) 行（服务端歌曲），
  /// 再按快照 [source] 协议匹配本地直连行（同 ref 含 WebDAV 编码变体 + 同协议），
  /// 各写各的源 key（运行时按源 key 读权重，见 playMetaOf）。
  /// 直连歌曲在连着服务器时同样参与同步（DESIGN §7.2 影子行）。
  void applySongSnapshot({
    required String songRef,
    String? source,
    required int likeStreak,
    required int dislikeStreak,
    required double factor,
    required bool frozen,
    required bool favorite,
  }) {
    void write(String key, String ref) => upsertPlayMeta(key, ref,
        likeStreak: likeStreak,
        dislikeStreak: dislikeStreak,
        factor: factor,
        frozen: frozen,
        favorite: favorite);
    write('server', songRef);
    if (source == null || source.isEmpty) return;
    final refs = <String>{songRef, ...webdavRefVariants(songRef)};
    for (final v in refs) {
      final rows = _db!.select(
          'SELECT source_key, ref FROM idx_songs WHERE ref=?', [v]);
      for (final r in rows) {
        final key = r['source_key'] as String;
        if (key == 'server') continue;
        if (_sourceOf(key) != source) continue;
        write(key, r['ref'] as String);
      }
    }
  }

  /// pull 断点写入镜像表（不碰运行时 play_state，见 SyncEngine）。
  void upsertBreakpointMirror({
    required String playlistUuid,
    int? songId,
    String? source,
    String? sourceRef,
    required int positionMs,
    required String updatedAt,
    String? deviceId,
  }) {
    _db!.execute(
        'INSERT INTO breakpoint_mirror(playlist_uuid, song_id, source, source_ref, '
        'position_ms, updated_at, device_id) VALUES(?,?,?,?,?,?,?) '
        'ON CONFLICT(playlist_uuid) DO UPDATE SET '
        'song_id=excluded.song_id, source=excluded.source, source_ref=excluded.source_ref, '
        'position_ms=excluded.position_ms, updated_at=excluded.updated_at, '
        'device_id=excluded.device_id',
        [playlistUuid, songId, source, sourceRef, positionMs, updatedAt, deviceId]);
  }

  BreakpointMirrorRow? breakpointMirrorOf(String playlistUuid) {
    final rs = _db!.select(
        'SELECT playlist_uuid, song_id, source, source_ref, position_ms, updated_at, device_id '
        'FROM breakpoint_mirror WHERE playlist_uuid=?',
        [playlistUuid]);
    if (rs.isEmpty) return null;
    final r = rs.first;
    return BreakpointMirrorRow(
      playlistUuid: r['playlist_uuid'] as String,
      songId: r['song_id'] as int?,
      source: r['source'] as String?,
      sourceRef: r['source_ref'] as String?,
      positionMs: r['position_ms'] as int,
      updatedAt: r['updated_at'] as String,
      deviceId: r['device_id'] as String?,
    );
  }

  void deleteBreakpointMirror(String playlistUuid) {
    _db!.execute(
        'DELETE FROM breakpoint_mirror WHERE playlist_uuid=?', [playlistUuid]);
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
  final String? albumArtist;
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
    this.albumArtist,
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

/// 服务端歌曲元数据本地覆盖（空字段=不覆盖）。
class MetaOverride {
  final String? title;
  final String? artist;
  final String? album;
  final String? albumArtist;
  const MetaOverride(
      {this.title, this.artist, this.album, this.albumArtist});

  bool get isEmpty =>
      title == null && artist == null && album == null && albumArtist == null;
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

/// 歌单行（stage2.md §1.2；clientUuid 为阶段5 跨设备全局标识）。
class PlaylistRow {
  final int id;
  final String name;
  final String? description;
  final String createdAt;
  final String? clientUuid;
  const PlaylistRow({
    required this.id,
    required this.name,
    this.description,
    required this.createdAt,
    this.clientUuid,
  });
}

/// 歌单条目行（含歌曲快照字段，离线或源失效仍可展示；source 为阶段5 同步用归属源）。
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
  final String? source;
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
    this.source,
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

/// 同步 outbox 行（阶段5）。
class OutboxRow {
  final String eventUuid;
  final String type;
  final String payload;
  final String occurredAt;
  const OutboxRow({
    required this.eventUuid,
    required this.type,
    required this.payload,
    required this.occurredAt,
  });
}

/// pull 歌单条目快照（阶段5；source_key 恒 'server'，由落库方补）。
class SyncedItem {
  final String? source;
  final String songRef;
  final String? title;
  final String? artist;
  final String? album;
  final int sortOrder;
  const SyncedItem({
    this.source,
    required this.songRef,
    this.title,
    this.artist,
    this.album,
    required this.sortOrder,
  });
}

/// 远端断点镜像行（阶段5；只读展示/续播用，不驱动运行时播放）。
class BreakpointMirrorRow {
  final String playlistUuid;
  final int? songId;
  final String? source;
  final String? sourceRef;
  final int positionMs;
  final String updatedAt;
  final String? deviceId;
  const BreakpointMirrorRow({
    required this.playlistUuid,
    this.songId,
    this.source,
    this.sourceRef,
    required this.positionMs,
    required this.updatedAt,
    this.deviceId,
  });
}
