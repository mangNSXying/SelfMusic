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
  // 阶段 2：歌曲播放元数据 / 歌单 / 应用设置 / 断点（DEVELOPER.md「播放算法与同步协议」、stage2.md §1）。
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
      play_sec      INTEGER NOT NULL DEFAULT 0,
      progress_hist TEXT,
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
      anchor_key    TEXT,
      session_id    TEXT
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
  // v2 播放会话 id：pause/resume/seek/progress 复用；新起播换新会话。
  if (!stateCols.contains('session_id')) {
    db.execute('ALTER TABLE play_state ADD COLUMN session_id TEXT');
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
  // 未确认事件扫描（2s tick 的 COUNT 与上推 SELECT 的 acked=0 过滤）：
  // 无索引会全表扫；已确认行删除后表通常很小，但死信行会长期留存。
  db.execute(
      'CREATE INDEX IF NOT EXISTS idx_outbox_acked ON weight_outbox(acked);');
  db.execute('''
    CREATE TABLE IF NOT EXISTS breakpoint_mirror (
      playlist_uuid TEXT PRIMARY KEY,
      song_id       INTEGER,
      source_id     TEXT,
      source        TEXT,
      source_ref    TEXT,
      position_ms   INTEGER NOT NULL DEFAULT 0,
      updated_at    TEXT NOT NULL,
      device_id     TEXT,
      last_event_at TEXT,
      head_rev      INTEGER NOT NULL DEFAULT 0,
      history_rev   INTEGER NOT NULL DEFAULT 0,
      head_clock    TEXT,
      head_op_id    TEXT,
      head_session  TEXT,
      head_playing  INTEGER NOT NULL DEFAULT 0,
      head_updated_at TEXT
    );
  ''');
  // 断点深层列表同步 base：每个歌单本机已采用且与服务端确认的深层列表
  // （身份 JSON）。纯追加时合并只消费 base 之后的后缀；非追加（上一首/
  // 替换/清空）则带上 base 做三向合并。与 mirror 分表，避免本机推送 ack
  // 更新时伪造一条远端镜像。
  db.execute('''
    CREATE TABLE IF NOT EXISTS breakpoint_sync_base (
      playlist_uuid TEXT PRIMARY KEY,
      deep_list_json TEXT NOT NULL,
      history_rev    INTEGER NOT NULL DEFAULT 0,
      updated_at     TEXT NOT NULL
    );
  ''');
  // v2 断点同步状态：已应用的 head/history 版本 + 本地待确认的 head 操作。
  // head_rev/history_rev 只增；server_epoch 变化时清零（服务端 DB 重建）。
  db.execute('''
    CREATE TABLE IF NOT EXISTS breakpoint_sync_state (
      playlist_uuid        TEXT PRIMARY KEY,
      applied_head_rev     INTEGER NOT NULL DEFAULT 0,
      applied_history_rev  INTEGER NOT NULL DEFAULT 0,
      pending_head_op_id   TEXT,
      session_id           TEXT,
      server_epoch         TEXT,
      updated_at           TEXT NOT NULL
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
  if (!mirrorCols.contains('last_event_at')) {
    // 比较时钟升级（F4）：镜像「最后操作时间」（= 命中事件的 occurred_at，
    // 与推送 LWW/服务端 latest 同口径；空值回退 updated_at）。加列时清空一次
    // 镜像表——旧行缺该字段，且此前「本机旧态盖上上传时间戳」的毒缓存正是
    // 需要清除的对象，交由同步重建。
    db.execute('ALTER TABLE breakpoint_mirror ADD COLUMN last_event_at TEXT');
    db.execute('DELETE FROM breakpoint_mirror');
  }
  // v2：head/history 版本与 head 操作元数据。旧镜像行 rev=0，首轮拉取会
  // 按服务端快照补齐；不清空镜像，避免升级瞬间把本地续播状态清掉。
  if (!mirrorCols.contains('head_rev')) {
    db.execute(
        'ALTER TABLE breakpoint_mirror ADD COLUMN head_rev INTEGER NOT NULL DEFAULT 0');
  }
  if (!mirrorCols.contains('history_rev')) {
    db.execute(
        'ALTER TABLE breakpoint_mirror ADD COLUMN history_rev INTEGER NOT NULL DEFAULT 0');
  }
  if (!mirrorCols.contains('head_clock')) {
    db.execute('ALTER TABLE breakpoint_mirror ADD COLUMN head_clock TEXT');
  }
  if (!mirrorCols.contains('head_op_id')) {
    db.execute('ALTER TABLE breakpoint_mirror ADD COLUMN head_op_id TEXT');
  }
  if (!mirrorCols.contains('head_session')) {
    db.execute('ALTER TABLE breakpoint_mirror ADD COLUMN head_session TEXT');
  }
  if (!mirrorCols.contains('head_playing')) {
    db.execute(
        'ALTER TABLE breakpoint_mirror ADD COLUMN head_playing INTEGER NOT NULL DEFAULT 0');
  }
  if (!mirrorCols.contains('head_updated_at')) {
    db.execute('ALTER TABLE breakpoint_mirror ADD COLUMN head_updated_at TEXT');
  }
  final baseCols = db
      .select('PRAGMA table_info(breakpoint_sync_base)')
      .map((r) => r['name'] as String)
      .toSet();
  if (!baseCols.contains('history_rev')) {
    db.execute(
        'ALTER TABLE breakpoint_sync_base ADD COLUMN history_rev INTEGER NOT NULL DEFAULT 0');
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
  // 累计播放时长（秒）：改进.txt 要求播放时长精确到秒、播放次数由其派生。
  if (!metaCols.contains('play_sec')) {
    db.execute(
        'ALTER TABLE play_meta ADD COLUMN play_sec INTEGER NOT NULL DEFAULT 0');
  }
  // 播放进度直方图（0..100 共 101 桶，JSON 数组）。空直方图留 NULL。
  if (!metaCols.contains('progress_hist')) {
    db.execute('ALTER TABLE play_meta ADD COLUMN progress_hist TEXT');
  }
  // 「不喜欢」锁定行权重刷新（一次性、幂等）：历史语义写的是自动调权下限 0.5，
  // 现改为固定最低档 0.1（SongWeightStore.dislikedFactor）。只降不升，重跑无匹配行。
  db.execute(
      'UPDATE play_meta SET factor = 0.1 WHERE frozen <> 0 AND factor > 0.1');
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
  // 歌手处理.txt：歌手身份聚合。artists 为唯一精炼身份表（每「真人/占位」一行，
  // 主角/别名/角色名折进 names JSON 列）；artist_canon 为 归一化键→身份 桥
  // （别名拼写合并进同一身份后仍需持久指向，避免 reconcile 反复重建占位）；
  // artist_song_map 为歌曲→身份联结。
  // artists.status：pending=待解析 / local=未命中（占位）/ resolved=已解析 /
  // ambiguous=待人工。
  db.execute('''
    CREATE TABLE IF NOT EXISTS artists (
      artist_key     TEXT PRIMARY KEY,
      mbid           TEXT,
      canonical_key  TEXT NOT NULL,
      display_name   TEXT NOT NULL,
      names          TEXT NOT NULL DEFAULT '[]',
      groups         TEXT NOT NULL DEFAULT '[]',
      type           TEXT NOT NULL DEFAULT 'person',
      disambiguation TEXT,
      status         TEXT NOT NULL DEFAULT 'pending',
      error_count    INTEGER NOT NULL DEFAULT 0,
      next_at        INTEGER NOT NULL DEFAULT 0,
      resolved_at    TEXT,
      updated_at     TEXT NOT NULL,
      UNIQUE (mbid)
    );
  ''');
  db.execute('''
    CREATE INDEX IF NOT EXISTS idx_artists_canonical ON artists(canonical_key);
  ''');
  db.execute('''
    CREATE INDEX IF NOT EXISTS idx_artists_rescan ON artists(status, next_at);
  ''');
  db.execute('''
    CREATE TABLE IF NOT EXISTS artist_canon (
      canonical_key TEXT PRIMARY KEY,
      artist_key    TEXT NOT NULL,
      updated_at    INTEGER NOT NULL DEFAULT 0
    );
  ''');
  db.execute('''
    CREATE INDEX IF NOT EXISTS idx_acanon_artist ON artist_canon(artist_key);
  ''');
  db.execute('''
    CREATE TABLE IF NOT EXISTS artist_song_map (
      source_key TEXT NOT NULL,
      ref        TEXT NOT NULL,
      artist_key TEXT NOT NULL,
      role       TEXT NOT NULL DEFAULT 'main',
      PRIMARY KEY (source_key, ref, artist_key, role)
    );
  ''');
  db.execute('''
    CREATE INDEX IF NOT EXISTS idx_asong_artist ON artist_song_map(artist_key);
  ''');
  // artist_member：组合/角色 → 成员 的有向边（歌手处理.txt 第 43-47 行）。
  // 一次 lookup(inc=artist-rels) 拿到的关系直接建边：关系自带 mbid，成员身份因此
  // 一出生就带 mbid、status='resolved'，不必再为每个成员单独搜 MB。
  // 歌手页沿这张图把组合一路递归到 Person；成员没有自己的 role='main' 歌曲映射，
  // 歌曲归属在查询期沿 parent 反向继承（见 LocalIndex.identityArtistGroups）。
  db.execute('''
    CREATE TABLE IF NOT EXISTS artist_member (
      parent_key TEXT NOT NULL,
      member_key TEXT NOT NULL,
      relation   TEXT NOT NULL,
      updated_at INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (parent_key, member_key, relation)
    );
  ''');
  db.execute('''
    CREATE INDEX IF NOT EXISTS idx_amember_member ON artist_member(member_key);
  ''');
  // 已展开的成员数：0 表示「没展开出成员」，歌手页据此决定是否回落显示组合本身。
  final artistCols = db
      .select("PRAGMA table_info(artists)")
      .map((r) => r['name'] as String)
      .toSet();
  if (!artistCols.contains('member_count')) {
    db.execute(
        'ALTER TABLE artists ADD COLUMN member_count INTEGER NOT NULL DEFAULT 0');
  }
  if (!artistCols.contains('expanded_at')) {
    db.execute('ALTER TABLE artists ADD COLUMN expanded_at TEXT');
  }
  // 采纳该身份时 MusicBrainz 给的检索分数（脏数据过滤后的第一个候选）。
  if (!artistCols.contains('match_score')) {
    db.execute('ALTER TABLE artists ADD COLUMN match_score REAL');
  }
  // SFTP 主机密钥 TOFU 钉（阶段 7）：host_port（`host:port`，host 小写）主键，
  // fingerprint 为 `SHA256:` 形态；本机信任锚，不参与跨设备同步。
  db.execute('''
    CREATE TABLE IF NOT EXISTS ssh_known_hosts (
      host_port   TEXT PRIMARY KEY,
      fingerprint TEXT NOT NULL,
      updated_at  INTEGER NOT NULL DEFAULT 0
    );
  ''');
}
