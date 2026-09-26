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
import 'db_writer.dart';
import 'schema.dart';

/// 直连模式本地轻量索引（DESIGN §6.4）。///
/// SQLite 存放：已配置的直连源（[DirectSourceRow]）、索引歌曲（[Song]）、
/// 离线缓存（[CachedFile]）。扫描时按 `(sourceKey, ref)` 的 mtime/size 三元组做增量。
class LocalIndex {
  Database? _db;
  String? _dir;
  DbWriter? _writer;

  Future<void> open() async {
    if (_db != null) return;
    final support = await getApplicationSupportDirectory();
    _dir = p.join(support.path, 'selfmusic');
    Directory(_dir!).createSync(recursive: true);
    final dbPath = p.join(_dir!, 'selfmusic.db');
    // 读连接（主线程，只读使用；写全部经 _writer 后台隔离，见 db_writer.dart）。
    _db = sqlite3.open(dbPath);
    _db!.execute('PRAGMA busy_timeout=30000;');
    applySchema(_db!);
    // 写隔离：独立连接 + 自动批事务 + NORMAL 同步（fsync 离开 UI 线程）。
    _writer = await DbWriter.start(dbPath);
    // 历史 ENCODE 形态的 play_meta 行一次性迁移到当前 ref（写隔离内执行）。
    // 之后读路径不再写库，避免 UI 线程出现「读前迁移」的 I/O。
    await _writer!.op<void>('migrateMetaRefs', const {});
  }

  /// 等待写隔离中排队写全部落库（退出前、导出等需要持久一致性的时点）。
  Future<void> flushWrites() => _writer!.flush();

