import 'package:sqlite3/sqlite3.dart';

/// 建表与迁移（幂等）：主线程读连接与后台写隔离共用同一份，
/// 保证两边连接的 schema 始终一致（WAL 单文件多连接）。
///
/// 迁移约定：ALTER TABLE 均先做 PRAGMA table_info 探测，缺列才补，
/// 因此重复执行安全（启动开连接、写隔离开连接各跑一遍）。
void applySchema(Database db) {
  db.execute('PRAGMA journal_mode=WAL;');
  db.execute('''
    CREATE TABLE IF NOT EXISTS sources (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      key TEXT NOT NULL UNIQUE,
      kind TEXT NOT NULL,
      name TEXT NOT NULL,
      config TEXT NOT NULL,
      enabled INTEGER NOT NULL DEFAULT 1,
      status TEXT NOT NULL DEFAULT '',
      last_scan_at TEXT,
      client_uuid TEXT
    );
  ''');
  final sourceCols = db
      .select('PRAGMA table_info(sources)')
      .map((r) => r['name'] as String)
      .toSet();
  if (!sourceCols.contains('client_uuid')) {
    db.execute('ALTER TABLE sources ADD COLUMN client_uuid TEXT');
  }
  db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_sources_uuid ON sources(client_uuid)');
  db.execute('''
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
  db.execute('''
    CREATE TABLE IF NOT EXISTS cache (
      cache_key TEXT PRIMARY KEY,
      path TEXT NOT NULL,
      size INTEGER NOT NULL DEFAULT 0
    );
  ''');
  // 阶段 2：歌曲播放元数据 / 歌单 / 应用设置 / 断点（DESIGN §7，stage2.md §1）。
  db.execute('''
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
  db.execute('''
    CREATE TABLE IF NOT EXISTS playlists (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      name        TEXT NOT NULL,
      description TEXT,
      created_at  TEXT NOT NULL
    );
  ''');
  db.execute('''
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
  db.execute('''
    CREATE TABLE IF NOT EXISTS app_settings (
      key   TEXT PRIMARY KEY,
      value TEXT NOT NULL
    );
  ''');
  db.execute('''
    CREATE TABLE IF NOT EXISTS play_state (
      id          INTEGER PRIMARY KEY CHECK (id = 1),
      queue_json  TEXT NOT NULL,
      idx         INTEGER NOT NULL,
      position_ms INTEGER NOT NULL,
      updated_at  TEXT NOT NULL,
      playlist_uuid TEXT,
      anchor_key    TEXT
    );
  ''');
  final stateCols = db
      .select('PRAGMA table_info(play_state)')
      .map((r) => r['name'] as String)
      .toSet();
  if (!stateCols.contains('playlist_uuid')) {
    db.execute('ALTER TABLE play_state ADD COLUMN playlist_uuid TEXT');
  }
  // 融合队列锚定键（任意列表上下文：playlist:<uuid>/liked/songs/album/artist/source）。
  if (!stateCols.contains('anchor_key')) {
    db.execute('ALTER TABLE play_state ADD COLUMN anchor_key TEXT');
  }
  final cacheCols = db
      .select('PRAGMA table_info(cache)')
      .map((r) => r['name'] as String)
      .toSet();
  if (!cacheCols.contains('cached_at')) {
    db.execute('ALTER TABLE cache ADD COLUMN cached_at TEXT');
  }
  if (!cacheCols.contains('last_accessed_at')) {
    db.execute('ALTER TABLE cache ADD COLUMN last_accessed_at TEXT');
  }
  // idx_songs 增量指纹：getetag（WebDAV）列，mtime/size 已在建表时定义。
  final songCols = db
      .select('PRAGMA table_info(idx_songs)')
      .map((r) => r['name'] as String)
      .toSet();
  if (!songCols.contains('etag')) {
    db.execute('ALTER TABLE idx_songs ADD COLUMN etag TEXT');
  }
  if (!songCols.contains('url')) {
    db.execute('ALTER TABLE idx_songs ADD COLUMN url TEXT');
  }
  // 用户手动改过元数据的行：扫描不再覆盖其标题/歌手/专辑。
  if (!songCols.contains('user_edited')) {
    db.execute(
        'ALTER TABLE idx_songs ADD COLUMN user_edited INTEGER NOT NULL DEFAULT 0');
  }
  // 是否已读取过文件元数据（播放时补读/后台扫描用，N1）。
  if (!songCols.contains('meta_read')) {
    db.execute(
        'ALTER TABLE idx_songs ADD COLUMN meta_read INTEGER NOT NULL DEFAULT 0');
  }
  // 专辑歌手（mp3 TPE2 / flac ALBUMARTIST）。
  if (!songCols.contains('album_artist')) {
    db.execute('ALTER TABLE idx_songs ADD COLUMN album_artist TEXT');
  }
  // 歌词（内嵌标签 / 同目录 .lrc 原文）：独立表存储，歌曲列表查询不加载大文本。
  db.execute('''
    CREATE TABLE IF NOT EXISTS song_lyrics (
      source_key TEXT NOT NULL,
      ref        TEXT NOT NULL,
      content    TEXT NOT NULL,
      updated_at INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (source_key, ref)
    );
  ''');
  // 阶段5 同步：本地变更流水（weight_outbox）+ 远端断点镜像（breakpoint_mirror）。
  db.execute('''
    CREATE TABLE IF NOT EXISTS weight_outbox (
      event_uuid  TEXT PRIMARY KEY,
      type        TEXT NOT NULL,
      payload     TEXT NOT NULL,
      occurred_at TEXT NOT NULL,
      acked       INTEGER NOT NULL DEFAULT 0,
      created_at  TEXT NOT NULL
    );
  ''');
  db.execute('''
    CREATE TABLE IF NOT EXISTS breakpoint_mirror (
      playlist_uuid TEXT PRIMARY KEY,
      song_id       INTEGER,
      source_id     TEXT,
      source        TEXT,
      source_ref    TEXT,
      position_ms   INTEGER NOT NULL DEFAULT 0,
      updated_at    TEXT NOT NULL,
      device_id     TEXT
    );
  ''');
  // 深层列表：每个锚定上下文一条「仅可修改末尾值」的历史栈（JSON 快照，仅本机）。
  // playlist_uuid 列存储通用锚定键（playlist:<uuid>/liked/songs/album:<id>/
  // artist:<name>/source:<key>），非歌单锚定亦可持久化。
  db.execute('''
    CREATE TABLE IF NOT EXISTS deep_lists (
      playlist_uuid TEXT PRIMARY KEY,
      entries_json  TEXT NOT NULL,
      updated_at    TEXT NOT NULL
    );
  ''');
  final mirrorCols = db
      .select('PRAGMA table_info(breakpoint_mirror)')
      .map((r) => r['name'] as String)
      .toSet();
  if (!mirrorCols.contains('source_id')) {
    db.execute('ALTER TABLE breakpoint_mirror ADD COLUMN source_id TEXT');
  }
  if (!mirrorCols.contains('deep_list_json')) {
    db.execute('ALTER TABLE breakpoint_mirror ADD COLUMN deep_list_json TEXT');
  }
  // 歌单跨设备全局标识 + 删除墓碑（本地删除仍硬删，墓碑只活在服务端）。
  final playlistCols = db
      .select('PRAGMA table_info(playlists)')
      .map((r) => r['name'] as String)
      .toSet();
  if (!playlistCols.contains('client_uuid')) {
    db.execute('ALTER TABLE playlists ADD COLUMN client_uuid TEXT');
    db.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_playlists_uuid ON playlists(client_uuid)');
  }
  if (!playlistCols.contains('deleted')) {
    db.execute(
        'ALTER TABLE playlists ADD COLUMN deleted INTEGER NOT NULL DEFAULT 0');
  }
  // 条目归属源（local/smb/webdav）：同步条目事件解析服务端 song_id 用。
  // 既有行留空（NULL），仅新写入行携带。
  final itemCols = db
      .select('PRAGMA table_info(playlist_items)')
      .map((r) => r['name'] as String)
      .toSet();
  if (!itemCols.contains('source')) {
    db.execute('ALTER TABLE playlist_items ADD COLUMN source TEXT');
  }
  // play_meta 为既有 DB 时可能缺 song_json 快照列。
  final metaCols = db
      .select('PRAGMA table_info(play_meta)')
      .map((r) => r['name'] as String)
      .toSet();
  if (!metaCols.contains('song_json')) {
    db.execute('ALTER TABLE play_meta ADD COLUMN song_json TEXT');
  }
  // 收藏一次性回填迁移：idx_songs.is_favorite → play_meta，此后以 play_meta 为准。
  db.execute('''
    INSERT OR IGNORE INTO play_meta(source_key, song_ref, is_favorite)
    SELECT source_key, ref, is_favorite FROM idx_songs WHERE is_favorite = 1
  ''');
  db.execute('''
    CREATE INDEX IF NOT EXISTS pli_playlist ON playlist_items(playlist_id);
  ''');
  db.execute('''
    CREATE INDEX IF NOT EXISTS idx_songs_source ON idx_songs(source_key);
  ''');
  db.execute('''
    CREATE INDEX IF NOT EXISTS idx_songs_ref ON idx_songs(ref);
  ''');
}