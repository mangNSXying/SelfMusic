import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../models/song.dart';
import '../../models/album.dart';
import '../../models/artist.dart';
import '../../utils/collection_sort.dart';
import '../../utils/cover_thumb.dart';
import '../../utils/chunked_scheduler.dart' show ChunkYield, yieldToEventLoop;
import '../../utils/off_thread.dart';
import '../../utils/main_thread_probe.dart';
import '../../utils/perf_log.dart';
import '../sources/webdav_url.dart';
import 'audio_metadata.dart';
import 'db_writer.dart';

/// 直连模式本地轻量索引（DEVELOPER.md「客户端扫描与元数据」）。///
/// SQLite 存放：已配置的直连源（[DirectSourceRow]）、索引歌曲（[Song]）、
/// 离线缓存（[CachedFile]）。扫描时按 `(sourceKey, ref)` 的 mtime/size 三元组做增量。
class LocalIndex {
  Database? _db;
  String? _dir;

  /// 数据库文件路径（后台 isolate 快照读时另开连接用；open 后非空）。
  String? _dbPath;
  DbWriter? _writer;

  Future<void> open() async {
    if (_db != null) return;
    final support = await getApplicationSupportDirectory();
    _dir = p.join(support.path, 'selfmusic');
    Directory(_dir!).createSync(recursive: true);
    final dbPath = p.join(_dir!, 'selfmusic.db');
    _dbPath = dbPath;
    // 写隔离与主读连接并行启动（spawn 期间主连接即可打开）：schema 迁移与
    // 历史 play_meta ENCODE 行的一次性探测/迁移统一在写隔离 init 内完成
    //（db_writer），主连接不再重复 CREATE/ALTER/PRAGMA，也不在启动链上做
    // 任何读扫描（曾把 instr 全表探测压在 UI 线程启动 await 链上）。
    final writerFuture = DbWriter.start(dbPath);
    // 读连接（主线程，只读使用；写经 _writer：全平台后台隔离，OHOS 仅在
    // 写隔离启动失败/超时时回退内联，见 db_writer.dart）。
    _db = sqlite3.open(dbPath);
    print('[index] 主连接已打开');
    _db!.execute('PRAGMA busy_timeout=30000;');
    _writer = await writerFuture;
    print('[index] 写隔离就绪（schema 与 legacy 迁移完成）');
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

  Future<void> upsertSource(
      String key, String kind, String name, String config) {
    return _writer!.exec(
        'INSERT INTO sources(key, kind, name, config) VALUES(?,?,?,?) '
        'ON CONFLICT(key) DO UPDATE SET name=excluded.name, config=excluded.config, kind=excluded.kind',
        [key, kind, name, config]);
  }

  /// 源实例 uuid（跨设备同步身份）：无则生成并落库（写经后台隔离）。
  Future<String> ensureSourceUuid(String key) async {
    final rs =
        _db!.select('SELECT client_uuid FROM sources WHERE key=?', [key]);
    if (rs.isEmpty) throw StateError('source not found: $key');
    final cur = rs.first['client_uuid'] as String?;
    if (cur != null && cur.isNotEmpty) return cur;
    final uuid = newEventUuid();
    await _writer!
        .exec('UPDATE sources SET client_uuid=? WHERE key=?', [uuid, key]);
    return uuid;
  }

  /// 源实例 uuid（未生成返回 null）。
  String? sourceUuidOf(String key) {
    final rs =
        _db!.select('SELECT client_uuid FROM sources WHERE key=?', [key]);
    if (rs.isEmpty) return null;
    final v = rs.first['client_uuid'] as String?;
    return (v == null || v.isEmpty) ? null : v;
  }

  /// 按源实例 uuid 反查本地源 key（未配置对应源返回 null）。
  String? sourceKeyOfUuid(String uuid) {
    if (uuid.isEmpty) return null;
    final rs =
        _db!.select('SELECT key FROM sources WHERE client_uuid=?', [uuid]);
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
    return _writer!.execUpdated("UPDATE idx_songs SET meta_read=0 "
        "WHERE meta_read=1 AND cover_path IS NULL AND format IN ('mp3','flac')");
  }

  /// 内嵌成功后刷新文件指纹（size/mtime）：嵌入改写了文件，扫描不能再把它
  /// 当“未变化”跳过、也不能当“新变化”重读覆盖——指纹同步后扫描即静默。
  /// 文本保护（user_edited）与已读标记（meta_read）保持不变：文件标签与
  /// DB 已一致（验签保证），song_lyrics/covers/ 即校验基准。
  Future<void> updateFileFingerprint(
      String sourceKey, String songRef, int size, int mtime) {
    return _writer!.exec(
        'UPDATE idx_songs SET size=?, mtime=? WHERE source_key=? AND ref=?',
        [size, mtime, sourceKey, songRef]);
  }

  /// ID3v2.3 帧长回填补读（帧长 syncsafe/BE32 口径修复）：旧版把 v2.3 帧长按
  /// v2.4 syncsafe 解，大 APIC 被截成半图丢弃、其后 USLT 也对不上，已标已读
  /// 但无封面的 mp3/aac 行重置为未读，交给后台补读重取。返回重置行数。
  Future<int> resetMetaReadForMissingId3Covers() {
    return _writer!.execUpdated("UPDATE idx_songs SET meta_read=0 "
        "WHERE meta_read=1 AND cover_path IS NULL AND format IN ('mp3','aac')");
  }

  /// wav/aiFF 尾块标签回填补读（新增能力）：旧版只在头部找 RIFF/FORM 块，遇到
  /// `data`/`SSND` 就 break，工具写在音频块**之后**的 `id3 ` 块（标题/歌手/封面）
  /// 从来读不到，而这些行已标已读 → 不会被补读。把它们重置为未读。
  /// 返回重置行数。
  Future<int> resetMetaReadForRiffTailTags() {
    return _writer!.execUpdated("UPDATE idx_songs SET meta_read=0 "
        "WHERE meta_read=1 AND (cover_path IS NULL OR artist IS NULL) "
        "AND format IN ('wav','aif','aiff','aifc')");
  }

  /// FLAC 前置 ID3v2 回填补读（TagLib/MusicPlayer2 口径）：旧版解析要求
  /// `fLaC` 必须在 offset 0，带前置 ID3v2 的文件会整首读空却已标已读
  /// （artist 为空）。重置这些行，交给后台补读重取。返回重置行数。
  Future<int> resetMetaReadForFlacId3Prefix() {
    return _writer!.execUpdated("UPDATE idx_songs SET meta_read=0 "
        "WHERE meta_read=1 AND artist IS NULL AND format IN ('flac')");
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

  /// 用户手动修改歌曲元数据：标题/歌手/专辑/年份落库并标记 user_edited=1（扫描不再覆盖），
  /// 同时同步 play_meta 歌曲快照中的对应字段（喜欢列表/断点恢复用快照渲染）。
  /// 字段语义：null=不修改；''=清空（置 NULL，UI 显示为未知）；
  /// 年份用 [year]/[clearYear]：null 且不清=不修改，非空=新值，clearYear=清空。
  Future<void> updateSongUserMeta(String sourceKey, String songRef,
      {String? title,
      String? artist,
      String? album,
      String? albumArtist,
      int? year,
      bool clearYear = false}) {
    return _writer!.op<void>('updateSongUserMeta', {
      'sourceKey': sourceKey,
      'songRef': songRef,
      'title': title,
      'artist': artist,
      'album': album,
      'albumArtist': albumArtist,
      'year': year,
      'clearYear': clearYear,
    });
  }

  /// 同步 play_meta 歌曲快照中的标题/歌手/专辑/专辑歌手（直连改库用）。
  /// '' 表示清空为未知（写 null）。
  /// 读快照在主连接上进行（song_json 仅此路径写），再经写隔离落库。
  Future<void> syncMetaSnapshot(String sourceKey, String songRef,
      {String? title,
      String? artist,
      String? album,
      String? albumArtist}) async {
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
  /// 仅接受轻量完整性通过的字节（问题1：只验头会把半图落盘且标已读）。
  /// 幂等：已有同尺寸**且完整**封面则跳过重写（启动期因此免去大量无谓写盘）；
  /// 同尺寸但现文件截断时覆盖重写，让好图能替换旧半图。
  /// 原子落盘：先写 tmp 再 rename，避免崩溃/断电留下半文件。
  String? persistCover(Uint8List cover, String ref) {
    if (cover.isEmpty || !isCompleteImageBytes(cover)) return null;
    try {
      final dir = p.join(_dir!, 'covers');
      Directory(dir).createSync(recursive: true);
      final h = md5.convert(utf8.encode(ref)).toString();
      final filePath = p.join(dir, '$h.jpg');
      final f = File(filePath);
      if (f.existsSync() &&
          f.lengthSync() == cover.length &&
          _existingCoverComplete(f)) {
        return filePath;
      }
      // 覆盖写新封面：旧缩略图作废删除，随后由 ensureCoverThumb 重新生成。
      deleteCoverThumb(filePath);
      final tmp = File('$filePath.tmp');
      try {
        tmp.writeAsBytesSync(cover, flush: true);
        tmp.renameSync(filePath);
      } catch (_) {
        try {
          if (tmp.existsSync()) tmp.deleteSync();
        } catch (_) {}
        rethrow;
      }
      return filePath;
    } catch (_) {
      return null;
    }
  }

  /// [persistCover] 的**切片让出版**（主线程长同步块治理 R-1 / FR-001）：封面字节的
  /// md5 哈希与落盘分片进行、片间 [yieldTo] 让出事件循环，避免大内嵌封面（可达
  /// [kMetaRegionCapBytes]）在主线程形成长同步块。语义与 [persistCover] 完全一致：
  /// 完整性校验 / 幂等跳过（同尺寸且完整才跳）/ 旧缩略图作废 / 原子落盘 / 返回路径或 null。
  Future<String?> persistCoverChunked(Uint8List cover, String ref,
      {ChunkYield? yieldTo}) async {
    if (cover.isEmpty || !isCompleteImageBytes(cover)) return null;
    final nextTick = yieldTo ?? yieldToEventLoop;
    try {
      final dir = p.join(_dir!, 'covers');
      Directory(dir).createSync(recursive: true);
      final h = await _md5HexChunked(cover, nextTick);
      final filePath = p.join(dir, '$h.jpg');
      final f = File(filePath);
      if (f.existsSync() &&
          f.lengthSync() == cover.length &&
          _existingCoverComplete(f)) {
        return filePath;
      }
      // 覆盖写新封面：旧缩略图作废删除，随后由 ensureCoverThumb 重新生成。
      deleteCoverThumb(filePath);
      final tmp = File('$filePath.tmp');
      try {
        await _writeBytesChunked(tmp, cover, nextTick);
        tmp.renameSync(filePath);
      } catch (_) {
        try {
          if (tmp.existsSync()) tmp.deleteSync();
        } catch (_) {}
        rethrow;
      }
      return filePath;
    } catch (_) {
      return null;
    }
  }

  /// 现存封面文件是否完整（同尺寸幂等跳过前用）：只读头 12B + 尾 4B，
  /// 不整文件读入内存。判不完整时返回 false，调用方覆盖重写。
  bool _existingCoverComplete(File f) {
    try {
      final len = f.lengthSync();
      if (len < 12) return false;
      final raf = f.openSync(mode: FileMode.read);
      try {
        final head = raf.readSync(12);
        if (!looksLikeImageBytes(head)) return false;
        // JPEG：尾2B须为 FFD9。
        if (head[0] == 0xFF && head[1] == 0xD8) {
          raf.setPositionSync(len - 2);
          final tail = raf.readSync(2);
          return tail.length == 2 && tail[0] == 0xFF && tail[1] == 0xD9;
        }
        // PNG：尾4B须为 AE426082。
        if (head[0] == 0x89 && head[1] == 0x50) {
          raf.setPositionSync(len - 4);
          final tail = raf.readSync(4);
          return tail.length == 4 &&
              tail[0] == 0xAE &&
              tail[1] == 0x42 &&
              tail[2] == 0x60 &&
              tail[3] == 0x82;
        }
        // GIF：尾字节 3B。
        if (head[0] == 0x47 && head[1] == 0x49) {
          raf.setPositionSync(len - 1);
          final tail = raf.readSync(1);
          return tail.length == 1 && tail[0] == 0x3B;
        }
        // BMP：声明大小须等于实际（0 无法校验按通过）。
        if (head[0] == 0x42 && head[1] == 0x4D) {
          final declared =
              head[2] | (head[3] << 8) | (head[4] << 16) | (head[5] << 24);
          if (declared == 0) return true;
          return declared == len;
        }
        // WEBP：RIFF+8 须等于实际（0 按通过）。
        if (head[0] == 0x52 && head[1] == 0x49) {
          final riff =
              head[4] | (head[5] << 8) | (head[6] << 16) | (head[7] << 24);
          if (riff == 0) return true;
          return riff + 8 == len;
        }
        return true; // ftyp：无廉价尾判
      } finally {
        raf.closeSync();
      }
    } catch (_) {
      return false;
    }
  }

  /// 封面落盘**目标路径**（沿用 [persistCover] 口径：`covers/<md5(ref)>.jpg`）。
  ///
  /// 仅供 ohos 原生解析把封面直接写到该路径（Dart 侧不再持有/重解析封面字节），
  /// 由 `extractAudioMeta` 的 `coverPath` 入参使用。目录不可用时返回 null。
  String? coverPathFor(String ref) {
    final root = _dir;
    if (root == null) return null;
    try {
      final dir = p.join(root, 'covers');
      Directory(dir).createSync(recursive: true);
      final h = md5.convert(utf8.encode(ref)).toString();
      return p.join(dir, '$h.jpg');
    } catch (_) {
      return null;
    }
  }

  /// 全部有效封面路径（缩略图后台补齐用；去重且跳过 missing 行）。
  List<String> allCoverPaths() {
    final db = _db;
    if (db == null) return const [];
    final rs = db.select('SELECT DISTINCT cover_path FROM idx_songs '
        "WHERE missing=0 AND cover_path IS NOT NULL AND cover_path<>''");
    return [for (final r in rs) r['cover_path'] as String];
  }

  /// 清理历史无效封面（旧解析缺陷曾把描述残留/URL 写盘，Android 解码器会刷错误日志；
  /// 问题1的半图：只验头落盘的截断 JPEG/PNG，尾判不通过）：
  /// 删除无效封面文件，并把引用它们的歌标为未读（`cover_path=NULL, meta_read=0`），
  /// 让补读用修复后的解析重取。每次启动都跑，自动清理存量半图。
  ///
  /// 目录遍历与逐文件校验（同步 IO，封面目录可能上万文件）放后台 isolate；
  /// 原来在主 isolate 分块让出事件循环仍会穿插卡 UI；现全平台（含 OHOS）
  /// 经 `runOffThread` 在真实后台 isolate 执行。
  Future<int> cleanupInvalidCovers() async {
    final root = _dir;
    if (root == null || _db == null) return 0;
    final stale = await runOffThread(
        () => collectInvalidCoverPaths(p.join(root, 'covers')));
    var cleaned = 0;
    for (final path in stale) {
      await _writer!.exec(
          'UPDATE idx_songs SET cover_path=NULL, meta_read=0 WHERE cover_path=?',
          [path]);
      // 原图已删，派生缩略图一并删掉，避免孤儿文件（下次补读会重新生成）。
      deleteCoverThumb(path);
      cleaned++;
    }
    return cleaned;
  }

  /// 扫描结束后把不再存在的条目标记 missing（DEVELOPER.md「客户端扫描与元数据」 增量）。
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

  /// 硬删一首歌曲的全部本地痕迹（阶段6 删除全删）：
  /// idx_songs + play_meta + song_lyrics + playlist_items + artist_song_map。
  /// 缓存文件/行由调用方另行经 [deleteCache] 清理（cache_key 需源侧计算）。
  Future<void> deleteSong(String sourceKey, String ref) {
    return _writer!.op<void>('deleteSong', {'sourceKey': sourceKey, 'ref': ref});
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

  /// SFTP 主机密钥 TOFU 钉：读（无记录返回 null）。
  /// `hostPort` 形态 `host:port`（host 小写，见 `sftpHostPort`）。
  String? sshFingerprint(String hostPort) {
    final rs = _db!.select(
        'SELECT fingerprint FROM ssh_known_hosts WHERE host_port=?',
        [hostPort]);
    if (rs.isEmpty) return null;
    final v = rs.first['fingerprint'];
    return v is String && v.isNotEmpty ? v : null;
  }

  /// 钉住/更新主机指纹（用户弹窗确认后调用）。
  Future<void> sshPin(String hostPort, String fingerprint) {
    return _writer!.exec('''
      INSERT INTO ssh_known_hosts(host_port, fingerprint, updated_at)
      VALUES(?,?,?)
      ON CONFLICT(host_port) DO UPDATE SET
        fingerprint=excluded.fingerprint, updated_at=excluded.updated_at
    ''', [hostPort, fingerprint, DateTime.now().millisecondsSinceEpoch]);
  }

  /// 忘记主机指纹（指纹变更后用户选择重认前清理，或删源时按需调用）。
  Future<void> sshForget(String hostPort) {
    return _writer!.exec(
        'DELETE FROM ssh_known_hosts WHERE host_port=?', [hostPort]);
  }

  /// 「忽略音频（时长/大小）」过滤子句（改进.txt 功能6）：设置变更后，
  /// 已扫描入库的歌曲也按规则过滤——时长未知（NULL/0，快扫未读头）一律放过。
  /// 返回 `(sqlFragment, extraArgs)`；两个阈值均为 0 时条件恒真（零开销兜底）。
  /// 实现见顶层 [ignoreFilterSql]（后台 isolate 读快照共用同一份 SQL）。
  ({String sql, List<Object?> args}) _ignoreFilterSql(
          int minDurationSec, int minSizeBytes) =>
      ignoreFilterSql(minDurationSec, minSizeBytes);

  List<Song> searchSongs({
    required String sourceKey,
    String? query,
    int page = 1,
    int? size,
    int minDurationSec = 0,
    int minSizeBytes = 0,
  }) =>
      querySongs(_db!,
          sourceKey: sourceKey,
          query: query,
          page: page,
          size: size,
          minDurationSec: minDurationSec,
          minSizeBytes: minSizeBytes);

  int countSongs(String sourceKey,
      {int minDurationSec = 0, int minSizeBytes = 0}) {
    final ignore = _ignoreFilterSql(minDurationSec, minSizeBytes);
    final rs = _db!.select('''
        SELECT COUNT(*) c FROM idx_songs i
        WHERE i.source_key=? AND i.missing=0 ${ignore.sql}
        ''', [sourceKey, ...ignore.args]);
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
    required double dislikedFactor,
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
      'dislikedFactor': dislikedFactor,
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
  /// 忽略音频过滤（改进.txt 功能6）只作用于索引落库的直连歌（服务器歌快照非本地扫描产物不放行拦截）。
  List<Song> likedSongs({int minDurationSec = 0, int minSizeBytes = 0}) {
    final rows = _db!.select(
        'SELECT source_key, song_ref, song_json FROM play_meta WHERE is_favorite=1');
    final out = <Song>[];
    for (final r in rows) {
      final srcKey = r['source_key'] as String;
      final ref = r['song_ref'] as String;
      final live = srcKey == 'server' ? null : _songByRef(srcKey, ref);
      if (live != null) {
        if (_passesIgnoreFilter(live, minDurationSec, minSizeBytes)) {
          out.add(live);
        }
        continue;
      }
      final json = r['song_json'] as String?;
      if (json != null && json.isNotEmpty) {
        try {
          final s = Song.fromJson(jsonDecode(json) as Map<String, dynamic>);
          // 服务器歌不占 idx_songs，规则对其不适用（见方法注释）。
          out.add(s);
          continue;
        } catch (_) {}
      }
      final s = _songByRef(srcKey, ref);
      if (s != null && _passesIgnoreFilter(s, minDurationSec, minSizeBytes)) {
        out.add(s);
      }
    }
    return out;
  }

  /// 按 ref 回查歌曲：兼容新旧两种入库形态（解码态 / 历史 ENCODE 文本）。
  Song? songByRef(String sourceKey, String ref) => _songByRef(sourceKey, ref);

  /// 批量按 (source_key, ref) 取实时行（启动恢复整队解析/歌单详情装配用）：
  /// 把 N 次单行 SELECT 收敛为每个源少量 IN 查询，消除 UI 线程 N+1
  /// （1262 首实测 885ms）。返回与输入等长的列表；无对应行（服务器歌快照
  /// 等）原样保留。同一 ref 被多条目重复引用（歌单内重复歌）时，所有位置
  /// 都解析为同一实时行。
  List<Song> resolveLiveSongs(List<Song> songs) {
    if (songs.isEmpty) return songs;
    final bySource = <String, List<int>>{};
    for (var i = 0; i < songs.length; i++) {
      bySource.putIfAbsent(songs[i].sourceKey, () => <int>[]).add(i);
    }
    final out = List<Song>.of(songs);
    for (final entry in bySource.entries) {
      final sourceKey = entry.key;
      // variant → 引用它的全部位置（重复条目共享同一实时行）。
      final variantToPos = <String, List<int>>{};
      final refs = <String>[];
      for (final pos in entry.value) {
        for (final v in webdavRefVariants(songs[pos].sourceRef)) {
          final positions = variantToPos[v];
          if (positions == null) {
            variantToPos[v] = [pos];
            refs.add(v);
          } else {
            positions.add(pos);
          }
        }
      }
      final resolved = <int>{};
      for (var start = 0; start < refs.length; start += 400) {
        final end = start + 400 < refs.length ? start + 400 : refs.length;
        final chunk = refs.sublist(start, end);
        final placeholders = List.filled(chunk.length, '?').join(',');
        final rows = _db!.select('''
          SELECT i.id, i.source_key, i.ref, i.title, i.artist, i.album, i.album_artist, i.track_no,
                 i.year, i.genre, i.duration, i.format, i.size, i.cover_path, i.url, i.missing,
                 i.meta_read, COALESCE(p.is_favorite, 0) AS favorite
          FROM idx_songs i
          LEFT JOIN play_meta p ON p.source_key = i.source_key AND p.song_ref = i.ref
          WHERE i.source_key=? AND i.ref IN ($placeholders)
        ''', [sourceKey, ...chunk]);
        for (final r in rows) {
          final positions = variantToPos[r['ref'] as String];
          if (positions == null) continue;
          final live = _rowToSong(r);
          for (final pos in positions) {
            if (resolved.add(pos)) out[pos] = live;
          }
        }
      }
    }
    return out;
  }

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

  List<Song> favorites(String sourceKey,
      {int minDurationSec = 0, int minSizeBytes = 0}) {
    final ignore = _ignoreFilterSql(minDurationSec, minSizeBytes);
    final rows = _db!.select('''
      SELECT i.id, i.source_key, i.ref, i.title, i.artist, i.album, i.album_artist, i.track_no,
             i.year, i.genre, i.duration, i.format, i.size, i.cover_path, i.url, i.missing,
             i.meta_read, COALESCE(p.is_favorite, 0) AS favorite
      FROM idx_songs i
      LEFT JOIN play_meta p ON p.source_key = i.source_key AND p.song_ref = i.ref
      WHERE i.source_key=? AND i.missing=0 AND COALESCE(p.is_favorite, 0) = 1
        ${ignore.sql}
      ORDER BY i.artist, i.album, i.track_no
    ''', [sourceKey, ...ignore.args]);
    return rows.map(_rowToSong).toList();
  }

  /// 忽略音频规则是否放行（改进.txt 功能6）：时长/大小未知（NULL/0）一律放过。
  static bool _passesIgnoreFilter(
      Song s, int minDurationSec, int minSizeBytes) {
    final d = s.duration;
    if (minDurationSec > 0 && d != null && d > 0 && d < minDurationSec) {
      return false;
    }
    final size = s.fileSize;
    if (minSizeBytes > 0 && size > 0 && size < minSizeBytes) return false;
    return true;
  }

  /// 行 → 歌曲模型。实现见顶层 [songFromRow]（后台 isolate 读快照共用）。
  Song _rowToSong(Row r) => songFromRow(r);

  // ---------- offline cache ----------

  /// 自定义缓存目录（空=默认应用目录下 cache；机器相关，不进导出白名单）。
  static const String kCacheDirCustom = 'cache_dir_custom';

  /// 自定义缓存目录的授权 URI（鸿蒙 FolderSelection；重启后需激活）。
  static const String kCacheDirUri = 'cache_dir_uri';

  String? get customCacheDir {
    final v = settingsGet(kCacheDirCustom);
    return (v == null || v.isEmpty) ? null : v;
  }

  String? get customCacheDirUri {
    final v = settingsGet(kCacheDirUri);
    return (v == null || v.isEmpty) ? null : v;
  }

  bool _cacheDirFallback = false;

  bool get usingDefaultCacheDir => customCacheDir == null || _cacheDirFallback;

  void markCacheDirUnavailable() {
    _cacheDirFallback = true;
  }

  bool get customCacheDirWritable {
    final custom = customCacheDir;
    if (custom == null) return true;
    try {
      final probe = File(p.join(custom, '.writetest'));
      probe.writeAsStringSync('ok');
      probe.deleteSync();
      return true;
    } catch (_) {
      return false;
    }
  }

  String get _cacheDir {
    final custom = customCacheDir;
    final d = (custom != null &&
            !_cacheDirFallback &&
            Directory(custom).existsSync())
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

  /// 是否已缓存：按库里的权威路径判（见 [cachePathOfKey]），不用当前缓存目录
  /// 派生——否则 SD 卡掉线/改目录后，缓存明明还在磁盘上却被判为未缓存，
  /// 白白重新下载一遍。
  bool isCached(String cacheKey) {
    final stored = cachePathOfKey(cacheKey) ?? cachePathForKey(cacheKey);
    return File(stored).existsSync();
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
  Future<void> cacheCommit(
      String cacheKey, String tmpFilePath, int size) async {
    final dst = cachePathForKey(cacheKey);
    if (File(dst).existsSync()) File(dst).deleteSync();
    _moveFile(tmpFilePath, dst);
    final now = DateTime.now().toIso8601String();
    return _writer!.exec(
        'INSERT INTO cache(cache_key, path, size, cached_at, last_accessed_at) '
        'VALUES(?,?,?,?,?) ON CONFLICT(cache_key) DO UPDATE SET size=excluded.size',
        [cacheKey, dst, size, now, now]);
  }

  /// 移动文件，跨文件系统时回退到「复制 + 删除」。
  ///
  /// [File.renameSync] 在跨设备（EXDEV）时直接抛错——不同分区/不同挂载点之间
  /// 的 rename 是 POSIX 就不支持的（Linux EXDEV），不是「偶发失败」。自定义缓存
  /// 目录选到 SD 卡 / 外置存储时，临时文件与目标天然不同盘，必须走复制。
  static void _moveFile(String srcPath, String dstPath) {
    final src = File(srcPath);
    try {
      src.renameSync(dstPath);
      return;
    } on FileSystemException catch (e) {
      // 仅跨文件系统才回退；权限/占用等其它错误照旧抛出，别把真问题糊过去。
      if (e.osError?.errorCode != _exdev) rethrow;
    }
    final dst = File(dstPath);
    final tmpDst = File('$dstPath.moving');
    src.copySync(tmpDst.path);
    // rename 在同目录内一定成功；用它替换目标，保证不出现「半个文件」。
    if (dst.existsSync()) dst.deleteSync();
    tmpDst.renameSync(dstPath);
    src.deleteSync();
  }

  static const int _exdev = 18; // POSIX EXDEV（Linux）

  String? cachedPath(String cacheKey) {
    final stored = cachePathOfKey(cacheKey) ?? cachePathForKey(cacheKey);
    return File(stored).existsSync() ? stored : null;
  }

  /// 迁移缓存目录：建新目录（含可写校验）→ 逐个移动 .dat 并更新 path 列 →
  /// 切换设置。返回迁移文件数；失败抛异常（调用方 toast），可重试继续。
  Future<int> migrateCacheDir(String newDir, {String? uri}) async {
    final target = Directory(newDir);
    target.createSync(recursive: true);
    final probe = File(p.join(target.path, '.writetest'));
    probe.writeAsStringSync('ok');
    probe.deleteSync();
    final oldDir = cacheDir;
    final same = p.normalize(oldDir) == p.normalize(target.path);
    var moved = 0;
    if (!same) {
      for (final r in listCache()) {
        // 源用行里记的路径（权威），目标才是新目录。
        final src = File(r.path);
        if (!src.existsSync()) continue;
        final dstPath = p.join(target.path, '${r.cacheKey}.dat');
        _moveFile(src.path, dstPath);
        await _writer!.exec(
            'UPDATE cache SET path=? WHERE cache_key=?', [dstPath, r.cacheKey]);
        moved++;
      }
    }
    settingsSet(kCacheDirCustom, target.path);
    settingsSet(kCacheDirUri, uri ?? '');
    _cacheDirFallback = false;
    return moved;
  }

  /// 播放/访问缓存时刷新最后访问时间（LRU 依据，fire-and-forget 落库）。
  void touchCache(String cacheKey) {
    _writer!.execFire('UPDATE cache SET last_accessed_at=? WHERE cache_key=?',
        [DateTime.now().toIso8601String(), cacheKey]);
  }

  /// 全部缓存行（供 LRU 淘汰与统计）。
  List<CachedRow> listCache() {
    final rs = _db!.select(
        'SELECT cache_key, path, size, cached_at, last_accessed_at FROM cache');
    return rs
        .map((r) => CachedRow(
              cacheKey: r['cache_key'] as String,
              path: r['path'] as String,
              size: r['size'] as int,
              cachedAt: r['cached_at'] as String?,
              lastAccessedAt: r['last_accessed_at'] as String?,
            ))
        .toList();
  }

  /// 已登记缓存的权威路径（以库里的 path 列为准）。
  ///
  /// 派生路径 [cachePathForKey] 只在「设置里的缓存目录 == 写库时的目录」时才对。
  /// 用户在设置里改目录、SD 卡掉线导致 [\_cacheDir] 回退、或历史遗留数据，都
  /// 会让两者分叉——此时按派生路径删文件会「文件没删到、行却没了」，
  /// 真实文件留在磁盘上成了永远看不到的孤儿，白占空间。
  String? cachePathOfKey(String cacheKey) {
    final rs =
        _db!.select('SELECT path FROM cache WHERE cache_key=?', [cacheKey]);
    if (rs.isEmpty) return null;
    final v = rs.first['path'];
    return v is String && v.isNotEmpty ? v : null;
  }

  Future<void> deleteCache(String cacheKey) async {
    // 先按库里记的路径删真实文件；没有登记行才退回派生路径。
    final stored = cachePathOfKey(cacheKey) ?? cachePathForKey(cacheKey);
    final f = File(stored);
    if (f.existsSync()) {
      try {
        f.deleteSync();
      } on FileSystemException {
        // 删不掉（占用/权限）就别把登记行抹掉——那样文件还在、库却查不到，
        // 彻底变成看不见的孤儿。下次用户重试仍能看到这条缓存。
        rethrow;
      }
    }
    return _writer!.exec('DELETE FROM cache WHERE cache_key=?', [cacheKey]);
  }

  // ---------- play_meta（阶段 2：权重 / 收藏，stage2.md §1.1） ----------

  /// 读 play_meta（纯读；历史 ENCODE 旧行迁移见 open() 的 migrateMetaRefs）。
  PlayMetaRow playMetaOf(String sourceKey, String songRef) {
    final rs = _db!.select(
        'SELECT source_key, song_ref, like_streak, dislike_streak, factor, frozen, is_favorite, song_json, play_sec '
        'FROM play_meta WHERE source_key=? AND song_ref=?',
        [sourceKey, songRef]);
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

  /// 批量读 factor（纯读）：一次查询拿回 [refs] 内已记录歌曲的权重，未命中不放入。
  /// 返回 map<songRef, factor>；`refs` 过大会超 SQLITE_MAX_VARIABLE_NUMBER，
  /// 因此按 500 分片多次查询（播放队列可达数千首，逐首查是主连接 n 次同步 I/O）。
  /// 批量读整行 play_meta（纯读）：与 [playFactorsOf] 同款分片 IN 查询，
  /// 供列表首帧后整表预热 SongWeightStore 行元数据缓存——替代首进歌单页时
  /// 「整表逐行 metaOf = 数千条同步 SELECT 挤在同一帧」这一卡顿源。
  Map<String, PlayMetaRow> playMetasOf(String sourceKey, Iterable<String> refs) {
    final refsList = refs.toSet().toList();
    if (refsList.isEmpty) return const {};
    final result = <String, PlayMetaRow>{};
    const chunkSize = 500;
    for (var start = 0; start < refsList.length; start += chunkSize) {
      final end = min(start + chunkSize, refsList.length);
      final chunk = refsList.sublist(start, end);
      final placeholders = List.filled(chunk.length, '?').join(',');
      final rs = _db!.select(
          'SELECT source_key, song_ref, like_streak, dislike_streak, factor, frozen, is_favorite, song_json, play_sec '
          'FROM play_meta WHERE source_key=? AND song_ref IN ($placeholders)',
          [sourceKey, ...chunk]);
      for (final r in rs) {
        result[r['song_ref'] as String] = PlayMetaRow(
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
    }
    return result;
  }

  Map<String, double> playFactorsOf(String sourceKey, Iterable<String> refs) {
    final refsList = refs.toSet().toList();
    if (refsList.isEmpty) return const {};
    final result = <String, double>{};
    const chunkSize = 500;
    for (var start = 0; start < refsList.length; start += chunkSize) {
      final end = min(start + chunkSize, refsList.length);
      final chunk = refsList.sublist(start, end);
      final placeholders = List.filled(chunk.length, '?').join(',');
      final rs = _db!.select(
          'SELECT song_ref, factor FROM play_meta '
          'WHERE source_key=? AND song_ref IN ($placeholders)',
          [sourceKey, ...chunk]);
      for (final r in rs) {
        result[r['song_ref'] as String] = (r['factor'] as num).toDouble();
      }
    }
    return result;
  }

  /// 批量读抽样权重行（纯读）：`factor` + `frozen` 两列，与 [playFactorsOf] 同款
  /// 分片 IN 查询。加权抽样需要锁定态（「不喜欢」）来按固定最低权重计权，而整行
  /// [playMetasOf] 会带 `song_json` 大字段，队列每次推进都读不划算。
  Map<String, ({double factor, bool frozen})> playWeightRowsOf(
      String sourceKey, Iterable<String> refs) {
    final refsList = refs.toSet().toList();
    if (refsList.isEmpty) return const {};
    final result = <String, ({double factor, bool frozen})>{};
    const chunkSize = 500;
    for (var start = 0; start < refsList.length; start += chunkSize) {
      final end = min(start + chunkSize, refsList.length);
      final chunk = refsList.sublist(start, end);
      final placeholders = List.filled(chunk.length, '?').join(',');
      final rs = _db!.select(
          'SELECT song_ref, factor, frozen FROM play_meta '
          'WHERE source_key=? AND song_ref IN ($placeholders)',
          [sourceKey, ...chunk]);
      for (final r in rs) {
        result[r['song_ref'] as String] = (
          factor: (r['factor'] as num).toDouble(),
          frozen: (r['frozen'] as int) == 1,
        );
      }
    }
    return result;
  }

  /// 累计播放时长（秒）加法：`play_sec += seconds`（写连接内累加，见 db_writer）。
  Future<void> addPlaySec(String sourceKey, String songRef, int seconds) {
    return _writer!.op<void>('addPlaySec', {
      'sourceKey': sourceKey,
      'songRef': songRef,
      'seconds': seconds,
    });
  }

  /// 批量读 play_sec（纯读）：与 [playFactorsOf] 同款分片 IN 查询，
  /// 供「播放时长/播放次数」排序一次拿全，替代逐首同步查库。
  Map<String, int> playSecsOf(String sourceKey, Iterable<String> refs) {
    final refsList = refs.toSet().toList();
    if (refsList.isEmpty) return const {};
    final result = <String, int>{};
    const chunkSize = 500;
    for (var start = 0; start < refsList.length; start += chunkSize) {
      final end = min(start + chunkSize, refsList.length);
      final chunk = refsList.sublist(start, end);
      final placeholders = List.filled(chunk.length, '?').join(',');
      final rs = _db!.select(
          'SELECT song_ref, play_sec FROM play_meta '
          'WHERE source_key=? AND song_ref IN ($placeholders)',
          [sourceKey, ...chunk]);
      for (final r in rs) {
        final v = r['play_sec'];
        if (v is int) result[r['song_ref'] as String] = v;
      }
    }
    return result;
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
    return _writer!
        .op<int>('createPlaylist', {'name': name, 'description': description});
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
    return rs
        .map((r) => PlaylistRow(
              id: r['id'] as int,
              name: r['name'] as String,
              description: r['description'] as String?,
              createdAt: r['created_at'] as String,
              clientUuid: r['client_uuid'] as String?,
            ))
        .toList();
  }

  /// 歌单内歌曲匹配：返回含匹配歌曲（标题/歌手/专辑，忽略大小写）的歌单 id 集合。
  /// 单条 SQL 完成，供歌单页搜索（搜索内容是歌单中的具体歌曲）。
  Set<int> playlistIdsMatchingSong(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const {};
    final escaped =
        q.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_');
    final like = '%$escaped%';
    final rs = _db!.select(
        "SELECT DISTINCT playlist_id FROM playlist_items "
        r"WHERE lower(title) LIKE ? ESCAPE '\' "
        r"OR lower(IFNULL(artist,'')) LIKE ? ESCAPE '\' "
        r"OR lower(IFNULL(album,'')) LIKE ? ESCAPE '\'",
        [like, like, like]);
    return {for (final r in rs) r['playlist_id'] as int};
  }

  Future<void> addPlaylistItem(int playlistId,
      {required String sourceKey,
      required String songRef,
      required String title,
      String? artist,
      String? album,
      String? coverPath,
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

  /// 歌单条目计数（E）：`PlaylistsProvider.refresh` 原先 `itemsOf(...).length`
  /// 全行物化只为计数，大歌单在 UI 线程放大；计数走 `COUNT(*)`。
  int playlistItemCount(int playlistId) {
    final rs = _db!.select(
        'SELECT COUNT(*) AS n FROM playlist_items WHERE playlist_id=?',
        [playlistId]);
    return (rs.first['n'] as int?) ?? 0;
  }

  List<PlaylistItemRow> playlistItems(int playlistId) {
    final rs = _db!.select('''
      SELECT id, playlist_id, source_key, song_ref, title, artist, album,
             cover_path, sort_order, source
      FROM playlist_items WHERE playlist_id=?
      ORDER BY sort_order, id
    ''', [playlistId]);
    return rs
        .map((r) => PlaylistItemRow(
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
            ))
        .toList();
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

  // ---------- 多设备同步 outbox（阶段5，DEVELOPER.md「播放算法与同步协议」） ----------

  /// 事件 uuid（服务端 event_uuid 幂等键；36 列内唯一即可，不需标准 UUID 形态）。
  static String newEventUuid() {
    final r = Random.secure();
    final tail = List.generate(
            3, (_) => r.nextInt(0xffffffff).toRadixString(16).padLeft(8, '0'))
        .join();
    return '${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}-${tail.substring(0, 12)}';
  }

  /// 时钟偏移（服务端回包 `server_time` 校准，见 [setClockSkew]）：
  /// 出队时间戳按此修正，治设备墙钟偏移导致的服务端 LWW 误判。
  /// 内存态（重启归零，下次同步成功后重建；旧服务端无该字段时恒为零）。
  Duration _clockSkew = Duration.zero;

  /// 上次入队时间戳（单调 guard：修正值回跳时沿用上次 +1ms，
  /// 防 skew 抖动导致自家事件乱序）。
  DateTime? _lastOccurredAt;

  /// 更新时钟偏移（SyncEngine 每次 push/pull 成功后调用）。
  void setClockSkew(Duration skew) {
    _clockSkew = skew;
  }

  /// 当前时钟偏移（诊断日志/测试用）。
  Duration get clockSkew => _clockSkew;

  /// 当前时钟偏移（测试用）。
  Duration get clockSkewForTest => _clockSkew;

  // v2 断点操作时钟：wallMillis-counter。设备维度由服务端用 auth clientId
  // 补齐（同一 wall+counter 时再按设备全序），客户端无需异步读设备号。
  int _hlcWallMs = 0;
  int _hlcCounter = 0;

  /// 生成一个本机单调递增的 HLC 操作时钟（`wall-counter`）。
  ///
  /// 注意：这不是「事件时间戳」；它只用于「最后一次真实播放操作」的仲裁。
  /// 进程重启后 counter 归零，若墙钟回拨，服务端仍会用 head_rev 拒绝更旧
  /// 的 head，历史合并不受影响。
  String nextBreakpointClock() {
    final now = DateTime.now().add(_clockSkew).millisecondsSinceEpoch;
    if (now > _hlcWallMs) {
      _hlcWallMs = now;
      _hlcCounter = 0;
    } else {
      _hlcCounter++;
    }
    return '$_hlcWallMs-$_hlcCounter';
  }

  /// 本地变更入队（uuid 同步生成，落库进写隔离后返回）。
  /// `occurred_at` 按时钟偏移修正后保证本机单调递增。
  /// 返回 event_uuid。
  Future<String> enqueueOutbox(
      String type, Map<String, dynamic> payload) async {
    final uuid = newEventUuid();
    var ts = DateTime.now().add(_clockSkew);
    final last = _lastOccurredAt;
    // bumped=单调 guard 生效：修正后仍不晚于上次入队（skew 回跳/同毫秒），
    // 被顶到上次 +1ms——排查「旧数据覆盖服务端新数据」时据此看时间戳来源。
    final bumped = last != null && !ts.isAfter(last);
    if (bumped) {
      ts = last.add(const Duration(milliseconds: 1));
    }
    _lastOccurredAt = ts;
    final now = ts.toIso8601String();
    perfLog('outbox.enqueue',
        'type=$type uuid=$uuid occurred=$now skew=${_clockSkew.inMilliseconds}ms${bumped ? ' bumped' : ''}');
    await _writer!.exec(
        'INSERT INTO weight_outbox(event_uuid, type, payload, occurred_at, acked, created_at) '
        'VALUES(?,?,?,?,0,?)',
        [uuid, type, jsonEncode(payload), now, now]);
    return uuid;
  }

  /// 未确认事件（SyncEngine 上推用，按入队序）。
  /// 读取与 payload 解码都在写隔离完成（同步后台化：UI isolate 不做 SQL/JSON）。
  Future<List<OutboxRow>> pendingOutbox({int limit = 500}) async {
    final rows = await _writer!.op<List<dynamic>>('pendingOutbox', {
      'limit': limit,
    });
    return [
      for (final r in rows)
        if (r is Map)
          OutboxRow(
            eventUuid: r['eventUuid'] as String,
            type: r['type'] as String,
            payload: (r['payload'] as Map).cast<String, dynamic>(),
            occurredAt: r['occurredAt'] as String,
          )
    ];
  }

  /// 未确认事件计数（SyncEngine 2s tick；写隔离内 COUNT，走 acked 索引）。
  Future<int> pendingOutboxCount() async {
    return _writer!.op<int>('pendingOutboxCount', const {});
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
    final rs =
        _db!.select('SELECT client_uuid FROM playlists WHERE id=?', [id]);
    if (rs.isEmpty) return null;
    return rs.first['client_uuid'] as String?;
  }

  int? playlistIdOfUuid(String uuid) {
    final rs =
        _db!.select('SELECT id FROM playlists WHERE client_uuid=?', [uuid]);
    if (rs.isEmpty) return null;
    return rs.first['id'] as int?;
  }

  /// 歌单名（uuid → name）：播控中心历史歌单显示名（avQueueName）用，
  /// 查不到返回 null（调用方兜底「正在播放」）。
  String? playlistNameOfUuid(String uuid) {
    final rs =
        _db!.select('SELECT name FROM playlists WHERE client_uuid=?', [uuid]);
    if (rs.isEmpty) return null;
    return rs.first['name'] as String?;
  }

  /// pull 歌单快照落库（deleted=true 则本地硬删）。
  /// 条目只替换服务端歌曲行（source_key='server'）：本地直连歌曲行保留，
  /// 由本机 push 事件与服务端收敛（直连歌曲同样参与同步，见 DEVELOPER.md「播放算法与同步协议」）。
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

  /// pull 歌单快照批·服务端原始 JSON 直通写隔离（条目解析/落库同处完成，
  /// UI isolate 只 await；跨页去重由 SyncEngine 完成）。
  Future<void> applyPlaylistSnapshots(List<Map<String, dynamic>> snapshots) {
    if (snapshots.isEmpty) return Future.value();
    return _writer!.opBatch('applyPlaylistSnapshots', snapshots);
  }

  /// 元数据读取情况汇总（侧边栏「歌曲信息」页，改进 B6-4）。
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
        'total',
        'missing',
        'meta_read',
        'artist',
        'album',
        'album_artist',
        'genre',
        'track_no',
        'year',
        'duration',
        'cover',
        'lyrics',
        'format',
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

  /// 播放数据总览（歌曲信息页用）：累计时长/次数 + 次数与时长分布。
  ///
  /// 口径与 [playCountOf] 一致：次数 = play_sec / 歌曲时长（未知时长按 0 次计，
  /// 归入「未播放/0 次」档）。只统计有效行（missing=0），play_meta 缺行按 0 秒。
  PlayOverview playOverview() {
    final rs = _db!.select('''
      SELECT COALESCE(p.play_sec,0) AS play_sec, i.duration AS duration
      FROM idx_songs i
      LEFT JOIN play_meta p ON p.source_key=i.source_key AND p.song_ref=i.ref
      WHERE i.missing=0
    ''');
    var withPlay = 0;
    var totalSec = 0;
    var totalCount = 0.0;
    var c0 = 0, cLt1 = 0, c1to5 = 0, cGt5 = 0;
    var s0 = 0, sLt = 0, sMid = 0, sGt = 0;
    for (final r in rs) {
      final sec = (r['play_sec'] as num?)?.toInt() ?? 0;
      final dur = (r['duration'] as num?)?.toInt();
      totalSec += sec;
      if (sec > 0) withPlay++;
      if (sec <= 0) {
        s0++;
      } else if (sec < 600) {
        sLt++;
      } else if (sec <= 3600) {
        sMid++;
      } else {
        sGt++;
      }
      double c = 0;
      if (sec > 0 && dur != null && dur > 0) c = sec / dur;
      totalCount += c;
      if (c <= 0) {
        c0++;
      } else if (c < 1) {
        cLt1++;
      } else if (c <= 5) {
        c1to5++;
      } else {
        cGt5++;
      }
    }
    return PlayOverview(
      total: rs.length,
      withPlay: withPlay,
      totalSec: totalSec,
      totalCount: totalCount,
      countZero: c0,
      countLt1: cLt1,
      count1to5: c1to5,
      countGt5: cGt5,
      secZero: s0,
      secLt10m: sLt,
      sec10mTo1h: sMid,
      secGt1h: sGt,
    );
  }

  /// 播放数据明细：全部有效歌曲的播放时长（play_sec 缺行按 0）。
  /// 排序在 UI 侧完成（歌曲名/歌手/源/次数/时长）。
  List<PlayDetailRow> playDetailRows() => playDetailRowsOf(_db!);

  /// 播放数据明细·后台 isolate 读（详情页入场不冻帧，见
  /// [librarySnapshotInBackground] 同款口径）。
  Future<List<PlayDetailRow>> playDetailRowsInBackground() {
    final path = _dbPath;
    if (path == null) return Future.value(const <PlayDetailRow>[]);
    return runOffThread(() {
      final db = openIsolateDatabase(path);
      try {
        return playDetailRowsOf(db);
      } finally {
        db.dispose();
      }
    });
  }

  /// 元数据明细：全部有效歌曲各维度原始值（与 [metaStats] 同口径）。
  /// 缺失判定：文本列 null/'' 即缺；数字列 null 即缺；封面 path 非空即有；
  /// 歌词 song_lyrics 有非空 content 即有；码率可估算 = size>0 && duration>0。
  List<MetaDetailRow> metaDetailRows() => metaDetailRowsOf(_db!);

  /// 元数据明细·后台 isolate 读（详情页入场不冻帧）。
  Future<List<MetaDetailRow>> metaDetailRowsInBackground() {
    final path = _dbPath;
    if (path == null) return Future.value(const <MetaDetailRow>[]);
    return runOffThread(() {
      final db = openIsolateDatabase(path);
      try {
        return metaDetailRowsOf(db);
      } finally {
        db.dispose();
      }
    });
  }

  /// pull 歌曲权重快照落 play_meta：先写 ('server', ref) 行（服务端歌曲），
  /// 再按快照 [source] 协议匹配本地直连行（同 ref 含 WebDAV 编码变体 + 同协议），
  /// 各写各的源 key（运行时按源 key 读权重，见 playMetaOf）。
  /// 直连歌曲在连着服务器时同样参与同步（DEVELOPER.md「播放算法与同步协议」 影子行）。
  ///
  /// [playSec] 累计播放时长（秒）取 `max(本地, 服务端)`：它是单调累计量，
  /// 被别的设备的旧值覆盖会丢真实数据（服务端按行级 LWW 收敛，值可能更小）。
  Future<void> applySongSnapshot({
    required String songRef,
    String? source,
    String? sourceId,
    required int likeStreak,
    required int dislikeStreak,
    required double factor,
    required bool frozen,
    required bool favorite,
    int? playSec,
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
      'playSec': playSec,
    });
  }

  /// 批量 pull 歌曲权重快照：单事务整批落 play_meta（SyncEngine 每页一次调用，
  /// 避免逐行事务 fsync）。
  Future<void> applySongSnapshots(List<Map<String, dynamic>> snapshots) {
    if (snapshots.isEmpty) return Future.value();
    return _writer!.opBatch('applySongSnapshots', snapshots);
  }

  /// 批量 pull 歌曲权重快照·服务端原始形态：字段映射与落库都在写隔离内
  /// （pull 主路径；UI isolate 不做逐条映射与 JSON 处理）。
  Future<void> applySongSnapshotsRaw(List<Map<String, dynamic>> snapshots) {
    if (snapshots.isEmpty) return Future.value();
    return _writer!.opBatch('applySongSnapshotsRaw', snapshots);
  }

  /// 单条 pull 歌曲权重快照·服务端原始形态（push correction 用）。
  Future<void> applySongSnapshotRaw(Map<String, dynamic> snapshot) {
    return _writer!.op<void>('applySongSnapshotRaw', snapshot);
  }

  /// pull 断点写入镜像表（不碰运行时 play_state，见 SyncEngine）。
  /// [lastEventAt] = 服务端「最后操作时间」（命中事件 occurred_at）；比较时钟
  /// 取 `lastEventAt ?? updatedAt`（见 BreakpointMirrorRow.compareClock）。
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
    String? lastEventAt,
    int headRev = 0,
    int historyRev = 0,
    String? headClock,
    String? headOpId,
    String? headSession,
    bool headPlaying = false,
    String? headUpdatedAt,
  }) {
    return _writer!.exec(
        'INSERT INTO breakpoint_mirror(playlist_uuid, song_id, source_id, source, source_ref, '
        'position_ms, deep_list_json, updated_at, device_id, last_event_at, '
        'head_rev, history_rev, head_clock, head_op_id, head_session, head_playing, head_updated_at) '
        'VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) '
        'ON CONFLICT(playlist_uuid) DO UPDATE SET '
        'song_id=CASE WHEN excluded.head_rev >= breakpoint_mirror.head_rev THEN excluded.song_id ELSE breakpoint_mirror.song_id END, '
        'source_id=CASE WHEN excluded.head_rev >= breakpoint_mirror.head_rev THEN excluded.source_id ELSE breakpoint_mirror.source_id END, '
        'source=CASE WHEN excluded.head_rev >= breakpoint_mirror.head_rev THEN excluded.source ELSE breakpoint_mirror.source END, '
        'source_ref=CASE WHEN excluded.head_rev >= breakpoint_mirror.head_rev THEN excluded.source_ref ELSE breakpoint_mirror.source_ref END, '
        'position_ms=CASE WHEN excluded.head_rev >= breakpoint_mirror.head_rev THEN excluded.position_ms ELSE breakpoint_mirror.position_ms END, '
        'deep_list_json=CASE WHEN excluded.deep_list_json IS NOT NULL AND excluded.history_rev >= breakpoint_mirror.history_rev THEN excluded.deep_list_json ELSE breakpoint_mirror.deep_list_json END, '
        'updated_at=CASE WHEN excluded.head_rev >= breakpoint_mirror.head_rev THEN excluded.updated_at ELSE breakpoint_mirror.updated_at END, '
        'device_id=CASE WHEN excluded.head_rev >= breakpoint_mirror.head_rev THEN excluded.device_id ELSE breakpoint_mirror.device_id END, '
        'last_event_at=CASE WHEN excluded.head_rev >= breakpoint_mirror.head_rev THEN excluded.last_event_at ELSE breakpoint_mirror.last_event_at END, '
        'head_rev=MAX(breakpoint_mirror.head_rev, excluded.head_rev), '
        'history_rev=MAX(breakpoint_mirror.history_rev, CASE WHEN excluded.deep_list_json IS NOT NULL THEN excluded.history_rev ELSE 0 END), '
        'head_clock=CASE WHEN excluded.head_rev >= breakpoint_mirror.head_rev THEN excluded.head_clock ELSE breakpoint_mirror.head_clock END, '
        'head_op_id=CASE WHEN excluded.head_rev >= breakpoint_mirror.head_rev THEN excluded.head_op_id ELSE breakpoint_mirror.head_op_id END, '
        'head_session=CASE WHEN excluded.head_rev >= breakpoint_mirror.head_rev THEN excluded.head_session ELSE breakpoint_mirror.head_session END, '
        'head_playing=CASE WHEN excluded.head_rev >= breakpoint_mirror.head_rev THEN excluded.head_playing ELSE breakpoint_mirror.head_playing END, '
        'head_updated_at=CASE WHEN excluded.head_rev >= breakpoint_mirror.head_rev THEN excluded.head_updated_at ELSE breakpoint_mirror.head_updated_at END',
        [
          playlistUuid,
          songId,
          sourceId,
          source,
          sourceRef,
          positionMs,
          deepListJson,
          updatedAt,
          deviceId,
          lastEventAt,
          headRev,
          historyRev,
          headClock,
          headOpId,
          headSession,
          headPlaying ? 1 : 0,
          headUpdatedAt,
        ]);
  }

  /// pull 断点镜像·服务端原始形态直通：playlist 存在性判定（本地已删则清镜像）
  /// 与 upsert 都在写隔离内完成（原先 playlistIdOfUuid 是 UI 线程同步查询）。
  /// [force]：push 的 merged 回执即使时钟不新也要落库（其中含对端分支）。
  Future<void> applyPlaystateMirror(Map<String, dynamic> snapshot,
      {bool force = false}) {
    return _writer!.op<void>('applyPlaystateMirror', {
      ...snapshot,
      if (force) '_force': true,
    });
  }

  BreakpointMirrorRow? breakpointMirrorOf(String playlistUuid) {
    final rs = _db!.select(
        'SELECT playlist_uuid, song_id, source_id, source, source_ref, position_ms, '
        'deep_list_json, updated_at, device_id, last_event_at, head_rev, history_rev, '
        'head_clock, head_op_id, head_session, head_playing, head_updated_at '
        'FROM breakpoint_mirror WHERE playlist_uuid=?',
        [playlistUuid]);
    if (rs.isEmpty) return null;
    return BreakpointMirrorRow.fromMap(rs.first);
  }

  /// 本机已采用且与服务端确认过的深层列表（身份 JSON）；null=从未确认。
  String? breakpointBaseDeepList(String playlistUuid) {
    final rs = _db!.select(
        'SELECT deep_list_json FROM breakpoint_sync_base WHERE playlist_uuid=?',
        [playlistUuid]);
    return rs.isEmpty ? null : rs.first['deep_list_json'] as String?;
  }

  /// [historyRev] 非空时同步记录该 base 对应的服务端历史版本；普通镜像
  /// 拉取/只落镜像的路径不得推进它（base 必须与本机已采用列表对齐）。
  Future<void> setBreakpointBaseDeepList(
      String playlistUuid, String deepListJson, {int? historyRev}) {
    return _writer!.exec(
        'INSERT INTO breakpoint_sync_base(playlist_uuid, deep_list_json, history_rev, updated_at) '
        'VALUES(?,?,?,?) ON CONFLICT(playlist_uuid) DO UPDATE SET '
        'deep_list_json=excluded.deep_list_json, '
        'history_rev=CASE WHEN ? IS NULL THEN breakpoint_sync_base.history_rev '
        'ELSE excluded.history_rev END, '
        'updated_at=excluded.updated_at',
        [
          playlistUuid,
          deepListJson,
          historyRev ?? 0,
          DateTime.now().toIso8601String(),
          historyRev,
        ]);
  }

  int breakpointBaseHistoryRev(String playlistUuid) {
    final rs = _db!.select(
        'SELECT history_rev FROM breakpoint_sync_base WHERE playlist_uuid=?',
        [playlistUuid]);
    return rs.isEmpty ? 0 : (rs.first['history_rev'] as int? ?? 0);
  }

  // ---------- 断点协议 v2 同步状态 ----------

  BreakpointSyncState? breakpointSyncStateOf(String playlistUuid) {
    final rs = _db!.select(
        'SELECT playlist_uuid, applied_head_rev, applied_history_rev, '
        'pending_head_op_id, session_id, server_epoch '
        'FROM breakpoint_sync_state WHERE playlist_uuid=?',
        [playlistUuid]);
    if (rs.isEmpty) return null;
    final r = rs.first;
    return BreakpointSyncState(
      playlistUuid: r['playlist_uuid'] as String,
      appliedHeadRev: r['applied_head_rev'] as int? ?? 0,
      appliedHistoryRev: r['applied_history_rev'] as int? ?? 0,
      pendingHeadOpId: r['pending_head_op_id'] as String?,
      sessionId: r['session_id'] as String?,
      serverEpoch: r['server_epoch'] as String?,
    );
  }

  Future<void> saveBreakpointSyncState({
    required String playlistUuid,
    int? appliedHeadRev,
    int? appliedHistoryRev,
    String? pendingHeadOpId,
    bool clearPending = false,
    String? sessionId,
    String? serverEpoch,
  }) {
    final now = DateTime.now().toIso8601String();
    return _writer!.exec(
        'INSERT INTO breakpoint_sync_state(playlist_uuid, applied_head_rev, '
        'applied_history_rev, pending_head_op_id, session_id, server_epoch, updated_at) '
        'VALUES(?,?,?,?,?,?,?) ON CONFLICT(playlist_uuid) DO UPDATE SET '
        'applied_head_rev=MAX(breakpoint_sync_state.applied_head_rev, excluded.applied_head_rev), '
        'applied_history_rev=MAX(breakpoint_sync_state.applied_history_rev, excluded.applied_history_rev), '
        'pending_head_op_id=CASE WHEN ? THEN NULL ELSE '
        'COALESCE(excluded.pending_head_op_id, breakpoint_sync_state.pending_head_op_id) END, '
        'session_id=COALESCE(excluded.session_id, breakpoint_sync_state.session_id), '
        'server_epoch=COALESCE(excluded.server_epoch, breakpoint_sync_state.server_epoch), '
        'updated_at=excluded.updated_at',
        [
          playlistUuid,
          appliedHeadRev ?? 0,
          appliedHistoryRev ?? 0,
          pendingHeadOpId,
          sessionId,
          serverEpoch,
          now,
          clearPending ? 1 : 0,
        ]);
  }

  /// 任一歌单已记录的服务端代次（用于启动时先收到网络响应、后恢复本机
  /// 断点的顺序下仍能识别 epoch 变化）。
  String? breakpointStoredServerEpoch() {
    final rs = _db!.select(
        'SELECT server_epoch FROM breakpoint_sync_state '
        'WHERE server_epoch IS NOT NULL AND server_epoch != \'\' LIMIT 1');
    if (rs.isEmpty) return null;
    final v = rs.first['server_epoch'] as String?;
    return (v == null || v.isEmpty) ? null : v;
  }

  Future<void> resetBreakpointSyncStateForEpoch(
      String playlistUuid, String serverEpoch) {
    return _writer!.exec(
        'INSERT INTO breakpoint_sync_state(playlist_uuid, applied_head_rev, '
        'applied_history_rev, pending_head_op_id, session_id, server_epoch, updated_at) '
        'VALUES(?,0,0,NULL,NULL,?,?) ON CONFLICT(playlist_uuid) DO UPDATE SET '
        'applied_head_rev=0, applied_history_rev=0, pending_head_op_id=NULL, '
        'server_epoch=excluded.server_epoch, updated_at=excluded.updated_at',
        [playlistUuid, serverEpoch, DateTime.now().toIso8601String()]);
  }

  /// 服务端 epoch 变化（DB 重建/迁移）：本地 revision 全部作废重来。
  /// 保留断点镜像的当前值（本机续播仍可用），只清版本号与 pending。
  Future<void> resetBreakpointSyncRevs(String serverEpoch) async {
    await _writer!.exec(
        'UPDATE breakpoint_mirror SET head_rev=0, history_rev=0');
    await _writer!.exec('DELETE FROM breakpoint_sync_state');
  }

  Future<void> deleteBreakpointMirror(String playlistUuid) {
    return _writer!.exec(
        'DELETE FROM breakpoint_mirror WHERE playlist_uuid=?', [playlistUuid]);
  }

  Future<void> deleteBreakpointSyncBase(String playlistUuid) {
    return _writer!.exec(
        'DELETE FROM breakpoint_sync_base WHERE playlist_uuid=?',
        [playlistUuid]);
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
    return _writer!
        .exec('DELETE FROM deep_lists WHERE playlist_uuid=?', [playlistUuid]);
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
        'ON CONFLICT(key) DO UPDATE SET value=excluded.value',
        [key, value]);
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
      {String? playlistUuid, String? anchorKey, String? sessionId}) {
    return _writer!.exec(
        'INSERT INTO play_state(id, queue_json, idx, position_ms, updated_at, playlist_uuid, anchor_key, session_id) '
        'VALUES(1,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET '
        'queue_json=excluded.queue_json, idx=excluded.idx, '
        'position_ms=excluded.position_ms, updated_at=excluded.updated_at, '
        'playlist_uuid=excluded.playlist_uuid, anchor_key=excluded.anchor_key, '
        'session_id=COALESCE(excluded.session_id, play_state.session_id)',
        [
          queueJson,
          idx,
          positionMs,
          DateTime.now().toIso8601String(),
          playlistUuid,
          anchorKey,
          sessionId,
        ]);
  }

  PlayStateRow? getPlayState() {
    final rs = _db!.select(
        'SELECT queue_json, idx, position_ms, updated_at, playlist_uuid, anchor_key, session_id FROM play_state WHERE id=1');
    if (rs.isEmpty) return null;
    final r = rs.first;
    return PlayStateRow(
      queueJson: r['queue_json'] as String,
      idx: r['idx'] as int,
      positionMs: r['position_ms'] as int,
      updatedAt: r['updated_at'] as String,
      playlistUuid: r['playlist_uuid'] as String?,
      anchorKey: r['anchor_key'] as String?,
      sessionId: r['session_id'] as String?,
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
        'deep_list_json, updated_at, device_id, last_event_at, head_rev, history_rev, '
        'head_clock, head_op_id, head_session, head_playing, head_updated_at '
        'FROM breakpoint_mirror');
    return [for (final r in rs) BreakpointMirrorRow.fromMap(r)];
  }

  Future<void> clearPlayState() {
    return _writer!.exec('DELETE FROM play_state WHERE id=1');
  }

  // ---------- 歌手处理.txt：身份聚合 ----------

  /// 对 idx_songs 校准歌手身份映射（扫描结束 / 元数据回填批 / 用户编辑后触发；
  /// 幂等，写连接单事务）。
  Future<void> reconcileArtists() {
    perfPhase('index.reconcileArtists'); // TEMP-PROBE
    return _writer!.op<void>('artistReconcile', const {});
  }

  /// 待解析工作集：pending 优先，其次按 next_at 退避到的 local/ambiguous。
  List<ArtistWorkItem> artistWorkSet({int limit = 8, int? nowEpochMs}) {
    final rs = _db!.select('''
      SELECT artist_key, canonical_key, display_name, status, error_count, next_at, mbid
      FROM artists
      WHERE status IN ('pending','local','ambiguous') AND next_at <= ?
      ORDER BY CASE WHEN status='pending' THEN 0 WHEN status='local' THEN 1 ELSE 2 END,
               next_at, error_count
      LIMIT ?
    ''', [nowEpochMs ?? DateTime.now().millisecondsSinceEpoch, limit]);
    return [
      for (final r in rs)
        ArtistWorkItem(
          artistKey: r['artist_key'] as String,
          canonicalKey: r['canonical_key'] as String,
          displayName: r['display_name'] as String,
          status: r['status'] as String,
          errorCount: r['error_count'] as int,
          nextAt: r['next_at'] as int,
          mbid: r['mbid'] as String?,
        )
    ];
  }

  /// 最早退避时刻（local/ambiguous 且未来到期的最小 next_at；null=近期无工作）。
  int? minArtistNextAt() {
    final rs = _db!.select(
        "SELECT MIN(next_at) v FROM artists WHERE status IN ('local','ambiguous') AND next_at>0");
    return rs.isEmpty ? null : (rs.first['v'] as int?);
  }

  /// 按 artist_key 读完整身份行（解析服务用）。
  ArtistRow? artistRowByKey(String artistKey) {
    final rs =
        _db!.select('SELECT * FROM artists WHERE artist_key=?', [artistKey]);
    return rs.isEmpty ? null : _rowToArtist(rs.first);
  }

  /// 按归一化键经 artist_canon 桥读身份行。
  ArtistRow? artistRowByCanonical(String canonicalKey) {
    final rs = _db!.select('''
      SELECT a.* FROM artist_canon c JOIN artists a ON a.artist_key=c.artist_key
      WHERE c.canonical_key=?
    ''', [canonicalKey]);
    return rs.isEmpty ? null : _rowToArtist(rs.first);
  }

  /// 按任一名字（primary / sort_name / alias / role）查本地已解析身份。
  ///
  /// 歌手处理.txt 第 3 步的「本地别名表」不需要另建表：别名一直存在
  /// `artists.names` JSON 里（`MbArtistHit.toNames` 写入，带 lang/is_primary），
  /// 缺的只是这一查。命中即直接 resolved、完全不打 MusicBrainz。
  /// 命中多个时优先已绑 mbid 的身份（占位身份也可能同名）。
  ArtistRow? artistRowByAnyName(String name) {
    final rs = _db!.select('''
      SELECT a.* FROM artists a JOIN json_each(a.names) n
        ON json_extract(n.value,'\$.name')=?
      ORDER BY (a.mbid IS NULL), a.updated_at DESC LIMIT 1
    ''', [name]);
    return rs.isEmpty ? null : _rowToArtist(rs.first);
  }

  /// 按 mbid 读身份行（成员递归时把 MB 关系里的 mbid 换成本地身份键）。
  ArtistRow? artistRowByMbid(String mbid) {
    final rs =
        _db!.select('SELECT * FROM artists WHERE mbid=? LIMIT 1', [mbid]);
    return rs.isEmpty ? null : _rowToArtist(rs.first);
  }

  /// 全量替换 [artistKey] 的成员边（解析服务展开社团/角色时调用），
  /// 返回与 [members] 等长的成员身份键列表（未建边处为空串），调用方据此递归下一跳。
  /// 传空列表即「该身份确实无成员」，会清掉旧边。
  Future<List<String>> artistSetMembers(
          {required String artistKey,
          required List<Map<String, dynamic>> members}) =>
      _writer!.op<List<String>>(
          'artistSetMembers', {'parentKey': artistKey, 'members': members});

  /// 只标记 [artistKey] 已展开过关系，不改动任何成员边。
  /// 切勿用 artistSetMembers(members: []) 代替：那是全量替换，会把刚建的边删掉。
  Future<void> artistMarkExpanded(String artistKey) =>
      _writer!.op<void>('artistMarkExpanded', {'artistKey': artistKey});

  /// 已有身份的歌手聚合（identity 模式，歌手页主数据源）。
  ///
  /// 显示集合不是「有歌的身份」而是「**歌手**」：组合/角色沿 [artist_member] 递归
  /// 展开，只显示 type='person' 的末端；整条链一个 Person 都没有（没展开出成员、
  /// MB 无成员数据）时才回落显示该身份本身。歌曲归属反向继承——成员身份自己没有
  /// role='main' 映射，计数与列表都算上其所有祖先身份的歌曲。
  List<Artist> identityArtistGroups(
          {String? query,
          CollectionSort? sort,
          int minDurationSec = 0,
          int minSizeBytes = 0}) =>
      _db == null
          ? const []
          : identityArtistGroupsOf(_db!,
              query: query,
              sort: sort,
              minDurationSec: minDurationSec,
              minSizeBytes: minSizeBytes);

  /// 空串当 null：MB 里「有字段但为空串」和「没这个字段」意思一样。
  static String? _emptyToNull(String? v) {
    if (v == null) return null;
    final t = v.trim();
    return t.isEmpty ? null : t;
  }

  /// 从 [root] 沿成员边广度展开出所有 type='person' 的身份（含 root 自身若是 Person）。
  /// visited 按 artist_key 防环；成员表很小，深度不设限也不会失控。
  /// 实现见顶层 [personsUnder]（后台 isolate 快照共用）。
  List<String> _personsUnder(String root, Map<String, List<String>> children,
          Map<String, String> types) =>
      personsUnder(root, children, types);

  /// 各身份的展示口径统计（歌曲数 + 专辑数）：与 [identitySongs] 完全同源——
  /// 沿成员边向上递归到「自己 + 全部祖先」，统计祖先名下 role='main' 的歌曲。
  /// 成员身份自己没有映射（歌曲只标了组合/角色名），所以它显示的是所属上级那批歌；
  /// 成员同时属于多个上级时按 k 合并去重，不会漏。没有映射的身份不在结果里。
  ///
  /// 歌手页列表与详情页共用这一口径（列表的 songCount/albumCount 来自这里，
  /// 详情页的歌曲列表来自 [identitySongs]），避免两处各写一套计数后漂移。
  ///
  /// 专辑数按全局专辑分组键统计（有名专辑只看 trim 后专辑名，未知专辑才拼接
  /// 歌手），与 [Album.fromSongs] 一致——详情页的专辑分区按同一键分组，数字才对得上。
  /// 实现见顶层 [identityDisplayStatsOf]。
  Map<String, ({int songs, int albums})> identityDisplayStats(
          {int minDurationSec = 0, int minSizeBytes = 0}) =>
      _db == null
          ? const {}
          : identityDisplayStatsOf(_db!,
              minDurationSec: minDurationSec, minSizeBytes: minSizeBytes);

  /// 各身份在歌手页的展示曲目数（详情页给关联行填数字用）。
  /// 语义与 [identitySongs] 完全一致，见 [identityDisplayStats]。
  Map<String, int> identityDisplayCounts(
          {int minDurationSec = 0, int minSizeBytes = 0}) =>
      {
        for (final e in identityDisplayStats(
                minDurationSec: minDurationSec, minSizeBytes: minSizeBytes)
            .entries)
          e.key: e.value.songs,
      };

  /// 已解析**人物**身份的详情（歌手详情页展示组合 / 角色 / 成员）。
  ///
  /// 只对 `type='person'` 的身份返回：组合/角色自身的关系挂在成员树上，弹页不
  /// 渲染它们的详情。三栏的数据来源分开：
  ///
  /// - 组合 / 角色：取 MusicBrainz 原始关系（`artists.groups`），因此**包含本地
  ///   从没展开过的关联**（MB 报了 5 个组合，本地可能只建了 1 个身份行）。另把本地
  ///   成员树里自己的祖先组合、及这些组合的上级组合一并并进来（递归到底）。
  /// - 成员：取本地成员树里同组合的其他人（排除自己），按歌手页的 Person 口径。
  ///
  /// 每一行都尽量带上本地身份键与展示曲目数；带不上的说明本地没这条身份，
  /// 只能展示不能点进去。
  ArtistDetail? artistDetail(String artistKey,
      {int minDurationSec = 0, int minSizeBytes = 0}) {
    final db = _db;
    if (db == null) return null;
    final row = artistRowByKey(artistKey);
    if (row == null || !row.isResolved || row.type != 'person') return null;

    final counts = identityDisplayCounts(
        minDurationSec: minDurationSec, minSizeBytes: minSizeBytes);
    final children = <String, List<String>>{};
    final parents = <String, List<String>>{};
    for (final r
        in db.select('SELECT parent_key, member_key FROM artist_member')) {
      final p = r['parent_key'] as String;
      final m = r['member_key'] as String;
      (children[p] ??= <String>[]).add(m);
      (parents[m] ??= <String>[]).add(p);
    }
    final types = <String, String>{};
    final rows = <String, ArtistRow>{};
    final byMbid = <String, ArtistRow>{};
    for (final r in db.select('SELECT * FROM artists')) {
      final a = _rowToArtist(r);
      rows[a.artistKey] = a;
      types[a.artistKey] = a.type;
      if (a.mbid != null && a.mbid!.isNotEmpty) byMbid[a.mbid!] = a;
    }

    ArtistRef refOf(ArtistRow r, {List<String> rels = const []}) => ArtistRef(
          name: r.displayName,
          mbid: r.mbid,
          type: r.type,
          disambiguation: _emptyToNull(r.disambiguation),
          artistKey: r.artistKey,
          songCount: counts[r.artistKey] ?? 0,
          relations: rels,
        );

    // ---- 组合 / 角色：MB 原始关系 ----
    const bandTypes = {'group', 'orchestra', 'choir'};
    const bandRelTypes = {
      'member of band',
      'former member of band',
      'subgroup',
      'performing orchestra',
      'conductor of',
      'collaboration',
    };
    final bands = <String, ArtistRef>{};
    final roles = <String, ArtistRef>{};
    for (final g in row.groups) {
      final name = (g['name'] as String?)?.trim() ?? '';
      if (name.isEmpty) continue;
      final relType = (g['type'] as String?) ?? '';
      final targetType = ((g['target_type'] as String?) ?? '').toLowerCase();
      final mbid = _emptyToNull((g['mbid'] as String?)?.trim());
      final local = mbid == null ? null : byMbid[mbid];
      final ref = local != null
          ? refOf(local, rels: [relType])
          : ArtistRef(
              name: name,
              mbid: mbid,
              type: targetType.isEmpty ? 'group' : targetType,
              disambiguation: _emptyToNull(g['disambiguation'] as String?),
            );
      if (relType == 'voice actor' && targetType == 'character') {
        roles.putIfAbsent(ref.mbid ?? ref.name, () => ref);
      } else if (bandTypes.contains(targetType) &&
          bandRelTypes.contains(relType)) {
        bands.putIfAbsent(ref.mbid ?? ref.name, () => ref);
      }
    }

    // ---- 组合：并入本地成员树里的祖先组合，并递归到根 ----
    // 成员树是「组合 → 角色 → 人物」三层，所以往上走会先撞到角色节点：角色不算组合，
    // 但**不能因此停下**，得继续往上把真正的组合、以及组合的上级组合一并捞出来。
    final bandKeys = <String>{};
    final walked = <String>{};
    void walkUp(String key, String relLabel) {
      if (!walked.add(key)) return;
      final r = rows[key];
      final isBand = r != null && bandTypes.contains(r.type);
      if (isBand) {
        bands.putIfAbsent(
            r.mbid ?? r.artistKey, () => refOf(r, rels: [relLabel]));
        bandKeys.add(key);
      }
      for (final up in parents[key] ?? const <String>[]) {
        // 穿过角色节点时标签不变（那还是本人的「所属组合」）；已到组合再往上是「上级组合」。
        walkUp(up, isBand ? '上级组合' : relLabel);
      }
    }

    for (final p in parents[artistKey] ?? const <String>[]) {
      walkUp(p, '所属组合');
    }
    for (final b in bands.values.toList()) {
      final k = b.artistKey;
      if (k != null) walkUp(k, '上级组合');
    }

    // ---- 成员：同组合的其他人物（排除自己）----
    final members = <String, ArtistRef>{};
    for (final k in bandKeys) {
      for (final p in _personsUnder(k, children, types)) {
        if (p == artistKey) continue;
        final r = rows[p];
        if (r != null) members.putIfAbsent(p, () => refOf(r));
      }
    }

    List<ArtistRef> ordered(Map<String, ArtistRef> m) {
      final list = m.values.toList()
        ..sort((a, b) {
          // 本地有身份行的排前面（能点进去），再按曲目数、名字排。
          final l = a.artistKey == null ? 1 : 0;
          final r = b.artistKey == null ? 1 : 0;
          if (l != r) return l - r;
          final c = (b.songCount ?? -1).compareTo(a.songCount ?? -1);
          if (c != 0) return c;
          return a.name.compareTo(b.name);
        });
      return list;
    }

    final out = ArtistDetail(
      bands: ordered(bands),
      roles: ordered(roles),
      members: ordered(members),
    );
    return out.isEmpty ? null : out;
  }

  /// 某身份对应的歌曲（走映射，天然含别名/角色合并）。
  ///
  /// 成员身份自己没有 role='main' 映射（歌曲只标了组合名），所以沿 [artist_member]
  /// 反向递归到所有祖先身份，把它们的歌一并算作该身份的歌——歌手页点开声优/成员
  /// 时看到的正是社团名下那批歌。非成员身份退化为原来的单身份查询。
  List<Song> identitySongs(String artistKey,
      {int minDurationSec = 0, int minSizeBytes = 0}) {
    final ignore = _ignoreFilterSql(minDurationSec, minSizeBytes);
    final rows = _db!.select('''
      WITH RECURSIVE up(key) AS (
        SELECT ?
        UNION
        SELECT am.parent_key FROM up u JOIN artist_member am ON am.member_key=u.key
      )
      SELECT DISTINCT i.id, i.source_key, i.ref, i.title, i.artist, i.album, i.album_artist,
             i.track_no, i.year, i.genre, i.duration, i.format, i.size, i.cover_path,
             i.url, i.missing, i.meta_read, COALESCE(p.is_favorite, 0) AS favorite
      FROM up
      JOIN artist_song_map m ON m.artist_key=up.key AND m.role='main'
      JOIN idx_songs i ON i.source_key=m.source_key AND i.ref=m.ref AND i.missing=0 ${ignore.sql}
      LEFT JOIN play_meta p ON p.source_key=i.source_key AND p.song_ref=i.ref
      ORDER BY i.artist, i.album, i.track_no, i.title
    ''', [artistKey, ...ignore.args]);
    return rows.map(_rowToSong).toList();
  }

  /// identity 模式无映射（本地聚合键未命中的残留）按原字符串分组；正常应为空，
  /// 兜底保证 aggregation 开启后歌手页仍完整。
  List<Artist> identityFallbackGroups(
          {int minDurationSec = 0, int minSizeBytes = 0}) =>
      _db == null
          ? const []
          : identityFallbackGroupsOf(_db!,
              minDurationSec: minDurationSec, minSizeBytes: minSizeBytes);

  // ---------- 后台 isolate 快照读（启动/刷新不阻塞 UI） ----------

  /// 启动/刷新用后台快照：在后台 isolate 里一次完成「歌曲查询 + 专辑分组 +
  /// 歌手分组」，UI isolate 只接收模型列表。主连接的同步小查询（详情页/源浏览）
  /// 不受影响；只有全量读这类大活走这里。
  Future<({List<Song> songs, List<Album> albums, List<Artist> artists})>
      librarySnapshotInBackground({
    required List<String> sourceKeys,
    String? query,
    CollectionSort? artistSort,
    int minDurationSec = 0,
    int minSizeBytes = 0,
  }) {
    final path = _dbPath;
    if (path == null) {
      return Future.value((
        songs: const <Song>[],
        albums: const <Album>[],
        artists: const <Artist>[],
      ));
    }
    perfPhase('index.snapshot'); // TEMP-PROBE
    return runOffThread(() {
      final db = openIsolateDatabase(path);
      try {
        perfPhase('index.snapshot.querySongs'); // TEMP-PROBE
        final songs = queryAllSongs(db,
            sourceKeys: sourceKeys,
            query: query,
            minDurationSec: minDurationSec,
            minSizeBytes: minSizeBytes);
        perfPhase('index.snapshot.albumGroups'); // TEMP-PROBE
        final albums = Album.fromSongs(songs);
        perfPhase('index.snapshot.artistGroups'); // TEMP-PROBE
        return (
          songs: songs,
          albums: albums,
          artists: artistGroupsOf(db,
              query: query,
              sort: artistSort,
              minDurationSec: minDurationSec,
              minSizeBytes: minSizeBytes),
        );
      } finally {
        db.dispose();
      }
    });
  }

  /// 只重算歌手分组（身份解析完成后逐批刷新用），同样在后台 isolate。
  Future<List<Artist>> artistGroupsInBackground({
    String? query,
    CollectionSort? sort,
    int minDurationSec = 0,
    int minSizeBytes = 0,
  }) {
    final path = _dbPath;
    if (path == null) return Future.value(const <Artist>[]);
    perfPhase('index.artistGroupsInBackground'); // TEMP-PROBE
    return runOffThread(() {
      final db = openIsolateDatabase(path);
      try {
        perfPhase('index.artistGroupsInBackground.build'); // TEMP-PROBE
        return artistGroupsOf(db,
            query: query,
            sort: sort,
            minDurationSec: minDurationSec,
            minSizeBytes: minSizeBytes);
      } finally {
        db.dispose();
      }
    });
  }

  /// 身份数量/状态汇总（信息页）。
  Map<String, int> artistStats() {
    int cnt(dynamic v) => (v as num?)?.toInt() ?? 0;
    final r = _db!.select('''
      SELECT COUNT(*) total,
        COALESCE(SUM(status='resolved'),0) resolved,
        COALESCE(SUM(status='ambiguous'),0) ambiguous,
        COALESCE(SUM(status='local'),0) local,
        COALESCE(SUM(status='pending'),0) pending
      FROM artists
    ''').first;
    final mapped = _db!
        .select("SELECT COUNT(*) c FROM artist_song_map WHERE role='main'")
        .first['c'];
    final withArtist = _db!
        .select(
            "SELECT COUNT(*) c FROM idx_songs WHERE missing=0 AND artist IS NOT NULL AND artist<>''")
        .first['c'];
    // 成员图进度：mated 关系条数 / 已展开身份数 / 展开不出成员（歌手页回落显示组合）的身份数。
    final memberRows = _db!.select('''
      SELECT (SELECT COUNT(*) FROM artist_member) members,
             (SELECT COUNT(*) FROM artists WHERE expanded_at IS NOT NULL) expanded,
             (SELECT COUNT(*) FROM artists a WHERE a.member_count=0
                AND EXISTS (SELECT 1 FROM artist_song_map m WHERE m.artist_key=a.artist_key)
                AND a.type<>'person') fallback
    ''').first;
    return {
      'total': cnt(r['total']),
      'resolved': cnt(r['resolved']),
      'ambiguous': cnt(r['ambiguous']),
      'local': cnt(r['local']),
      'pending': cnt(r['pending']),
      'mapped': cnt(mapped),
      'withArtist': cnt(withArtist),
      'members': cnt(memberRows['members']),
      'expanded': cnt(memberRows['expanded']),
      'fallback': cnt(memberRows['fallback']),
    };
  }

  /// 解析结果整行走写隔离落库（占位更新 / 首次解析 / 人工绑定全新 mbid）。
  Future<void> artistUpsert({
    required String artistKey,
    required String canonicalKey,
    required String displayName,
    required String status,
    required int errorCount,
    required int nextAt,
    String? mbid,
    List<Map<String, dynamic>>? names,
    List<Map<String, dynamic>>? groups,
    String? type,
    String? disambiguation,
    String? resolvedAt,
    double? matchScore,
  }) {
    return _writer!.op<void>('artistUpsert', {
      'artistKey': artistKey,
      'canonicalKey': canonicalKey,
      'displayName': displayName,
      'status': status,
      'errorCount': errorCount,
      'nextAt': nextAt,
      'mbid': mbid,
      'names': names ?? const [],
      'groups': groups ?? const [],
      'type': type ?? 'person',
      'disambiguation': disambiguation,
      'resolvedAt': resolvedAt,
      'matchScore': matchScore,
    });
  }

  /// 把某 canonical 的解析结果并入已存在的 mbid 身份行（同真人别名合流）。
  /// 返回是否命中已存在 mbid 行；false 时调用方改用 [artistUpsert]。
  Future<bool> artistMergeMbid({
    required String canonicalKey,
    required String fromArtistKey,
    required String mbid,
    String? displayName,
    String? type,
    String? disambiguation,
    List<Map<String, dynamic>>? names,
    List<Map<String, dynamic>>? groups,
    double? matchScore,
  }) {
    return _writer!.op<bool>('artistMergeMbid', {
      'canonicalKey': canonicalKey,
      'fromArtistKey': fromArtistKey,
      'mbid': mbid,
      'displayName': displayName,
      'type': type ?? 'person',
      'disambiguation': disambiguation,
      'names': names ?? const [],
      'groups': groups ?? const [],
      'matchScore': matchScore,
      'update': true,
    });
  }

  /// 重置 local/ambiguous 为 pending 重试解析（canonicalKey=null 表示全部）。
  /// 已解析成功的身份不受影响。
  Future<void> artistRetry({String? canonicalKey}) {
    return _writer!.op<void>('artistRetry', {'canonicalKey': canonicalKey});
  }

  /// 强制解析：连 resolved 一起打回 pending，并清 expanded_at 让成员重新展开。
  /// 三选一传参：[all]=true 全部、[artistKey] 单个身份、[canonicalKey] 单个归一化键。
  Future<void> artistForceRetry(
      {bool all = false, String? artistKey, String? canonicalKey}) {
    return _writer!.op<void>('artistForceRetry',
        {'all': all, 'artistKey': artistKey, 'canonicalKey': canonicalKey});
  }

  /// 记某一轮失败待重试；不动 mbid/names/groups/type（见 writer 侧 _opArtistMarkError）。
  Future<void> artistMarkError({
    required String artistKey,
    required int errorCount,
    required int nextAt,
    String status = 'local',
  }) {
    return _writer!.op<void>('artistMarkError', {
      'artistKey': artistKey,
      'errorCount': errorCount,
      'nextAt': nextAt,
      'status': status,
    });
  }

  /// 行 → 身份模型。实现见顶层 [artistRowFrom]（后台 isolate 快照共用）。
  ArtistRow _rowToArtist(Row r) => artistRowFrom(r);
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

/// 播放数据总览（歌曲信息页用）：见 [LocalIndex.playOverview]。
class PlayOverview {
  final int total;
  final int withPlay;
  final int totalSec;
  final double totalCount;
  final int countZero;
  final int countLt1;
  final int count1to5;
  final int countGt5;
  final int secZero;
  final int secLt10m;
  final int sec10mTo1h;
  final int secGt1h;
  const PlayOverview({
    required this.total,
    required this.withPlay,
    required this.totalSec,
    required this.totalCount,
    required this.countZero,
    required this.countLt1,
    required this.count1to5,
    required this.countGt5,
    required this.secZero,
    required this.secLt10m,
    required this.sec10mTo1h,
    required this.secGt1h,
  });
}

/// 播放数据明细行（歌曲信息页用）：见 [LocalIndex.playDetailRows]。
class PlayDetailRow {
  final String sourceKey;
  final String ref;
  final String title;
  final String? artist;
  final int? duration;
  final int playSec;
  const PlayDetailRow({
    required this.sourceKey,
    required this.ref,
    required this.title,
    this.artist,
    this.duration,
    required this.playSec,
  });
}

/// 元数据明细行（歌曲信息页用）：见 [LocalIndex.metaDetailRows]。
class MetaDetailRow {
  final String sourceKey;
  final String ref;
  final String title;
  final String? artist;
  final String? album;
  final String? albumArtist;
  final String? genre;
  final int? trackNo;
  final int? year;
  final int? duration;
  final String? coverPath;
  final String? format;
  final int size;
  final bool metaRead;
  final bool hasLyrics;
  const MetaDetailRow({
    required this.sourceKey,
    required this.ref,
    required this.title,
    this.artist,
    this.album,
    this.albumArtist,
    this.genre,
    this.trackNo,
    this.year,
    this.duration,
    this.coverPath,
    this.format,
    required this.size,
    required this.metaRead,
    required this.hasLyrics,
  });

  bool get hasArtist => artist != null && artist!.isNotEmpty;
  bool get hasAlbum => album != null && album!.isNotEmpty;
  bool get hasAlbumArtist => albumArtist != null && albumArtist!.isNotEmpty;
  bool get hasGenre => genre != null && genre!.isNotEmpty;
  bool get hasTrackNo => trackNo != null;
  bool get hasYear => year != null;
  bool get hasDuration => duration != null && duration! > 0;
  bool get hasCover => coverPath != null && coverPath!.isNotEmpty;
  bool get hasFormat => format != null && format!.isNotEmpty;
  bool get bitrateEstimable => size > 0 && hasDuration;

  /// 缺失维度数（12 维，与总览页 [_dims] 对应，含 meta_read 本身）。
  int get missingCount {
    var m = 0;
    if (!metaRead) m++;
    if (!hasArtist) m++;
    if (!hasAlbum) m++;
    if (!hasAlbumArtist) m++;
    if (!hasGenre) m++;
    if (!hasTrackNo) m++;
    if (!hasYear) m++;
    if (!hasDuration) m++;
    if (!hasCover) m++;
    if (!hasLyrics) m++;
    if (!hasFormat) m++;
    if (!bitrateEstimable) m++;
    return m;
  }

  /// 指定维度是否有（dim key 与总览页一致）。
  bool hasDim(String dim) => switch (dim) {
        'meta_read' => metaRead,
        'artist' => hasArtist,
        'album' => hasAlbum,
        'album_artist' => hasAlbumArtist,
        'genre' => hasGenre,
        'track_no' => hasTrackNo,
        'year' => hasYear,
        'duration' => hasDuration,
        'cover' => hasCover,
        'lyrics' => hasLyrics,
        'format' => hasFormat,
        'bitrate' => bitrateEstimable,
        _ => true,
      };
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

  /// v2 播放会话 id（旧数据为空）。
  final String? sessionId;
  const PlayStateRow({
    required this.queueJson,
    required this.idx,
    required this.positionMs,
    required this.updatedAt,
    this.playlistUuid,
    this.anchorKey,
    this.sessionId,
  });
}

/// 同步 outbox 行（阶段5）。
class OutboxRow {
  final String eventUuid;
  final String type;

  /// 已解码的 JSON 载荷（解码在写隔离完成，见 [LocalIndex.pendingOutbox]）。
  final Map<String, dynamic> payload;
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

  /// 最后操作时间（= 服务端命中事件的 occurred_at；旧数据可能为空）。
  final String? lastEventAt;

  /// v2：head/history 独立版本；旧服务端/旧镜像行为 0。
  final int headRev;
  final int historyRev;
  final String? headClock;
  final String? headOpId;
  final String? headSession;
  final bool headPlaying;
  final String? headUpdatedAt;

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
    this.lastEventAt,
    this.headRev = 0,
    this.historyRev = 0,
    this.headClock,
    this.headOpId,
    this.headSession,
    this.headPlaying = false,
    this.headUpdatedAt,
  });

  factory BreakpointMirrorRow.fromMap(Map<String, dynamic> r) {
    return BreakpointMirrorRow(
      playlistUuid: r['playlist_uuid'] as String,
      songId: r['song_id'] as int?,
      sourceId: r['source_id'] as String?,
      source: r['source'] as String?,
      sourceRef: r['source_ref'] as String?,
      positionMs: r['position_ms'] as int? ?? 0,
      deepListJson: r['deep_list_json'] as String?,
      updatedAt: r['updated_at'] as String,
      deviceId: r['device_id'] as String?,
      lastEventAt: r['last_event_at'] as String?,
      headRev: r['head_rev'] as int? ?? 0,
      historyRev: r['history_rev'] as int? ?? 0,
      headClock: r['head_clock'] as String?,
      headOpId: r['head_op_id'] as String?,
      headSession: r['head_session'] as String?,
      headPlaying: (r['head_playing'] as int? ?? 0) != 0,
      headUpdatedAt: r['head_updated_at'] as String?,
    );
  }

  /// 比较时钟（F4）：最后操作时间优先，旧数据回退上传时间 updated_at。
  /// v2 的本地状态机用 head_rev/history_rev 判断，不依赖这个墙钟。
  String get compareClock =>
      (lastEventAt == null || lastEventAt!.isEmpty) ? updatedAt : lastEventAt!;
}

/// 每歌单的 v2 断点同步状态。
class BreakpointSyncState {
  final String playlistUuid;
  final int appliedHeadRev;
  final int appliedHistoryRev;
  final String? pendingHeadOpId;
  final String? sessionId;
  final String? serverEpoch;

  const BreakpointSyncState({
    required this.playlistUuid,
    this.appliedHeadRev = 0,
    this.appliedHistoryRev = 0,
    this.pendingHeadOpId,
    this.sessionId,
    this.serverEpoch,
  });
}

/// 歌手处理.txt：ARTISTS 精炼身份行（names/groups 为 JSON 数组）。
class ArtistRow {
  final String artistKey;
  final String? mbid;
  final String canonicalKey;
  final String displayName;
  final List<Map<String, dynamic>> names;
  final List<Map<String, dynamic>> groups;
  final String type;
  final String? disambiguation;
  final String status;
  final int errorCount;
  final int nextAt;
  final String? resolvedAt;

  /// 采纳该身份时 MusicBrainz 给的检索分数（脏数据过滤后取首个候选）。
  final double? matchScore;
  const ArtistRow({
    required this.artistKey,
    this.mbid,
    required this.canonicalKey,
    required this.displayName,
    this.names = const [],
    this.groups = const [],
    this.type = 'person',
    this.disambiguation,
    this.status = 'pending',
    this.errorCount = 0,
    this.nextAt = 0,
    this.resolvedAt,
    this.matchScore,
  });

  bool get isResolved => status == 'resolved';
  bool get isAmbiguous => status == 'ambiguous';
}

/// 详情页里的一条关联（组合 / 角色 / 成员）。
///
/// [artistKey] 为空表示本地还没这条身份（MusicBrainz 报了但没展开过），只能展示
/// 不能点进去；[songCount] 为空同理——没身份就没法算它在歌手页的展示曲目数。
class ArtistRef {
  final String name;
  final String? mbid;
  final String type;
  final String? disambiguation;

  /// 本地身份键；null = 本地没这条身份。
  final String? artistKey;

  /// 歌手页展示曲目数；null = 本地没这条身份，算不出来。
  final int? songCount;

  /// 与本人的关系描述（如 `上级组合`、`member of band`）。
  final List<String> relations;

  const ArtistRef({
    required this.name,
    this.mbid,
    this.type = 'person',
    this.disambiguation,
    this.artistKey,
    this.songCount,
    this.relations = const [],
  });
}

/// 人物身份的详情（[LocalIndex.artistDetail] 的结果）。
class ArtistDetail {
  final List<ArtistRef> bands;
  final List<ArtistRef> roles;
  final List<ArtistRef> members;

  const ArtistDetail({
    this.bands = const [],
    this.roles = const [],
    this.members = const [],
  });

  /// 三栏都没内容时不渲染详情区（免得点开是个空壳）。
  bool get isEmpty => bands.isEmpty && roles.isEmpty && members.isEmpty;
}

/// 歌手处理.txt：待解析工作项（解析服务轮询用）。
class ArtistWorkItem {
  final String artistKey;
  final String canonicalKey;
  final String displayName;
  final String status;
  final int errorCount;
  final int nextAt;
  final String? mbid;
  const ArtistWorkItem({
    required this.artistKey,
    required this.canonicalKey,
    required this.displayName,
    required this.status,
    required this.errorCount,
    required this.nextAt,
    this.mbid,
  });
}

// ---------- 顶层查询实现（读写分离） ----------
//
// 这些函数不依赖 LocalIndex 实例：主连接方法（LocalIndex 内的同步读）与后台
// isolate 快照（另开连接读同一份库）共用同一份 SQL 与映射逻辑，避免两处漂移。
// 见 LocalIndex.librarySnapshotInBackground / artistGroupsInBackground。

/// 「忽略音频（时长/大小）」过滤子句（改进.txt 功能6）：设置变更后，
/// 已扫描入库的歌曲也按规则过滤——时长未知（NULL/0，快扫未读头）一律放过。
/// 返回 `(sqlFragment, extraArgs)`；两个阈值均为 0 时条件恒真（零开销兜底）。
({String sql, List<Object?> args}) ignoreFilterSql(
    int minDurationSec, int minSizeBytes) {
  return (
    sql: '''
      AND (i.duration IS NULL OR i.duration<=0 OR ?<=0 OR i.duration>=?)
      AND (i.size IS NULL OR i.size<=0 OR ?<=0 OR i.size>=?)
      ''',
    args: [minDurationSec, minDurationSec, minSizeBytes, minSizeBytes],
  );
}

/// 从 source_key（'webdav:name'）取协议名（'webdav'）。
String sourceOf(String key) {
  final i = key.indexOf(':');
  return i > 0 ? key.substring(0, i) : key;
}

/// 数据库行 → 歌曲模型（列名与 [querySongs] 的 SELECT 对齐）。
Song songFromRow(Row r) => Song.direct(
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
      source: sourceOf(r['source_key'] as String),
      sourceRef: r['ref'] as String,
      fileSize: r['size'] as int,
      format: r['format'] as String?,
      favorite: r['favorite'] == 1,
      coverPath: r['cover_path'] as String?,
      sourceUrl: r['url'] as String?,
      metaRead: (r['meta_read'] as int? ?? 0) == 1,
    );

/// 按源查询歌曲（主连接与后台快照共用）。
List<Song> querySongs(
  Database db, {
  required String sourceKey,
  String? query,
  int page = 1,
  int? size,
  int minDurationSec = 0,
  int minSizeBytes = 0,
}) {
  final q = query?.trim().toLowerCase() ?? '';
  final like = q.isEmpty ? '%' : '%$q%';
  // size==null 时不设 LIMIT（返回全部，供列表无限滚动 / 全选）。
  final limitSql = size == null ? '' : 'LIMIT ? OFFSET ?';
  final ignore = ignoreFilterSql(minDurationSec, minSizeBytes);
  final args = <Object?>[sourceKey, like, like, like];
  args.addAll(ignore.args);
  if (size != null) {
    args.add(size);
    args.add((page - 1) * size);
  }
  final rows = db.select('''
      SELECT i.id, i.source_key, i.ref, i.title, i.artist, i.album, i.album_artist, i.track_no,
             i.year, i.genre, i.duration, i.format, i.size, i.cover_path, i.url, i.missing,
             i.meta_read, COALESCE(p.is_favorite, 0) AS favorite
      FROM idx_songs i
      LEFT JOIN play_meta p ON p.source_key = i.source_key AND p.song_ref = i.ref
      WHERE i.source_key=? AND i.missing=0
        AND (i.title LIKE ? OR COALESCE(i.artist,'') LIKE ? OR COALESCE(i.album,'') LIKE ?)
        ${ignore.sql}
      ORDER BY i.artist, i.album, i.track_no, i.title
      $limitSql
    ''', args);
  return rows.map(songFromRow).toList();
}

/// 播放数据明细查询（详情页；后台 isolate 读共用，见
/// [LocalIndex.playDetailRowsInBackground]）。排序在 UI 侧完成。
List<PlayDetailRow> playDetailRowsOf(Database db) {
  final rs = db.select('''
    SELECT i.source_key AS source_key, i.ref AS ref, i.title AS title,
           i.artist AS artist, i.duration AS duration,
           COALESCE(p.play_sec,0) AS play_sec
    FROM idx_songs i
    LEFT JOIN play_meta p ON p.source_key=i.source_key AND p.song_ref=i.ref
    WHERE i.missing=0
    ORDER BY i.id
  ''');
  return [
    for (final r in rs)
      PlayDetailRow(
        sourceKey: (r['source_key'] as String?) ?? '',
        ref: (r['ref'] as String?) ?? '',
        title: (r['title'] as String?) ?? 'Unknown',
        artist: r['artist'] as String?,
        duration: (r['duration'] as num?)?.toInt(),
        playSec: (r['play_sec'] as num?)?.toInt() ?? 0,
      ),
  ];
}

/// 元数据明细查询（详情页；后台 isolate 读共用，见
/// [LocalIndex.metaDetailRowsInBackground]）。
List<MetaDetailRow> metaDetailRowsOf(Database db) {
  final rs = db.select('''
    SELECT i.source_key AS source_key, i.ref AS ref, i.title AS title,
           i.artist AS artist, i.album AS album,
           i.album_artist AS album_artist, i.genre AS genre,
           i.track_no AS track_no, i.year AS year, i.duration AS duration,
           i.cover_path AS cover_path, i.format AS format, i.size AS size,
           COALESCE(i.meta_read,0) AS meta_read,
           CASE WHEN l.content IS NOT NULL AND l.content<>'' THEN 1 ELSE 0 END AS has_lyrics
    FROM idx_songs i
    LEFT JOIN song_lyrics l ON l.source_key=i.source_key AND l.ref=i.ref
    WHERE i.missing=0
    ORDER BY i.id
  ''');
  return [
    for (final r in rs)
      MetaDetailRow(
        sourceKey: (r['source_key'] as String?) ?? '',
        ref: (r['ref'] as String?) ?? '',
        title: (r['title'] as String?) ?? 'Unknown',
        artist: r['artist'] as String?,
        album: r['album'] as String?,
        albumArtist: r['album_artist'] as String?,
        genre: r['genre'] as String?,
        trackNo: (r['track_no'] as num?)?.toInt(),
        year: (r['year'] as num?)?.toInt(),
        duration: (r['duration'] as num?)?.toInt(),
        coverPath: r['cover_path'] as String?,
        format: r['format'] as String?,
        size: (r['size'] as num?)?.toInt() ?? 0,
        metaRead: ((r['meta_read'] as num?)?.toInt() ?? 0) == 1,
        hasLyrics: ((r['has_lyrics'] as num?)?.toInt() ?? 0) == 1,
      ),
  ];
}

/// 多源合并查询（启动/刷新快照用）：逐源查询后拼接，与
/// `DirectSourceManager.allSongs` 同序。
List<Song> queryAllSongs(
  Database db, {
  required List<String> sourceKeys,
  String? query,
  int minDurationSec = 0,
  int minSizeBytes = 0,
}) {
  final out = <Song>[];
  for (final key in sourceKeys) {
    out.addAll(querySongs(db,
        sourceKey: key,
        query: query,
        minDurationSec: minDurationSec,
        minSizeBytes: minSizeBytes));
  }
  return out;
}

/// 数据库行 → 身份模型。
ArtistRow artistRowFrom(Row r) => ArtistRow(
      artistKey: r['artist_key'] as String,
      mbid: r['mbid'] as String?,
      canonicalKey: r['canonical_key'] as String,
      displayName: r['display_name'] as String,
      names: _jsonMapList(r['names']),
      groups: _jsonMapList(r['groups']),
      type: r['type'] as String,
      disambiguation: r['disambiguation'] as String?,
      status: r['status'] as String,
      errorCount: r['error_count'] as int,
      nextAt: r['next_at'] as int,
      resolvedAt: r['resolved_at'] as String?,
      matchScore: (r['match_score'] as num?)?.toDouble(),
    );

List<Map<String, dynamic>> _jsonMapList(Object? raw) {
  if (raw == null) return const [];
  try {
    return (jsonDecode(raw as String) as List).cast<Map<String, dynamic>>();
  } catch (_) {
    return const [];
  }
}

/// 从 [root] 沿成员边广度展开出所有 type='person' 的身份（含 root 自身若是 Person）。
/// visited 按 artist_key 防环；成员表很小，深度不设限也不会失控。
List<String> personsUnder(String root, Map<String, List<String>> children,
    Map<String, String> types) {
  final out = <String>[];
  final seen = <String>{};
  final queue = <String>[root];
  while (queue.isNotEmpty) {
    final cur = queue.removeAt(0);
    if (!seen.add(cur)) continue;
    if (types[cur] == 'person') out.add(cur);
    queue.addAll(children[cur] ?? const <String>[]);
  }
  return out;
}

/// 各身份的展示口径统计（歌曲数 + 专辑数）：沿成员边向上递归到「自己 + 全部
/// 祖先」，统计祖先名下 role='main' 的歌曲。专辑数按全局专辑分组键统计，与
/// [Album.fromSongs] 一致。语义与 [LocalIndex.identitySongs] 同源。
Map<String, ({int songs, int albums})> identityDisplayStatsOf(
    Database db,
    {int minDurationSec = 0,
    int minSizeBytes = 0}) {
  final ignore = ignoreFilterSql(minDurationSec, minSizeBytes);
  final out = <String, ({int songs, int albums})>{};
  for (final r in db.select('''
      WITH RECURSIVE up(k, owner) AS (
        SELECT artist_key, artist_key FROM artists
        UNION
        SELECT u.k, am.parent_key FROM up u JOIN artist_member am ON am.member_key=u.owner
      )
      SELECT u.k AS k,
             COUNT(DISTINCT m.source_key || char(1) || m.ref) AS n,
             COUNT(DISTINCT
               CASE WHEN TRIM(COALESCE(i.album,''))='' THEN
                 COALESCE(NULLIF(TRIM(i.album_artist),''), NULLIF(TRIM(i.artist),''), 'Unknown')
                 || char(1) || 'Unknown Album'
               ELSE TRIM(i.album) END) AS albums
      FROM up u
      JOIN artist_song_map m ON m.artist_key=u.owner AND m.role='main'
      JOIN idx_songs i ON i.source_key=m.source_key AND i.ref=m.ref AND i.missing=0
        ${ignore.sql}
      GROUP BY u.k
    ''', ignore.args)) {
    out[r['k'] as String] =
        (songs: r['n'] as int, albums: r['albums'] as int);
  }
  return out;
}

/// 歌手页主数据源（identity 模式）：显示集合不是「有歌的身份」而是「**歌手**」：
/// 组合/角色沿 [LocalIndex.artistSetMembers] 建的边递归展开，只显示
/// type='person' 的末端；整条链一个 Person 都没有时才回落显示该身份本身。
/// 歌曲归属反向继承——计数由 [identityDisplayStatsOf] 沿祖先合并。
List<Artist> identityArtistGroupsOf(
  Database db, {
  String? query,
  CollectionSort? sort,
  int minDurationSec = 0,
  int minSizeBytes = 0,
}) {
  final q = query?.trim() ?? '';
  final like = q.isEmpty ? '%' : '%$q%';
  final ignore = ignoreFilterSql(minDurationSec, minSizeBytes);

  final types = <String, String>{};
  for (final r in db.select('SELECT artist_key, type FROM artists')) {
    types[r['artist_key'] as String] = (r['type'] as String?) ?? 'person';
  }
  final children = <String, List<String>>{};
  for (final r in db.select('SELECT parent_key, member_key FROM artist_member')) {
    (children[r['parent_key'] as String] ??= <String>[])
        .add(r['member_key'] as String);
  }
  final owners = <String>[
    for (final r in db.select(
        "SELECT DISTINCT artist_key FROM artist_song_map WHERE role='main'"))
      r['artist_key'] as String
  ];

  // owner → 应显示的身份；无 Person 可达时回落 owner 自己。
  //
  // 同一身份可能挂在**多个** owner 下（成员同时属于两个组合），每个 owner 都要留
  // 一条 pair；计数由 [identityDisplayStatsOf] 按显示身份合并（自己 + 全部祖先），
  // 不会少算。这里只让 personsUnder 内部按 artist_key 去重（防环），不再全局去重。
  final pairs = <List<String>>[];
  for (final o in owners) {
    final display = personsUnder(o, children, types);
    for (final d in (display.isEmpty ? <String>[o] : display)) {
      pairs.add([d, o]);
    }
  }
  if (pairs.isEmpty) return const [];

  // 显示身份的计数：与详情页 identitySongs 完全同一口径（沿成员边向上递归到
  // 「自己 + 全部祖先」）。以前列表按 pairs 逐 owner 累加，是与详情页各写一套的
  // 近似口径，重解析/合流后两处可能漂移（列表旧数、详情新数）。
  final stats = identityDisplayStatsOf(db,
      minDurationSec: minDurationSec, minSizeBytes: minSizeBytes);

  // 展示集合：pairs 里的 display 身份去重后按名字 LIKE 过滤；无歌（或全被忽略
  // 规则过滤）的身份不展示。
  final displayRows = <String, ArtistRow>{};
  for (final r in db.select(
      'SELECT * FROM artists WHERE display_name LIKE ?', [like])) {
    final a = artistRowFrom(r);
    displayRows[a.artistKey] = a;
  }
  final displays = <String, ArtistRow>{};
  for (final p in pairs) {
    if (!stats.containsKey(p[0])) continue;
    final a = displayRows[p[0]];
    if (a == null) continue;
    displays.putIfAbsent(p[0], () => a);
  }
  if (displays.isEmpty) return const [];

  // 封面：同一身份的多首歌取最早入库的那张（成员继承自祖先的歌）。
  final covers = <String, String?>{};
  for (final r in db.select('''
      WITH pairs(dk, ok) AS (
        SELECT json_extract(value,'\$[0]'), json_extract(value,'\$[1]')
        FROM json_each(?)
      )
      SELECT p.dk AS dk, i.cover_path AS c
      FROM pairs p
      JOIN artists a ON a.artist_key=p.dk AND a.display_name LIKE ?
      JOIN artist_song_map m ON m.artist_key=p.ok AND m.role='main'
      JOIN idx_songs i ON i.source_key=m.source_key AND i.ref=m.ref AND i.missing=0
        AND i.cover_path IS NOT NULL
        ${ignore.sql}
      ORDER BY i.id
    ''', [jsonEncode(pairs), like, ...ignore.args])) {
    covers.putIfAbsent(r['dk'] as String, () => r['c'] as String?);
  }

  final list = <Artist>[
    for (final e in displays.entries)
      Artist(
        name: e.value.displayName,
        songCount: stats[e.key]!.songs,
        albumCount: stats[e.key]!.albums,
        coverPath: covers[e.key],
        identityKey: e.key,
        canonicalKey: e.value.canonicalKey,
        status: e.value.status,
        mbid: e.value.mbid,
      ),
  ];
  final pref = sort ?? CollectionSort.charAsc;
  return sortByCollection(list, pref, (a) => a.name,
      countOf: (a) => a.songCount);
}

/// identity 模式无映射（本地聚合键未命中的残留）按原字符串分组；正常应为空，
/// 兜底保证聚合开启后歌手页仍完整。
List<Artist> identityFallbackGroupsOf(
    Database db,
    {int minDurationSec = 0,
    int minSizeBytes = 0}) {
  final ignore = ignoreFilterSql(minDurationSec, minSizeBytes);
  final fallback = ignore.sql.replaceAll('i.', 's.');
  final cover = ignore.sql
      .replaceAll('i.', '')
      .replaceAll('s.duration', 'duration')
      .replaceAll('s.size', 'size')
      .replaceAll('s.cover', 'cover');
  final rs = db.select('''
      SELECT s.artist raw, COUNT(*) n,
        COUNT(DISTINCT
          CASE WHEN TRIM(COALESCE(s.album,''))='' THEN
            COALESCE(NULLIF(TRIM(s.album_artist),''), NULLIF(TRIM(s.artist),''), 'Unknown')
            || char(1) || 'Unknown Album'
          ELSE TRIM(s.album) END) al,
        (SELECT cover_path FROM idx_songs WHERE artist=s.artist AND cover_path IS NOT NULL
          $cover ORDER BY id LIMIT 1) c
      FROM idx_songs s
      WHERE s.missing=0 AND s.artist IS NOT NULL AND s.artist<>''
        AND NOT EXISTS (SELECT 1 FROM artist_song_map m
                         WHERE m.source_key=s.source_key AND m.ref=s.ref AND m.role='main')
        $fallback
      GROUP BY s.artist
    ''', [...ignore.args, ...ignore.args]);
  return [
    for (final r in rs)
      Artist(
        name: r['raw'] as String,
        songCount: r['n'] as int,
        albumCount: r['al'] as int,
        coverPath: r['c'] as String?,
      ),
  ];
}

/// 歌手列表完整口径：身份聚合 + 无映射残留兜底（顺序与
/// [LocalIndex.identityArtistGroups] + [LocalIndex.identityFallbackGroups] 一致）。
List<Artist> artistGroupsOf(
  Database db, {
  String? query,
  CollectionSort? sort,
  int minDurationSec = 0,
  int minSizeBytes = 0,
}) =>
    [
      ...identityArtistGroupsOf(db,
          query: query,
          sort: sort,
          minDurationSec: minDurationSec,
          minSizeBytes: minSizeBytes),
      ...identityFallbackGroupsOf(db,
          minDurationSec: minDurationSec, minSizeBytes: minSizeBytes),
    ];

/// 收集无效封面文件并删除，返回其路径列表（DB 引用由调用方标记）。
/// 无效含两种：签名不符（旧脏数据）与**截断半图**（问题1：只验头落盘的
/// JPEG 头+部分 MCU，轻量尾判 [isCompleteImageBytes] 不通过）。
/// 同步 IO，供后台 isolate 调用；每次启动都跑（自动清理存量半图并重标未读）。
List<String> collectInvalidCoverPaths(String coversDirPath) {
  final dir = Directory(coversDirPath);
  if (!dir.existsSync()) return const [];
  final out = <String>[];
  final now = DateTime.now();
  for (final f in dir.listSync()) {
    if (f is! File) continue;
    try {
      // 跳过刚落盘的文件，避免与正在进行的扫描/补读写盘竞争。
      // 原子落盘的 tmp 残留（崩溃中断）超 5 分钟一并清理（无 DB 引用，只删文件）。
      if (now.difference(f.statSync().modified).inMinutes < 5) continue;
      if (f.path.endsWith('.tmp')) {
        try {
          f.deleteSync();
        } catch (_) {}
        continue;
      }
      final bytes = f.readAsBytesSync();
      if (!isCompleteImageBytes(bytes)) {
        f.deleteSync();
        out.add(f.path);
      }
    } catch (_) {
      // 单文件失败忽略，继续清理其余。
    }
  }
  return out;
}

// ---------- 封面切片落盘辅助（主线程长同步块治理 R-1） ----------

/// 分片计算文件引用（ref）的 md5 十六进制——这里入参是**封面字节**（本函数只对
/// 封面内容做分片处理，ref 的哈希在主路径上一次性完成）。
Future<String> _md5HexChunked(Uint8List bytes, ChunkYield yieldTo) async {
  const chunk = 256 * 1024;
  final sink = _DigestCollector();
  final input = md5.startChunkedConversion(sink);
  for (var off = 0; off < bytes.length; off += chunk) {
    final end = off + chunk < bytes.length ? off + chunk : bytes.length;
    input.add(Uint8List.sublistView(bytes, off, end));
    if (end < bytes.length) await yieldTo();
  }
  input.close();
  return sink.digest.toString();
}

/// 分片写盘：覆盖写 [f]（截断），每片之间让出事件循环；末片 flush。
Future<void> _writeBytesChunked(
    File f, Uint8List bytes, ChunkYield yieldTo) async {
  const chunk = 512 * 1024;
  final raf = f.openSync(mode: FileMode.write);
  try {
    for (var off = 0; off < bytes.length; off += chunk) {
      final end = off + chunk < bytes.length ? off + chunk : bytes.length;
      raf.writeFromSync(bytes, off, end);
      if (end < bytes.length) await yieldTo();
    }
    raf.flushSync();
  } finally {
    raf.closeSync();
  }
}

/// 收集 [md5.startChunkedConversion] 的最终摘要。
class _DigestCollector implements Sink<Digest> {
  late Digest digest;
  @override
  void add(Digest data) => digest = data;
  @override
  void close() {}
}
