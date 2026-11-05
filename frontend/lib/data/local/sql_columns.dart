/// 本地库的列清单与固定 SQL（主连接与写隔离共用，改表时只改这里）。
library;

/// `idx_songs` 行 → `Song` 的完整 SELECT 列表（别名固定 `i` / `p`）。
const String kSongSelectColumns =
    'i.id, i.source_key, i.ref, i.title, i.artist, i.album, i.album_artist, '
    'i.track_no, i.year, i.genre, i.duration, i.format, i.size, '
    'i.cover_path, i.url, i.missing, i.meta_read, '
    'COALESCE(p.is_favorite, 0) AS favorite';

/// 歌曲查询的公共 FROM/JOIN（`i` = idx_songs，`p` = play_meta）。
const String kSongFromJoin = 'FROM idx_songs i '
    'LEFT JOIN play_meta p ON p.source_key = i.source_key AND p.song_ref = i.ref';

/// `playlist_items` 的完整列清单（`PlaylistItemRow` 映射用）。
const String kPlaylistItemColumns =
    'id, playlist_id, source_key, song_ref, title, artist, album, '
    'cover_path, sort_order, source';

/// `playlist_items` 插入列（三种写法共用）。
const String kPlaylistItemInsertColumns =
    'playlist_id, source_key, song_ref, title, artist, album, cover_path, '
    'sort_order, added_at, source';

const String kPlaylistItemInsertSql =
    'INSERT INTO playlist_items($kPlaylistItemInsertColumns) '
    'VALUES(?,?,?,?,?,?,?,?,?,?)';

const String kPlaylistItemInsertIgnoreSql = '$kPlaylistItemInsertSql '
    'ON CONFLICT(playlist_id, source_key, song_ref) DO NOTHING';

/// `breakpoint_mirror` 的完整列清单（v2）。
const String kBreakpointMirrorColumns =
    'playlist_uuid, song_id, source_id, source, source_ref, position_ms, '
    'deep_list_json, updated_at, device_id, last_event_at, head_rev, '
    'history_rev, head_clock, head_op_id, head_session, head_playing, '
    'head_updated_at';

/// 断点镜像 v2 upsert：head 字段只跟随更高 `head_rev`，历史只跟随更高
/// `history_rev`（乱序旧快照不会覆盖新值）。
const String kBreakpointMirrorV2UpsertSql =
    'INSERT INTO breakpoint_mirror($kBreakpointMirrorColumns) '
    'VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) '
    'ON CONFLICT(playlist_uuid) DO UPDATE SET '
    'song_id=CASE WHEN excluded.head_rev >= breakpoint_mirror.head_rev THEN excluded.song_id ELSE breakpoint_mirror.song_id END, '
    'source_id=CASE WHEN excluded.head_rev >= breakpoint_mirror.head_rev THEN excluded.source_id ELSE breakpoint_mirror.source_id END, '
    'source=CASE WHEN excluded.head_rev >= breakpoint_mirror.head_rev THEN excluded.source ELSE breakpoint_mirror.source END, '
    'source_ref=CASE WHEN excluded.head_rev >= breakpoint_mirror.head_rev THEN excluded.source_ref ELSE breakpoint_mirror.source_ref END, '
    'position_ms=CASE WHEN excluded.head_rev >= breakpoint_mirror.head_rev THEN excluded.position_ms ELSE breakpoint_mirror.position_ms END, '
    'deep_list_json=CASE WHEN excluded.deep_list_json IS NOT NULL AND excluded.history_rev >= breakpoint_mirror.history_rev THEN excluded.deep_list_json ELSE breakpoint_mirror.deep_list_json END, '
    'device_id=CASE WHEN excluded.head_rev >= breakpoint_mirror.head_rev THEN excluded.device_id ELSE breakpoint_mirror.device_id END, '
    'last_event_at=CASE WHEN excluded.head_rev >= breakpoint_mirror.head_rev THEN excluded.last_event_at ELSE breakpoint_mirror.last_event_at END, '
    'updated_at=CASE WHEN excluded.head_rev >= breakpoint_mirror.head_rev THEN excluded.updated_at ELSE breakpoint_mirror.updated_at END, '
    'head_rev=MAX(breakpoint_mirror.head_rev, excluded.head_rev), '
    'history_rev=MAX(breakpoint_mirror.history_rev, CASE WHEN excluded.deep_list_json IS NOT NULL THEN excluded.history_rev ELSE 0 END), '
    'head_clock=CASE WHEN excluded.head_rev >= breakpoint_mirror.head_rev THEN excluded.head_clock ELSE breakpoint_mirror.head_clock END, '
    'head_op_id=CASE WHEN excluded.head_rev >= breakpoint_mirror.head_rev THEN excluded.head_op_id ELSE breakpoint_mirror.head_op_id END, '
    'head_session=CASE WHEN excluded.head_rev >= breakpoint_mirror.head_rev THEN excluded.head_session ELSE breakpoint_mirror.head_session END, '
    'head_playing=CASE WHEN excluded.head_rev >= breakpoint_mirror.head_rev THEN excluded.head_playing ELSE breakpoint_mirror.head_playing END, '
    'head_updated_at=CASE WHEN excluded.head_rev >= breakpoint_mirror.head_rev THEN excluded.head_updated_at ELSE breakpoint_mirror.head_updated_at END';

/// 断点镜像 legacy（无 v2 head/history）upsert。
const String kBreakpointMirrorV1UpsertSql =
    'INSERT INTO breakpoint_mirror(playlist_uuid, song_id, source_id, source, '
    'source_ref, position_ms, deep_list_json, updated_at, device_id, '
    'last_event_at) VALUES(?,?,?,?,?,?,?,?,?,?) '
    'ON CONFLICT(playlist_uuid) DO UPDATE SET '
    'song_id=excluded.song_id, source_id=excluded.source_id, '
    'source=excluded.source, source_ref=excluded.source_ref, '
    'position_ms=excluded.position_ms, deep_list_json=excluded.deep_list_json, '
    'updated_at=excluded.updated_at, device_id=excluded.device_id, '
    'last_event_at=excluded.last_event_at';