  void close() {
    // 写隔离火速回收（未落库排队写丢弃，调用方负责先 flush）。
    _writer?.dispose();
    _writer = null;
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

  Future<void> upsertSource(String key, String kind, String name, String config) {
    return _writer!.exec(
        'INSERT INTO sources(key, kind, name, config) VALUES(?,?,?,?) '
        'ON CONFLICT(key) DO UPDATE SET name=excluded.name, config=excluded.config, kind=excluded.kind',
        [key, kind, name, config]);
  }

  /// 源实例 uuid（跨设备同步身份）：无则生成并落库（写经后台隔离）。
  Future<String> ensureSourceUuid(String key) async {
    final rs = _db!.select('SELECT client_uuid FROM sources WHERE key=?', [key]);
    if (rs.isEmpty) throw StateError('source not found: $key');
    final cur = rs.first['client_uuid'] as String?;
    if (cur != null && cur.isNotEmpty) return cur;
    final uuid = newEventUuid();
    await _writer!.exec(
        'UPDATE sources SET client_uuid=? WHERE key=?', [uuid, key]);
    return uuid;
  }

  /// 源实例 uuid（未生成返回 null）。
  String? sourceUuidOf(String key) {
    final rs = _db!.select('SELECT client_uuid FROM sources WHERE key=?', [key]);
    if (rs.isEmpty) return null;
    final v = rs.first['client_uuid'] as String?;
    return (v == null || v.isEmpty) ? null : v;
  }

  /// 按源实例 uuid 反查本地源 key（未配置对应源返回 null）。
  String? sourceKeyOfUuid(String uuid) {
    if (uuid.isEmpty) return null;
    final rs = _db!.select('SELECT key FROM sources WHERE client_uuid=?', [uuid]);
    return rs.isEmpty ? null : rs.first['key'] as String;
  }

  Future<void> updateSourceScan(String key, String status) {
    return _writer!.exec(
        'UPDATE sources SET status=?, last_scan_at=? WHERE key=?',
        [status, DateTime.now().toIso8601String(), key]);
  }

  Future<void> deleteSource(String key) =>
      _writer!.op<void>('deleteSource', {'key': key});

  /// 源改名：源 key 由名称派生，改名时同步迁移所有引用该 key 的数据，
  /// 保证已索引歌曲、收藏、歌单条目在改名后仍然有效。
  Future<void> renameSource(String oldKey, String newKey) async {
    if (oldKey == newKey) return;
    await _writer!.op<void>('renameSource', {
      'oldKey': oldKey,
      'newKey': newKey,
    });
  }

  /// 应用服务端源快照（阶段5 源同步）：
  /// - deleted → 本地硬删（源 + 索引）；
  /// - uuid 命中 → 更新名称/配置/开关；
  /// - 未命中 → 按 (kind, 地址) 去重合并（同址视为同一源，采纳远端 uuid）；
  /// - 均无 → 以 `kind:名称` 建行（重名加后缀）。
  /// 返回是否发生变更（调用方据此重建内存源与 UI）。
  /// 内部读取全部在写连接上完成，保证与其它入队写的一致性。
  Future<bool> applySourceSnapshot({
    required String uuid,
    required String kind,
    String? name,
    required String address,
    Map<String, dynamic>? config,
    required bool enabled,
    required bool deleted,
  }) {
    return _writer!.op<bool>('applySourceSnapshot', {
      'uuid': uuid,
      'kind': kind,
      'name': name,
      'address': address,
      'config': config,
      'enabled': enabled,
      'deleted': deleted,
    });
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
  /// 覆盖保护：
  /// - 用户手动改过元数据的行（user_edited=1）：标题/歌手/专辑不再被扫描覆盖；
  /// - 其余行：扫描未解析出的空值不覆盖已存值（浅扫描重扫不丢已读元数据）；
  ///   兜底标题（文件名，[DirectSongRow.titleFromMeta]=false）仅在旧值为空时填入；
  /// - meta_read：本次解析出时长（完整读取）才标已读，否则重置为未读，
  ///   交给播放/后台补读做一次完整重读（指纹变化行数据自愈）。
  /// 复用写隔离的 [DbWriter.opBatch] 单事务整批落库。
  Future<void> upsertSongs(List<DirectSongRow> songs) {
    if (songs.isEmpty) return Future.value();
    return _writer!.op<void>('upsertSongs', {
      'rows': [for (final s in songs) s.toRowMap()],
    });
  }

  /// 播放懒补全：把播放时解析出的额外元数据（标题/歌手/专辑/专辑歌手/时长/流派/
  /// 曲目/年份/封面）回填，并标记已读（后台不再重复扫描）。
  /// 用户手改过的行（user_edited=1）不回写文本字段，只补技术字段。
Future<void> enrichSong(String sourceKey, String songRef,
    {String? title,
    String? artist,
    String? album,
    String? albumArtist,
    int? duration,
    String? genre,
    int? trackNo,
    int? year,
    String? coverPath}) {
  return _writer!.exec('''
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
  Future<int> resetMetaReadForMissingCovers() {
    return _writer!.execUpdated(
        "UPDATE idx_songs SET meta_read=0 "
        "WHERE meta_read=1 AND cover_path IS NULL AND format IN ('mp3','flac')");
  }

  /// 块序异常元数据回填补读（旧版解析遇大封面/PICTURE 在 VORBIS_COMMENT
  /// 之前时提前中断，已标已读却没有歌手等信息）：把始终没有歌手的行重置为
  /// 未读，交给后台补读用「从头完整读取」重取。[sourceKeys] 限定直连源
  /// （服务端代理行不参与本地补读）；所有格式统一。
  /// 返回重置行数。
  Future<int> resetMetaReadForMissingArtist(List<String> sourceKeys) {
    if (sourceKeys.isEmpty) return Future.value(0);
    final marks = List.filled(sourceKeys.length, '?').join(',');
    return _writer!.execUpdated(
        'UPDATE idx_songs SET meta_read=0 '
        'WHERE meta_read=1 AND artist IS NULL AND source_key IN ($marks)',
        sourceKeys);
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
Future<void> updateSongUserMeta(String sourceKey, String songRef,
    {String? title, String? artist, String? album, String? albumArtist}) {
  return _writer!.op<void>('updateSongUserMeta', {
    'sourceKey': sourceKey,
    'songRef': songRef,
    'title': title,
    'artist': artist,
    'album': album,
    'albumArtist': albumArtist,
  });
}

/// 同步 play_meta 歌曲快照中的标题/歌手/专辑/专辑歌手（直连改库用）。
/// '' 表示清空为未知（写 null）。
/// 读快照在主连接上进行（song_json 仅此路径写），再经写隔离落库。
Future<void> syncMetaSnapshot(String sourceKey, String songRef,
    {String? title, String? artist, String? album, String? albumArtist}) async {
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
    await _writer!.exec(
        'UPDATE play_meta SET song_json=? WHERE source_key=? AND song_ref=?',
        [jsonEncode(j), sourceKey, songRef]);
  } catch (_) {
    // 快照损坏则忽略（下次收藏时重写）。
  }
}

  /// 把嵌入封面包装成可跨源复用的落盘（`covers/<md5(ref)>.jpg`），返回路径或 null。
  /// 仅接受图片签名通过的字节（防止描述残留/URL 等脏数据落盘致解码报错）。
  /// 幂等：已有同尺寸封面则跳过重写（启动期因此免去大量无谓写盘）。
  String? persistCover(Uint8List cover, String ref) {
    if (cover.isEmpty || !looksLikeImageBytes(cover)) return null;
    try {
      final dir = p.join(_dir!, 'covers');
      Directory(dir).createSync(recursive: true);
      final h = md5.convert(utf8.encode(ref)).toString();
      final filePath = p.join(dir, '$h.jpg');
      final f = File(filePath);
      if (f.existsSync() && f.lengthSync() == cover.length) return filePath;
      f.writeAsBytesSync(cover, flush: true);
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
          await _writer!.exec(
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
  Future<void> markMissingExcept(String sourceKey, List<String> aliveRefs) {
    // 用 jsonEncode 生成合法 JSON 数组，避免 ref 含引号/反斜杠时破坏 json_each。
    return _writer!.exec(
        'UPDATE idx_songs SET missing=1 WHERE source_key=? '
        'AND ref NOT IN (SELECT value FROM json_each(?))',
        [sourceKey, jsonEncode(aliveRefs)]);
  }

  /// 删除该源下已标记 missing 且未收藏的行（保留收藏中的缺失歌，等源恢复）。
  Future<void> clearMissing(String sourceKey) {
    return _writer!.op<void>('clearMissing', {'sourceKey': sourceKey});
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
  Future<void> setLyrics(String sourceKey, String ref, String content) {
    return _writer!.exec('''
      INSERT INTO song_lyrics(source_key, ref, content, updated_at)
      VALUES(?,?,?,?)
      ON CONFLICT(source_key, ref) DO UPDATE SET
        content=excluded.content, updated_at=excluded.updated_at
    ''', [sourceKey, ref, content, DateTime.now().millisecondsSinceEpoch]);
  }

  /// 标记「已查过但无歌词」：仅在没有记录时写入空串，
  /// 不覆盖并发补读写回的内嵌歌词。
  Future<void> markLyricsMissing(String sourceKey, String ref) {
    return _writer!.exec('''
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
  /// 合并读在写连接内完成（见 db_writer `setFavorite`），避免与权重写互相覆盖。
  Future<void> setFavorite(String sourceKey, String songRef, bool fav,
      {String? songJson}) {
    return _writer!.op<void>('setFavorite', {
      'sourceKey': sourceKey,
      'songRef': songRef,
      'favorite': fav,
      'songJson': songJson,
    });
  }

  /// 权重/收藏事件落库（complete/skip/liked/unfavorite/disliked/reset）。
  ///
  /// 读 streak/factor 与写回必须同在写连接内完成：主连接可能读到尚未提交的旧值，
  /// 连续两次事件（如连续完播）会互相覆盖丢更新。权重上下界由 SongWeightStore
  /// 传入（单一来源）。
  Future<void> applyWeightEvent(
    String sourceKey,
    String songRef,
    String event, {
    bool? enabled,
    String? songJson,
    required double minFactor,
    required double maxFactor,
    required double step,
    required double defaultFactor,
  }) {
    return _writer!.op<void>('applyWeightEvent', {
      'sourceKey': sourceKey,
      'songRef': songRef,
      'event': event,
      'enabled': enabled,
      'songJson': songJson,
      'minFactor': minFactor,
      'maxFactor': maxFactor,
      'step': step,
      'defaultFactor': defaultFactor,
    });
  }

  /// 非默认权重行（补推用）：streak 非零 / factor 非 1.0 / 锁定 / 收藏。
  /// 默认态服务端本就是初值，无需补推。
  List<PlayMetaRow> listDirtyPlayMeta() {
    final rs = _db!.select(
        'SELECT source_key, song_ref, like_streak, dislike_streak, factor, '
        'frozen, is_favorite, song_json, play_sec FROM play_meta '
        'WHERE like_streak<>0 OR dislike_streak<>0 OR factor<>1.0 '
        'OR frozen<>0 OR is_favorite<>0 OR play_sec<>0');
    return [
      for (final r in rs)
        PlayMetaRow(
          sourceKey: r['source_key'] as String,
          songRef: r['song_ref'] as String,
          likeStreak: r['like_streak'] as int,
          dislikeStreak: r['dislike_streak'] as int,
          factor: (r['factor'] as num).toDouble(),
          frozen: (r['frozen'] as int) != 0,
          favorite: (r['is_favorite'] as int) != 0,
          songJson: r['song_json'] as String?,
          playSec: (r['play_sec'] as int?) ?? 0,
        ),
    ];
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

  Future<void> cacheSave(String cacheKey, List<int> bytes) {
    final now = DateTime.now().toIso8601String();
    File(cachePathForKey(cacheKey)).writeAsBytesSync(bytes, flush: true);
    return _writer!.exec(
        'INSERT INTO cache(cache_key, path, size, cached_at, last_accessed_at) '
        'VALUES(?,?,?,?,?) ON CONFLICT(cache_key) DO UPDATE SET size=excluded.size, cached_at=COALESCE(excluded.cached_at, cache.cached_at)',
        [cacheKey, cachePathForKey(cacheKey), bytes.length, now, now]);
  }

  /// 把下载好的临时文件移入缓存目录并登记（流式缓存，避免整文件常驻内存）。
  Future<void> cacheCommit(String cacheKey, String tmpFilePath, int size) {
    final dst = cachePathForKey(cacheKey);
    if (File(dst).existsSync()) File(dst).deleteSync();
    File(tmpFilePath).renameSync(dst);
    final now = DateTime.now().toIso8601String();
    return _writer!.exec(
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
      await _writer!.exec('UPDATE cache SET path=? WHERE cache_key=?',
          [dstPath, r.cacheKey]);
      moved++;
    }
    settingsSet(kCacheDirCustom, target.path);
    return moved;
  }

  /// 播放/访问缓存时刷新最后访问时间（LRU 依据，fire-and-forget 落库）。
  void touchCache(String cacheKey) {
    _writer!.execFire(
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

  Future<void> deleteCache(String cacheKey) {
    final f = File(cachePathForKey(cacheKey));
    if (f.existsSync()) f.deleteSync();
    return _writer!.exec('DELETE FROM cache WHERE cache_key=?', [cacheKey]);
  }

  // ---------- play_meta（阶段 2：权重 / 收藏，stage2.md §1.1） ----------

  /// 读 play_meta（纯读；历史 ENCODE 旧行迁移见 open() 的 migrateMetaRefs）。
  PlayMetaRow playMetaOf(String sourceKey, String songRef) {
    final rs = _db!.select(
        'SELECT source_key, song_ref, like_streak, dislike_streak, factor, frozen, is_favorite, song_json, play_sec '
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
      playSec: (r['play_sec'] as int?) ?? 0,
    );
  }

  /// 累计播放时长（秒）加法：`play_sec += seconds`（写连接内累加，见 db_writer）。
  Future<void> addPlaySec(String sourceKey, String songRef, int seconds) {
    return _writer!.op<void>('addPlaySec', {
      'sourceKey': sourceKey,
      'songRef': songRef,
      'seconds': seconds,
    });
  }

  bool isFavoriteOf(String sourceKey, String songRef) =>
      playMetaOf(sourceKey, songRef).favorite;

  /// 全量更新一首歌的权重元数据（null 保持原值）。
  ///
  /// NOTE：play_meta 各列为 NOT NULL，且 ON CONFLICT 需区分「未传（保持原值）」
  /// 与「传 0（清零）」。VALUES 里用 COALESCE(?,0) 会把「未传」也变成 0，
  /// 导致 excluded 行覆盖掉刚写入的收藏等状态；因此先读当前行再合并。
  /// 合并读在写连接内完成（见 db_writer `upsertPlayMeta`），保证与收藏等
  /// 已入队写的一致性。
  Future<void> upsertPlayMeta(String sourceKey, String songRef,
      {int? likeStreak,
      int? dislikeStreak,
      double? factor,
      bool? frozen,
      bool? favorite,
      String? songJson,
      int? playSec}) {
    return _writer!.op<void>('upsertPlayMeta', {
      'sourceKey': sourceKey,
      'songRef': songRef,
      'likeStreak': likeStreak,
      'dislikeStreak': dislikeStreak,
      'factor': factor,
      'frozen': frozen,
      'favorite': favorite,
      'songJson': songJson,
      'playSec': playSec,
    });
  }

  // ---------- 歌单（stage2.md §1.2） ----------

  Future<int> createPlaylist(String name, {String? description}) {
    return _writer!.op<int>('createPlaylist',
        {'name': name, 'description': description});
  }

  Future<void> renamePlaylist(int id, String name) {
    return _writer!.exec('UPDATE playlists SET name=? WHERE id=?', [name, id]);
  }

  Future<void> deletePlaylist(int id) {
    return _writer!.op<void>('deletePlaylist', {'id': id});
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

  /// 歌单内歌曲匹配：返回含匹配歌曲（标题/歌手，忽略大小写）的歌单 id 集合。
  /// 单条 SQL 完成，供歌单页搜索（搜索内容是歌单中的具体歌曲）。
  Set<int> playlistIdsMatchingSong(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const {};
    final escaped = q
        .replaceAll(r'\', r'\\')
        .replaceAll('%', r'\%')
        .replaceAll('_', r'\_');
    final like = '%$escaped%';
    final rs = _db!.select(
        "SELECT DISTINCT playlist_id FROM playlist_items "
        r"WHERE lower(title) LIKE ? ESCAPE '\' "
        r"OR lower(IFNULL(artist,'')) LIKE ? ESCAPE '\'",
        [like, like]);
    return {for (final r in rs) r['playlist_id'] as int};
  }

  Future<void> addPlaylistItem(int playlistId,
      {required String sourceKey, required String songRef,
      required String title, String? artist, String? album, String? coverPath,
      String? source}) {
    return _writer!.op<void>('addPlaylistItem', {
      'playlistId': playlistId,
      'sourceKey': sourceKey,
      'songRef': songRef,
      'title': title,
      'artist': artist,
      'album': album,
      'coverPath': coverPath,
      'source': source,
    });
  }

  Future<void> removePlaylistItem(
      int playlistId, String sourceKey, String songRef) async {
    // 兼容历史 ENCODE/Unicode ref 形态：逐一删除（单事务整体提交）。
    final ph = List.filled(webdavRefVariants(songRef).length, '?').join(',');
    await _writer!.exec(
        'DELETE FROM playlist_items WHERE playlist_id=? AND source_key=? '
        'AND song_ref IN ($ph)',
        [playlistId, sourceKey, ...webdavRefVariants(songRef)]);
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
  /// 相邻判定在写连接内完成（见 db_writer `movePlaylistItem`）。
  Future<void> movePlaylistItem(int playlistId, int itemId, int delta) {
    return _writer!.op<void>('movePlaylistItem', {
      'playlistId': playlistId,
      'itemId': itemId,
      'delta': delta,
    });
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

  /// 本地变更入队（uuid 同步生成，落库进写隔离后返回）。
  /// 返回 event_uuid。
  Future<String> enqueueOutbox(String type, Map<String, dynamic> payload) async {
    final uuid = newEventUuid();
    final now = DateTime.now().toIso8601String();
    await _writer!.exec(
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
  Future<void> deleteOutbox(Iterable<String> uuids) {
    final list = uuids.toList();
    if (list.isEmpty) return Future.value();
    return _writer!.exec(
        'DELETE FROM weight_outbox WHERE event_uuid IN '
        '(${List.filled(list.length, '?').join(',')})',
        list);
  }

  /// 服务端明确拒绝（游离引用等）：进死信，不再重试，避免毒丸循环。
  Future<void> deadLetterOutbox(Iterable<String> uuids) {
    final list = uuids.toList();
    if (list.isEmpty) return Future.value();
    return _writer!.exec(
        'UPDATE weight_outbox SET acked=2 WHERE event_uuid IN '
        '(${List.filled(list.length, '?').join(',')})',
        list);
  }

  /// 歌单跨设备标识： legacy 行按需补发；新建行在 [createPlaylist] 已直接写入。
  Future<String> ensurePlaylistUuid(int id) =>
      _writer!.op<String>('ensurePlaylistUuid', {'id': id});

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
  /// 整段逻辑（源 key 解析 + 封面保留）运行在写连接上，避免读到陈旧歌单条目。
  Future<void> applyPlaylistSnapshot({
    required String uuid,
    required String name,
    String? description,
    required bool deleted,
    required List<SyncedItem> items,
  }) {
    return _writer!.op<void>('applyPlaylistSnapshot', {
      'uuid': uuid,
      'name': name,
      'description': description,
      'deleted': deleted,
      'items': [
        for (final it in items)
          {
            'sourceId': it.sourceId,
            'source': it.source,
            'songRef': it.songRef,
            'title': it.title,
            'artist': it.artist,
            'album': it.album,
            'sortOrder': it.sortOrder,
          }
      ],
    });
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
  Future<void> applySongSnapshot({
    required String songRef,
    String? source,
    String? sourceId,
    required int likeStreak,
    required int dislikeStreak,
    required double factor,
    required bool frozen,
    required bool favorite,
  }) {
    return _writer!.op<void>('applySongSnapshot', {
      'songRef': songRef,
      'source': source,
      'sourceId': sourceId,
      'likeStreak': likeStreak,
      'dislikeStreak': dislikeStreak,
      'factor': factor,
      'frozen': frozen,
      'favorite': favorite,
    });
  }

  /// 批量 pull 歌曲权重快照：单事务整批落 play_meta（SyncEngine 每页一次调用，
  /// 避免逐行事务 fsync）。
  Future<void> applySongSnapshots(List<Map<String, dynamic>> snapshots) {
    if (snapshots.isEmpty) return Future.value();
    return _writer!.opBatch('applySongSnapshots', snapshots);
  }

  /// pull 断点写入镜像表（不碰运行时 play_state，见 SyncEngine）。
  Future<void> upsertBreakpointMirror({
    required String playlistUuid,
    int? songId,
    String? sourceId,
    String? source,
    String? sourceRef,
    required int positionMs,
    String? deepListJson,
    required String updatedAt,
    String? deviceId,
  }) {
    return _writer!.exec(
        'INSERT INTO breakpoint_mirror(playlist_uuid, song_id, source_id, source, source_ref, '
        'position_ms, deep_list_json, updated_at, device_id) VALUES(?,?,?,?,?,?,?,?,?) '
        'ON CONFLICT(playlist_uuid) DO UPDATE SET '
        'song_id=excluded.song_id, source_id=excluded.source_id, source=excluded.source, '
        'source_ref=excluded.source_ref, position_ms=excluded.position_ms, '
        'deep_list_json=excluded.deep_list_json, '
        'updated_at=excluded.updated_at, device_id=excluded.device_id',
        [playlistUuid, songId, sourceId, source, sourceRef, positionMs,
         deepListJson, updatedAt, deviceId]);
  }

  BreakpointMirrorRow? breakpointMirrorOf(String playlistUuid) {
    final rs = _db!.select(
        'SELECT playlist_uuid, song_id, source_id, source, source_ref, position_ms, deep_list_json, updated_at, device_id '
        'FROM breakpoint_mirror WHERE playlist_uuid=?',
        [playlistUuid]);
    if (rs.isEmpty) return null;
    final r = rs.first;
    return BreakpointMirrorRow(
      playlistUuid: r['playlist_uuid'] as String,
      songId: r['song_id'] as int?,
      sourceId: r['source_id'] as String?,
      source: r['source'] as String?,
      sourceRef: r['source_ref'] as String?,
      positionMs: r['position_ms'] as int,
      deepListJson: r['deep_list_json'] as String?,
      updatedAt: r['updated_at'] as String,
      deviceId: r['device_id'] as String?,
    );
  }

  Future<void> deleteBreakpointMirror(String playlistUuid) {
    return _writer!.exec(
        'DELETE FROM breakpoint_mirror WHERE playlist_uuid=?', [playlistUuid]);
  }

  // ---------- 深层列表（隐藏历史栈，仅本机，按锚定键键控） ----------

  Future<void> saveDeepList(String playlistUuid, String entriesJson) {
    return _writer!.exec(
        'INSERT INTO deep_lists(playlist_uuid, entries_json, updated_at) VALUES(?,?,?) '
        'ON CONFLICT(playlist_uuid) DO UPDATE SET entries_json=excluded.entries_json, '
        'updated_at=excluded.updated_at',
        [playlistUuid, entriesJson, DateTime.now().toIso8601String()]);
  }

  String? loadDeepList(String playlistUuid) {
    final rs = _db!.select(
        'SELECT entries_json FROM deep_lists WHERE playlist_uuid=?',
        [playlistUuid]);
    return rs.isEmpty ? null : rs.first['entries_json'] as String;
  }

  Future<void> deleteDeepList(String playlistUuid) {
    return _writer!.exec('DELETE FROM deep_lists WHERE playlist_uuid=?',
        [playlistUuid]);
  }

  // ---------- 应用设置（settings.md §3） ----------

  /// 设置内存缓存：AppSettings 的每个 getter 都会触发 settingsGet，歌曲列表每行
  /// 读取标题格式又是一条 SQL——滑动/进入页时几千行 × 1 次同步查询全压在 UI 线程。
  /// 写入与全部读取统一收口于此方法，缓存恒一致（backup_service 导入同样走 settingsSet）。
  final Map<String, String> _settingsCache = {};
  static const String _settingsNull = '\u0000';

  String? settingsGet(String key) {
    if (_settingsCache.containsKey(key)) {
      final v = _settingsCache[key]!;
      return v == _settingsNull ? null : v;
    }
    final rs = _db!.select('SELECT value FROM app_settings WHERE key=?', [key]);
    final v = rs.isEmpty ? null : rs.first['value'] as String;
    _settingsCache[key] = v ?? _settingsNull;
    return v;
  }

  /// 保持同步（AppSettings 数十个 getter/setter 与 build() 直读依赖），
  /// 内存缓存立即生效，落库 fire-and-forget 进写隔离。
  void settingsSet(String key, String value) {
    _settingsCache[key] = value;
    _writer!.execFire(
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

  Future<void> savePlayState(String queueJson, int idx, int positionMs,
      {String? playlistUuid, String? anchorKey}) {
    return _writer!.exec(
        'INSERT INTO play_state(id, queue_json, idx, position_ms, updated_at, playlist_uuid, anchor_key) '
        'VALUES(1,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET '
        'queue_json=excluded.queue_json, idx=excluded.idx, '
        'position_ms=excluded.position_ms, updated_at=excluded.updated_at, '
        'playlist_uuid=excluded.playlist_uuid, anchor_key=excluded.anchor_key',
        [queueJson, idx, positionMs, DateTime.now().toIso8601String(),
            playlistUuid, anchorKey]);
  }

  PlayStateRow? getPlayState() {
    final rs = _db!.select(
        'SELECT queue_json, idx, position_ms, updated_at, playlist_uuid, anchor_key FROM play_state WHERE id=1');
    if (rs.isEmpty) return null;
    final r = rs.first;
    return PlayStateRow(
      queueJson: r['queue_json'] as String,
      idx: r['idx'] as int,
      positionMs: r['position_ms'] as int,
      updatedAt: r['updated_at'] as String,
      playlistUuid: r['playlist_uuid'] as String?,
      anchorKey: r['anchor_key'] as String?,
    );
  }

  /// 歌单条目 → 可播放歌曲列表（按 sort_order 排序；给跨设备断点恢复重建队列用）。
  List<Song> playlistSongs(int playlistId) {
    final rows = _db!.select(
        'SELECT source_key, song_ref, title, artist, album, cover_path, source '
        'FROM playlist_items WHERE playlist_id=? ORDER BY sort_order, id',
        [playlistId]);
    return [
      for (final r in rows)
        Song(
          id: 0,
          sourceKey: r['source_key'] as String,
          title: (r['title'] as String?) ?? '',
          artist: r['artist'] as String?,
          albumName: r['album'] as String?,
          sourceRef: r['song_ref'] as String,
          source: (r['source'] as String?) ??
              ((r['source_key'] as String).contains(':')
                  ? (r['source_key'] as String)
                      .substring(0, (r['source_key'] as String).indexOf(':'))
                  : r['source_key'] as String),
          fileSize: 0,
          coverPath: r['cover_path'] as String?,
        ),
    ];
  }

  /// 全部跨设备断点镜像（启动优先最新断点用）。
  List<BreakpointMirrorRow> allBreakpointMirrors() {
    final rs = _db!.select(
        'SELECT playlist_uuid, song_id, source_id, source, source_ref, position_ms, '
        'deep_list_json, updated_at, device_id FROM breakpoint_mirror');
    return [
      for (final r in rs)
        BreakpointMirrorRow(
          playlistUuid: r['playlist_uuid'] as String,
          songId: r['song_id'] as int?,
          sourceId: r['source_id'] as String?,
          source: r['source'] as String?,
          sourceRef: r['source_ref'] as String?,
          positionMs: r['position_ms'] as int,
          deepListJson: r['deep_list_json'] as String?,
          updatedAt: r['updated_at'] as String,
          deviceId: r['device_id'] as String?,
        ),
    ];
  }

  Future<void> clearPlayState() {
    return _writer!.exec('DELETE FROM play_state WHERE id=1');
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

  /// 标题是否来自真实标签（false=文件名兜底）：兜底标题不覆盖已存标题。
  final bool titleFromMeta;
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
    this.titleFromMeta = true,
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

  /// 序列化给写隔离（keys 与 [_opUpsertSongs] 约定的绑定参数一一对应）。
  Map<String, dynamic> toRowMap() => {
        'sourceKey': sourceKey,
        'ref': ref,
        'url': url,
        'title': title,
        'titleFromMeta': titleFromMeta,
        'artist': artist,
        'album': album,
        'albumArtist': albumArtist,
        'trackNo': trackNo,
        'year': year,
        'genre': genre,
        'duration': duration,
        'format': format,
        'size': size,
        'mtime': mtime,
        'etag': etag,
        'coverPath': coverPath,
      };
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

  /// 累计播放时长（秒，整数）。播放次数由它派生：playSec / 歌曲时长（1 位小数）。
  final int playSec;
  const PlayMetaRow({
    required this.sourceKey,
    required this.songRef,
    required this.likeStreak,
    required this.dislikeStreak,
    required this.factor,
    required this.frozen,
    required this.favorite,
    this.songJson,
    this.playSec = 0,
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

  /// 队列归属的已同步歌单 uuid（跨设备断点归属；通用队列为 null）。
  final String? playlistUuid;

  /// 融合队列锚定键（任意列表上下文：playlist:<uuid>/liked/songs/album:<id>/
  /// artist:<id>/source:<key>；重启恢复锚定与深层历史用）。
  final String? anchorKey;
  const PlayStateRow({
    required this.queueJson,
    required this.idx,
    required this.positionMs,
    required this.updatedAt,
    this.playlistUuid,
    this.anchorKey,
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
  final String? sourceId;
  final String? source;
  final String songRef;
  final String? title;
  final String? artist;
  final String? album;
  final int sortOrder;
  const SyncedItem({
    this.sourceId,
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
  final String? sourceId;
  final String? source;
  final String? sourceRef;
  final int positionMs;
  final String? deepListJson;
  final String updatedAt;
  final String? deviceId;
  const BreakpointMirrorRow({
    required this.playlistUuid,
    this.songId,
    this.sourceId,
    this.source,
    this.sourceRef,
    required this.positionMs,
    this.deepListJson,
    required this.updatedAt,
    this.deviceId,
  });
}
